require "fileutils"

source_path = File.join(__dir__, "pico2w3d.rb")
raise "pico2w3d.rb is missing: implement the single-file PicoRuby application" unless File.file?(source_path)

require_relative "test/host_hardware"
$LOADED_FEATURES.concat(["gpio.rb", "spi.rb"])
# R2P2 must run on load; host unit tests call run explicitly after loading definitions.
eval(File.read(source_path).sub(/^Pico2W3D\.run\s*\z/, ""), TOPLEVEL_BINDING, source_path)

def assert(condition, message)
  Host.assert(condition, message)
end

def assert_raises(type)
  begin
    yield
  rescue type
    return
  end
  raise "expected #{type}"
end

def with_constants(values)
  original = values.to_h { |name, _| [name, Pico2W3D.const_get(name)] }
  values.each { |name, value| Pico2W3D.send(:remove_const, name); Pico2W3D.const_set(name, value) }
  yield
ensure
  original.each { |name, value| Pico2W3D.send(:remove_const, name); Pico2W3D.const_set(name, value) }
end

def display
  spi = SPI.new
  spi.select if Pico2W3D::USE_CS
  dc = GPIO.new(Pico2W3D::DC_PIN, GPIO::OUT)
  reset = GPIO.new(Pico2W3D::RESET_PIN, GPIO::OUT)
  [Pico2W3D::Display.new(spi, dc, reset), spi]
end

def projected_vertices(vertices, frame)
  sx = Pico2W3D.sine(frame + 18)
  cx = Pico2W3D.sine(frame + 82)
  sy = Pico2W3D.sine(2 * frame + 30)
  cy = Pico2W3D.sine(2 * frame + 94)
  vertices.map do |x, y, z|
    xx = (x * cy + z * sy) / 1024
    zz = (-x * sy + z * cy) / 1024
    yy = (y * cx - zz * sx) / 1024
    z = (y * sx + zz * cx) / 1024
    d = z + Pico2W3D::CAMERA_Z
    [xx, yy, z, 120 + xx * Pico2W3D::FOCAL_LENGTH / d, 120 - yy * Pico2W3D::FOCAL_LENGTH / d]
  end
end

def cross(a, b, c)
  u = b.zip(a).map { |x, y| x - y }
  v = c.zip(a).map { |x, y| x - y }
  [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
end

def hull(points)
  points = points.uniq.sort
  halves = [points, points.reverse].map do |ordered|
    ordered.each_with_object([]) do |point, result|
      while result.length > 1
        a, b = result[-2], result[-1]
        break if (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0]) > 0
        result.pop
      end
      result << point
    end
  end
  halves[0][0...-1] + halves[1][0...-1]
end

def verify_silhouette(screen, vertices, frame)
  polygon = hull(projected_vertices(vertices, frame).map { |v| v[3, 2] })
  (0...240).each do |y|
    scan_y = y + 0.5
    intersections = polygon.each_with_index.filter_map do |a, i|
      b = polygon[(i + 1) % polygon.length]
      next unless [a[1], b[1]].min <= scan_y && scan_y < [a[1], b[1]].max
      a[0] + (scan_y - a[1]) * (b[0] - a[0]).fdiv(b[1] - a[1])
    end
    row = screen[y * 240, 240]
    colored = row.each_index.select { |x| row[x] != 0 }
    if intersections.empty?
      assert(colored.empty?, "pixels outside projected silhouette at frame #{frame}, y=#{y}")
      next
    end
    left, right = intersections.minmax
    assert(colored.all? { |x| x >= left - 1 && x <= right + 1 }, "pixels outside hull at frame #{frame}")
    first = [0, (left + 1).ceil].max
    last = [239, (right - 1).floor].min
    gap = 0
    (first..last).each do |x|
      gap = row[x].zero? ? gap + 1 : 0
      assert(gap <= 1, "interior hole at frame #{frame}, pixel #{x},#{y}")
    end
  end
end

