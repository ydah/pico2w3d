# Host-only geometry oracle; no external gems and no test_host.rb side effects.
require "digest"

$LOADED_FEATURES.concat(["gpio.rb", "spi.rb"])
source_path = File.expand_path("../pico2w3d.rb", __dir__)
eval(File.read(source_path).sub(/^Pico2W3D\.run\s*\z/, ""), TOPLEVEL_BINDING, source_path)

class GeometryScreen
  attr_reader :pixels

  def initialize
    @pixels = Array.new(240 * 240, 0)
    @remaining = 0
  end

  def window(x0, y0, x1, y1)
    raise "unfinished previous window" unless @remaining.zero?
    raise "invalid clipped window" unless 0 <= x0 && x0 <= x1 && x1 < 240 && 0 <= y0 && y0 <= y1 && y1 < 240
    @x = x0
    @y = y0
    @width = x1 - x0 + 1
    @remaining = y1 - y0 + 1
  end

  def write_pixels(row)
    raise "incorrect row length" unless row.bytesize == @width * 2 && @remaining > 0
    @pixels[@y * 240 + @x, @width] = row.unpack("n*")
    @y += 1
    @remaining -= 1
  end

  def digest
    raise "unfinished frame" unless @remaining.zero?
    Digest::SHA256.digest(@pixels.pack("n*"))
  end

  def verify_no_cracks(frame)
    previous_y = nil
    @pixels.each_slice(240).with_index do |row, y|
      left = row.index { |pixel| pixel != 0 }
      next unless left
      raise "missing interior row at frame #{frame}, row #{y - 1}" if previous_y && y != previous_y + 1
      previous_y = y
      right = row.rindex { |pixel| pixel != 0 }
      raise "black crack at frame #{frame}, row #{y}" if row[left..right].include?(0)
    end
    raise "empty model at frame #{frame}" unless previous_y
  end
end

def geometry_setting(name, value)
  old = Pico2W3D.const_get(name)
  Pico2W3D.send(:remove_const, name)
  Pico2W3D.const_set(name, value)
  yield
ensure
  Pico2W3D.send(:remove_const, name)
  Pico2W3D.const_set(name, old)
end

# Matrix-vector products use independently generated trigonometric values.
def reference_projection(vertices, frame)
  ax = (frame + 18) * Math::PI / 128
  ay = (2 * frame + 30) * Math::PI / 128
  sx, cx, sy, cy = [Math.sin(ax), Math.cos(ax), Math.sin(ay), Math.cos(ay)].map { |n| (n * 1024).round }
  rotations = [
    [[cy, 0, sy], [0, 1024, 0], [-sy, 0, cy]],
    [[1024, 0, 0], [0, cx, -sx], [0, sx, cx]]
  ]
  vertices.map do |vertex|
    rotated = rotations.reduce(vertex) do |vector, matrix|
      matrix.map { |row| row.zip(vector).sum { |a, b| a * b }.div(1024) }
    end
    x, y, z = rotated
    rotated + [120 + (x * Pico2W3D::FOCAL_LENGTH).div(z + Pico2W3D::CAMERA_Z),
               120 - (y * Pico2W3D::FOCAL_LENGTH).div(z + Pico2W3D::CAMERA_Z)]
  end
end

# Rational intersections avoid sharing the renderer's interpolation arithmetic.
def reference_span(points, y)
  scan = Rational(2 * y + 1, 2)
  intersections = points.each_with_index.filter_map do |a, i|
    b = points[(i + 1) % points.size]
    next unless [a[1], b[1]].min <= scan && scan < [a[1], b[1]].max
    a[0] + (scan - a[1]) * Rational(b[0] - a[0], b[1] - a[1])
  end
  return nil if intersections.empty?
  intersections.minmax.map { |x| Rational((x * 256).floor - 128, 256).ceil }
end

[[], [100, 102]].each do |rows|
  screen = GeometryScreen.new
  rows.each { |y| screen.pixels[y * 240 + 100, 3] = [1, 1, 1] }
  rejected = false
  begin
    screen.verify_no_cracks("negative control")
  rescue RuntimeError => error
    rejected = error.message.include?(rows.empty? ? "empty model" : "missing interior row")
  end
  raise "geometry oracle accepted a blank frame or missing interior row" unless rejected
end
puts "PASS geometry oracle rejects blank frames and missing interior rows"

scene = Pico2W3D::Scene.new(GeometryScreen.new)
[Pico2W3D::CUBE_VERTICES, Pico2W3D::GEM_VERTICES].each do |vertices|
  256.times do |frame|
    expected = reference_projection(vertices, frame)
    raise "rotation/projection differs from matrix oracle at #{frame}" unless scene.project(vertices, frame) == expected
  end
end
puts "PASS independent matrix projection for both models in all 256 orientations"

polygons = [
  [[0, 0], [4, 0], [4, 4], [0, 4]],
  [[-3, -2], [3, -2], [0, 4]],
  [[0, 0], [1, 5], [2, 0]],
  [[-4, 2], [4, 2], [0, 2]],
  [[0, 0], [255, 1], [0, 2]]
]
random = Random.new(20261028)
200.times { polygons << Array.new(3) { [random.rand(-240..480), random.rand(-240..480)] } }
polygons.each do |points|
  polygon = points.map { |x, y| [0, 0, 0, x, y] }
  ys = points.map(&:last)
  ([ys.min - 1, ys.min, ys.max - 1, ys.max] + Array.new(8) { random.rand(ys.min..ys.max) }).uniq.each do |y|
    expected = reference_span(points, y)
    actual = scene.span(polygon, y, "color")
    raise "scanline differs from rational oracle: #{points.inspect} y=#{y}" unless (actual && actual.first(2)) == expected
  end
end
puts "PASS rational scanline oracle for horizontal, thin, negative and seeded random edges"

reference = [[], []]
geometry_setting(:MODEL_FRAMES, 256) do
  512.times do |frame|
    screen = GeometryScreen.new
    Pico2W3D::Scene.new(screen).frame(frame)
    screen.verify_no_cracks(frame)
    reference[frame / 256][frame % 256] = screen.digest
  end
end
puts "PASS zero interior cracks in all 512 model/orientation combinations"

screen = GeometryScreen.new
scene = Pico2W3D::Scene.new(screen)
period = (2 * Pico2W3D::MODEL_FRAMES).lcm(256)
period.times do |frame|
  scene.frame(frame)
  expected = reference[(frame / Pico2W3D::MODEL_FRAMES) % 2][frame % 256]
  raise "residual or missing pixels at frame #{frame}" unless screen.digest == expected
end
puts "PASS #{period} sequential frames cover the complete model/rotation period with exact image equality"

[110, 180, 420, 1000].each do |camera|
  geometry_setting(:CAMERA_Z, camera) do
    [30, 300, 1200].each do |focal|
      geometry_setting(:FOCAL_LENGTH, focal) do
        geometry_setting(:MODEL_FRAMES, 256) do
          screen = GeometryScreen.new
          scene = Pico2W3D::Scene.new(screen)
          512.times do |frame|
            scene.frame(frame)
            screen.verify_no_cracks(frame)
            screen.digest
          end
        end
      end
    end
  end
end
puts "PASS 6144 camera/zoom/orientation cases preserve clipped windows and unbroken silhouettes"
