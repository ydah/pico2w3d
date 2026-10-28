require_relative "host_hardware"
$LOADED_FEATURES.concat(["gpio.rb", "spi.rb"])
source_path = File.expand_path("../pico2w3d.rb", __dir__)
source = File.read(source_path)
raise "expected an unconditional Pico2W3D.run entrypoint" unless source.match?(/^Pico2W3D\.run\s*\z/)
eval(source.sub(/^Pico2W3D\.run\s*\z/, ""), TOPLEVEL_BINDING, source_path)

def with_settings(settings)
  original = settings.to_h { |name, _| [name, Pico2W3D.const_get(name)] }
  settings.each { |name, value| Pico2W3D.send(:remove_const, name); Pico2W3D.const_set(name, value) }
  yield
ensure
  original.each { |name, value| Pico2W3D.send(:remove_const, name); Pico2W3D.const_set(name, value) }
end

failures = []
# Positive fractions previously passed validation, cleared the display, then failed in window encoding.
invalid_settings = [
  [:CAMERA_Z, 420.5], [:FOCAL_LENGTH, 300.5],
  [:X_OFFSET, -1], [:Y_OFFSET, -1],
  [:X_OFFSET, 0.5], [:Y_OFFSET, 80.5],
  [:X_OFFSET, 65_536 - 239], [:Y_OFFSET, 65_536 - 239],
  [:FRAME_PAUSE, Float::NAN], [:FRAME_PAUSE, Float::INFINITY]
]
invalid_settings.each do |name, value|
  with_settings({MAX_FRAMES: 1, FRAME_PAUSE: 0, USE_CS: true}.merge(name => value)) do
    before = SPI.instances.length
    error = nil
    begin
      Pico2W3D.run
    rescue StandardError => e
      error = e
    end
    unless error.is_a?(ArgumentError) && SPI.instances.length == before
      failures << "#{name}=#{value.inspect}: expected ArgumentError before SPI creation; got #{error.class} after #{SPI.instances.length - before} SPI creation(s)"
    end
  end
end

# Valid panel offset and zoom settings remain usable, including the smallest finite run.
with_settings(Y_OFFSET: 80, CAMERA_Z: 200, FOCAL_LENGTH: 600, MAX_FRAMES: 1, MODEL_FRAMES: 1, FRAME_PAUSE: 0, USE_CS: true, SPI_MODE: 0) do
  Pico2W3D.run
  spi = SPI.instances.last
  spi.finish!
  Host.assert(spi.windows.length == 2, "one-frame run must clear then render exactly once")
  Host.assert(spi.select_count == 1 && spi.deselect_count == 1, "one-frame run must release CS")
  Host.assert(spi.row_lengths.max <= 480, "zoomed model exceeded scanline buffer limit")
end

raise failures.join("\n") unless failures.empty?
puts "PASS adversarial settings: #{invalid_settings.length} invalid configurations rejected before hardware; valid zoom/panel/one-frame run completed"