def verify_face_colors(screen, vertices, faces, frame, gem)
  projected = projected_vertices(vertices, frame)
  faces.each_with_index do |face, face_index|
    a, b, c = face.first(3).map { |i| projected[i].first(3) }
    normal = cross(a, b, c)
    next unless normal[0] * a[0] + normal[1] * a[1] + normal[2] * (a[2] + Pico2W3D::CAMERA_Z) < 0
    points = face.map { |i| projected[i][3, 2] }
    twice_area = points.each_with_index.sum { |p, i| q = points[(i + 1) % points.size]; p[0] * q[1] - p[1] * q[0] }.abs
    next if twice_area < 300
    x = points.sum { |p| p[0] } / points.length
    y = points.sum { |p| p[1] } / points.length
    next unless (0...240).cover?(x) && (0...240).cover?(y)
    illumination = [-2 * normal[0] + 3 * normal[1] - 5 * normal[2], 0].max
    shade = 2 + illumination / normal.sum(&:abs)
    brightness = 32 + shade * 31
    rgb = Pico2W3D::COLORS[gem ? 6 : face_index].map { |channel| channel * brightness / 255 }
    color = ((rgb[0] >> 3) << 11) | ((rgb[1] >> 2) << 5) | (rgb[2] >> 3)
    assert(screen[y * 240 + x] == color, "incorrect visible-face shade/color at frame #{frame}, face #{face_index}")
  end
end

def write_ppm(path, screen)
  rgb = screen.flat_map { |pixel| [((pixel >> 11) & 31) * 255 / 31, ((pixel >> 5) & 63) * 255 / 63, (pixel & 31) * 255 / 31] }
  File.binwrite(path, "P6\n240 240\n255\n" + rgb.pack("C*"))
end

tests = {}
tests["bundled model data and continuous-run defaults match the demo"] = proc do
  assert(Pico2W3D::MAX_FRAMES == 0, "default run must continue until interrupted")
  assert(Pico2W3D::MODEL_FRAMES == 180, "default model switch must occur at frames 180 and 360")
  assert(Pico2W3D::CUBE_VERTICES.sort == [-62, 62].repeated_permutation(3).to_a.sort, "cube corners must use coordinates +/-62")
  assert(Pico2W3D::GEM_VERTICES.include?([0, 88, 0]) && Pico2W3D::GEM_VERTICES.include?([0, -108, 0]), "gem apex positions differ from the design")
  assert(Pico2W3D::COLORS[6] == [255, 48, 96], "the gem's base color must be ruby red")
  assert(Pico2W3D::COLORS.first(6).uniq.size == 6, "cube faces must have six distinct base colors")
end

tests["fixed-point sine and RGB565 byte order"] = proc do
  assert(Pico2W3D::SIN_QUARTER.length == 65, "quarter sine table must contain 65 values")
  (-512..512).each do |angle|
    reference = (Math.sin(angle * Math::PI / 128) * 1024).round
    assert((Pico2W3D.sine(angle) - reference).abs <= 1, "incorrect sine for #{angle}")
  end
  {[255, 0, 0] => [0xf8, 0], [0, 255, 0] => [7, 0xe0], [0, 0, 255] => [0, 31],
   [255, 255, 255] => [255, 255], [0, 0, 0] => [0, 0]}.each do |rgb, bytes|
    assert(Pico2W3D.rgb565(*rgb).bytes == bytes, "RGB565 must send its high byte first")
  end
end

tests["model topology is closed, convex and outward-facing"] = proc do
  [[Pico2W3D::CUBE_VERTICES, Pico2W3D::CUBE_FACES, 8, 6, 4], [Pico2W3D::GEM_VERTICES, Pico2W3D::GEM_FACES, 10, 16, 3]].each do |vertices, faces, count, face_count, corners|
    assert(vertices.length == count && faces.length == face_count, "incorrect model size")
    edges = Hash.new(0)
    faces.each do |face|
      assert(face.length == corners && face.uniq.length == corners, "incorrect face topology")
      a, b, c = face.first(3).map { |index| vertices.fetch(index) }
      normal = cross(a, b, c)
      assert(normal.zip(a).sum { |n, v| n * v } > 0, "face points inward")
      vertices.each { |v| assert(normal.zip(v.zip(a).map { |x, y| x - y }).sum { |n, d| n * d } <= 0, "model is not convex") }
      face.each_with_index { |a_index, i| edges[[a_index, face[(i + 1) % corners]]] += 1 }
    end
    edges.each { |edge, count| assert(count == 1 && edges[edge.reverse] == 1, "model has open or duplicate edges") }
  end
end

tests["ST7789 reset, initialization, black clear and timing"] = proc do
  Host.events.clear
  _, spi = display
  spi.finish!
  expected = [1, 0x11, 0x3a, 0x36, 0x21, 0x13, 0x2a, 0x2b, 0x2c, 0x29]
  assert(spi.commands.map(&:first) == expected, "incorrect initialization command sequence")
  assert(spi.commands[2][1].bytes == [0x55], "COLMOD must select RGB565")
  assert(spi.commands[3][1].bytes == [Pico2W3D::MADCTL], "MADCTL mismatch")
  assert(Host.events.select { |e| e[0] == :gpio && e[1] == Pico2W3D::RESET_PIN }.map(&:last) == [1, 0, 1], "incorrect reset sequence")
  assert(Host.events.select { |e| e[0] == :sleep }.map(&:last) == [0.01, 0.02, 0.15, 0.15, 0.15, 0.1], "incorrect reset/init delays")
  assert(spi.screen.all?(&:zero?) && spi.row_lengths == [480] * 240, "initialization must clear one row at a time")
  assert(spi.windows == [[0, 0, 239, 239]], "initial clear must cover screen")
  puts "  init: #{spi.byte_count} bytes, #{spi.write_count} writes"
end

tests["panel offsets, color order, inversion and window bounds"] = proc do
  with_constants(X_OFFSET: 12, Y_OFFSET: 80, MADCTL: 8, INVERT: false) do
    lcd, spi = display
    assert(spi.commands.map(&:first).include?(0x20), "inversion disable command missing")
    assert(spi.commands.find { |c| c[0] == 0x36 }[1].bytes == [8], "color order setting ignored")
    lcd.window(2, 3, 3, 4)
    lcd.write_pixels(Pico2W3D.rgb565(255, 0, 0) * 2)
    lcd.write_pixels(Pico2W3D.rgb565(0, 0, 255) * 2)
    spi.finish!
    assert(spi.commands.reverse.find { |c| c[0] == 0x2a }[1].unpack("n2") == [14, 15], "column offset ignored")
    assert(spi.commands.reverse.find { |c| c[0] == 0x2b }[1].unpack("n2") == [83, 84], "row offset ignored")
    assert(spi.screen[3 * 240 + 2, 2] == [0xf800] * 2 && spi.screen[4 * 240 + 2, 2] == [31] * 2, "window pixels incorrect")
    [[-1, 0, 1, 1], [0, 0, 240, 1], [0, 0, 1, 240], [2, 0, 1, 1], [0, 2, 1, 1]].each do |bounds|
      assert_raises(ArgumentError) { lcd.window(*bounds) }
    end
  end
end

tests["720 frames alternate cube and gem and erase prior frames"] = proc do
  lcd, spi = display
  scene = Pico2W3D::Scene.new(lcd)
  models = [[Pico2W3D::CUBE_VERTICES, Pico2W3D::CUBE_FACES], [Pico2W3D::GEM_VERTICES, Pico2W3D::GEM_FACES]]
  names = %w[cube gem]
  metrics = [[], []]
  previous_bounds = nil
  FileUtils.mkdir_p(File.join(__dir__, "tmp/host"))
  720.times do |frame|
    before = [spi.byte_count, spi.write_count, spi.row_lengths.length]
    scene.frame(frame)
    spi.finish!
    model = (frame / Pico2W3D::MODEL_FRAMES) % 2
    vertices, faces = models[model]
    projected = projected_vertices(vertices, frame)
    xs = projected.map { |v| v[3] }
    ys = projected.map { |v| v[4] }
    bounds = [xs.min - 2, ys.min - 2, xs.max + 2, ys.max + 2]
    combined = if previous_bounds
      [[bounds[0], previous_bounds[0]].min, [bounds[1], previous_bounds[1]].min,
       [bounds[2], previous_bounds[2]].max, [bounds[3], previous_bounds[3]].max]
    else
      bounds
    end
    expected_window = [[combined[0], 0].max, [combined[1], 0].max, [combined[2], 239].min, [combined[3], 239].min]
    assert(spi.windows.last == expected_window, "dirty window must cover current and previous bounds with two-pixel padding at frame #{frame}")
    previous_bounds = bounds
    assert(spi.screen.any? { |pixel| pixel != 0 }, "empty model at frame #{frame}")
    if model == 1
      spi.screen.uniq.each do |pixel|
        next if pixel.zero?
        red = (pixel >> 11) & 31
        assert(red * 2 > ((pixel >> 5) & 63) && red > (pixel & 31), "gem must appear red in the transmitted pixels")
      end
    end
    verify_silhouette(spi.screen, vertices, frame)
    verify_face_colors(spi.screen, vertices, faces, frame, model == 1)
    if frame < 360
      metrics[model] << [spi.byte_count - before[0], spi.write_count - before[1], spi.row_lengths.length - before[2]]
    end
    if [0, 179, 180, 255, 359, 360, 539, 540, 719].include?(frame)
      clean_lcd, clean_spi = display
      Pico2W3D::Scene.new(clean_lcd).frame(frame)
      clean_spi.finish!
      assert(spi.screen == clean_spi.screen, "previous frame left a ghost at frame #{frame}")
    end
    write_ppm(File.join(__dir__, "tmp/host/#{names[model]}.ppm"), spi.screen) if [0, 180].include?(frame)
  end
  metrics.each_with_index do |rows, i|
    bytes, calls, lines = rows.transpose
    puts "  #{names[i]}: bytes min/avg/max #{bytes.min}/#{(bytes.sum.fdiv(bytes.size)).round}/#{bytes.max}; rows #{lines.min}..#{lines.max}; writes #{calls.min}..#{calls.max}"
  end
end

tests["both models render all 256 orientations"] = proc do
  with_constants(MODEL_FRAMES: 256) do
    lcd, spi = display
    scene = Pico2W3D::Scene.new(lcd)
    512.times do |frame|
      scene.frame(frame)
      spi.finish!
      vertices = frame < 256 ? Pico2W3D::CUBE_VERTICES : Pico2W3D::GEM_VERTICES
      verify_silhouette(spi.screen, vertices, frame)
    end
  end
end

tests["screen clipping and camera-plane rejection"] = proc do
  with_constants(FOCAL_LENGTH: 1200) do
    lcd, spi = display
    scene = Pico2W3D::Scene.new(lcd)
    [0, 60, 180, 240, 360].each { |frame| scene.frame(frame); spi.finish! }
    assert(spi.row_lengths.max == 480, "large model should clip to screen width")
  end
  with_constants(CAMERA_Z: 1) do
    lcd, = display
    assert_raises(ArgumentError) { Pico2W3D::Scene.new(lcd).frame(0) }
  end
end

tests["run configures SPI and stops after exactly 400 frames"] = proc do
  Host.events.clear
  with_constants(MAX_FRAMES: 400) { Pico2W3D.run }
  spi = SPI.instances.last
  spi.finish!
  expected = {unit: :RP2040_SPI0, frequency: 8_000_000, mode: 3, sck_pin: 18, cipo_pin: 16, copi_pin: 19, cs_pin: 17}
  assert(spi.options == expected, "SPI options differ from configured pins and mode")
  assert(spi.windows.length == 401, "finite run did not render exactly 400 frames")
  assert(spi.select_count.zero? && spi.deselect_count.zero?, "CS-less module must not require select/deselect")
  assert(Host.events.count { |e| e == [:sleep, 0.025] } == 400, "frame pause not applied once per frame")
  final_lcd, final_spi = display
  Pico2W3D::Scene.new(final_lcd).frame(399)
  assert(spi.screen == final_spi.screen, "finite run stopped on the wrong frame")
  with_constants(MAX_FRAMES: 2, FRAME_PAUSE: 0, USE_CS: true, SPI_MODE: 0) do
    Pico2W3D.run
    spi = SPI.instances.last
    spi.finish!
    assert(spi.options[:mode].zero? && spi.windows.length == 3, "CS mode or frame count incorrect")
    assert(spi.select_count == 1 && spi.deselect_count == 1, "CS must be selected during run and released on exit")
  end
end

tests["invalid runtime settings fail before touching hardware"] = proc do
  {MODEL_FRAMES: 0, MAX_FRAMES: -1, FRAME_PAUSE: -0.1, CAMERA_Z: 0, FOCAL_LENGTH: 0}.each do |name, value|
    with_constants(name => value) do
      count = SPI.instances.length
      assert_raises(ArgumentError) { Pico2W3D.run }
      assert(SPI.instances.length == count, "invalid #{name} touched hardware")
    end
  end
end

tests["unlimited mode renders repeated model pairs and releases CS on failure"] = proc do
  with_constants(MAX_FRAMES: 0, MODEL_FRAMES: 3, FRAME_PAUSE: 0, USE_CS: true) do
    begin
      SPI.stop_after_windows = 19 # Initial clear plus three cube/gem pairs.
      assert_raises(Host::Stopped) { Pico2W3D.run }
      spi = SPI.instances.last
      spi.finish!
      assert(spi.windows.length == 19, "unlimited mode stopped before three complete model pairs")
      assert(spi.select_count == 1 && spi.deselect_count == 1, "CS was left active after failure")
      final_lcd, final_spi = display
      Pico2W3D::Scene.new(final_lcd).frame(17)
      final_spi.finish!
      assert(spi.screen == final_spi.screen, "unlimited loop ended on the wrong rendered frame")
    ensure
      SPI.stop_after_windows = nil
    end
  end
end

tests["unlimited frame counter stays bounded without changing model or rotation phases"] = proc do
  counts = []
  period = (2 * 3).lcm(256)
  recorder = Class.new do
    define_method(:initialize) { |_display| }
    define_method(:frame) do |count|
      raise Host::Stopped, "simulated interruption" if counts.length == 2 * period + 2
      counts << count
    end
  end
  with_constants(Scene: recorder, MODEL_FRAMES: 3, MAX_FRAMES: 0, FRAME_PAUSE: 0, USE_CS: true) do
    assert_raises(Host::Stopped) { Pico2W3D.run }
    assert(counts.length == 2 * period + 2, "unlimited loop stopped before two complete phase periods")
    counts.each_with_index do |count, frame|
      assert((0...period).cover?(count), "unlimited frame counter grew beyond its visual period")
      assert(count % 256 == frame % 256 && (count / 3) % 2 == (frame / 3) % 2, "counter wrap changed the visible model or rotation")
    end
    spi = SPI.instances.last
    assert(spi.select_count == 1 && spi.deselect_count == 1, "CS was left active after counter-loop interruption")
    counts.clear
    with_constants(MAX_FRAMES: period + 2) { Pico2W3D.run }
    assert(counts == (0...period + 2).to_a, "finite runs must retain the total frame count")
  end
end

tests.each do |name, test|
  test.call
  puts "PASS #{name}"
end
puts "#{tests.length} host tests passed. PPM previews: tmp/host/cube.ppm, tmp/host/gem.ppm"
