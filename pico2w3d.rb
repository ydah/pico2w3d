# pico2w3d: PicoRuby / R2P2, Pico 2 W + ST7789 240x240.
require "gpio"
require "spi"

module Pico2W3D
  SCK_PIN = 18
  COPI_PIN = 19
  RESET_PIN = 20
  DC_PIN = 21
  CIPO_PIN = 16
  CS_PIN = 17
  USE_CS = false             # Set true only when LCD CS is connected to GP17.
  SPI_HZ = 8_000_000
  SPI_MODE = 3               # No CS: 3. With CS: start with 0.
  WIDTH = 240
  HEIGHT = 240
  X_OFFSET = 0
  Y_OFFSET = 0
  MADCTL = 0x00
  INVERT = true
  MODEL_FRAMES = 180
  FRAME_PAUSE = 0.025
  MAX_FRAMES = 0             # Continuous loop; set 400 for a finite first-run check.
  CAMERA_Z = 420
  FOCAL_LENGTH = 300
  FIXED = 1024

  SIN_QUARTER = [
    0, 25, 50, 75, 100, 125, 150, 175, 200, 224, 249, 273, 297,
    321, 345, 369, 392, 415, 438, 460, 483, 505, 526, 548, 569, 590,
    610, 630, 650, 669, 688, 706, 724, 742, 759, 775, 792, 807, 822,
    837, 851, 865, 878, 891, 903, 915, 926, 936, 946, 955, 964, 972,
    980, 987, 993, 999, 1004, 1009, 1013, 1016, 1019, 1021, 1023, 1024, 1024
  ]
  CUBE_VERTICES = [
    [-62, -62, -62], [62, -62, -62], [62, 62, -62], [-62, 62, -62],
    [-62, -62, 62], [62, -62, 62], [62, 62, 62], [-62, 62, 62]
  ]
  CUBE_FACES = [
    [0, 3, 2, 1], [4, 5, 6, 7], [0, 4, 7, 3],
    [1, 2, 6, 5], [3, 7, 6, 2], [0, 1, 5, 4]
  ]
  GEM_VERTICES = [
    [0, 88, 0], [80, 10, 0], [57, 10, 57], [0, 10, 80],
    [-57, 10, 57], [-80, 10, 0], [-57, 10, -57], [0, 10, -80],
    [57, 10, -57], [0, -108, 0]
  ]
  GEM_FACES = [
    [0, 2, 1], [0, 3, 2], [0, 4, 3], [0, 5, 4],
    [0, 6, 5], [0, 7, 6], [0, 8, 7], [0, 1, 8],
    [9, 1, 2], [9, 2, 3], [9, 3, 4], [9, 4, 5],
    [9, 5, 6], [9, 6, 7], [9, 7, 8], [9, 8, 1]
  ]
  COLORS = [
    [48, 144, 255], [96, 64, 255], [48, 224, 192],
    [160, 80, 255], [64, 192, 255], [64, 224, 128], [255, 48, 96]
  ]
  BLACK = "\x00\x00"

  def self.sine(angle)
    angle %= 256
    return SIN_QUARTER[angle] if angle <= 64
    return SIN_QUARTER[128 - angle] if angle <= 128
    return -SIN_QUARTER[angle - 128] if angle <= 192
    -SIN_QUARTER[256 - angle]
  end

  def self.rgb565(r, g, b)
    value = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    (value >> 8).chr + (value & 255).chr
  end

  class Display
    def initialize(spi, dc, reset)
      @spi = spi
      @dc = dc
      reset.write(1)
      sleep 0.01
      reset.write(0)
      sleep 0.02
      reset.write(1)
      sleep 0.15
      command(0x01)
      sleep 0.15
      command(0x11)
      sleep 0.15
      command(0x3A, "\x55")
      command(0x36, MADCTL.chr)
      command(INVERT ? 0x21 : 0x20)
      command(0x13)
      clear
      command(0x29)
      sleep 0.1
    end

    def command(code, data = "")
      @dc.write(0)
      @spi.write(code.chr)
      @dc.write(1)
      @spi.write(data) unless data.empty?
    end

    def window(x0, y0, x1, y1)
      if x0 < 0 || y0 < 0 || x1 >= WIDTH || y1 >= HEIGHT || x0 > x1 || y0 > y1
        raise ArgumentError, "display window outside screen"
      end
      x0 += X_OFFSET
      x1 += X_OFFSET
      y0 += Y_OFFSET
      y1 += Y_OFFSET
      command(0x2A, (x0 >> 8).chr + (x0 & 255).chr + (x1 >> 8).chr + (x1 & 255).chr)
      command(0x2B, (y0 >> 8).chr + (y0 & 255).chr + (y1 >> 8).chr + (y1 & 255).chr)
      command(0x2C)
    end

    def write_pixels(row)
      @spi.write(row)
    end

    def clear
      window(0, 0, WIDTH - 1, HEIGHT - 1)
      row = BLACK * WIDTH
      y = 0
      while y < HEIGHT
        write_pixels(row)
        y += 1
      end
    end
  end

  class Scene
    def initialize(display)
      @display = display
      @previous = nil
      @palette = []
      COLORS.each do |rgb|
        shades = []
        i = 0
        while i < 8
          light = 32 + i * 31
          shades << Pico2W3D.rgb565(rgb[0] * light / 255, rgb[1] * light / 255, rgb[2] * light / 255)
          i += 1
        end
        @palette << shades
      end
    end

    def project(vertices, count)
      sx = Pico2W3D.sine(count + 18)
      cx = Pico2W3D.sine(count + 82)
      sy = Pico2W3D.sine(count * 2 + 30)
      cy = Pico2W3D.sine(count * 2 + 94)
      points = []
      vertices.each do |v|
        x = (v[0] * cy + v[2] * sy) / FIXED
        z1 = (-v[0] * sy + v[2] * cy) / FIXED
        y = (v[1] * cx - z1 * sx) / FIXED
        z = (v[1] * sx + z1 * cx) / FIXED
        depth = z + CAMERA_Z
        raise ArgumentError, "vertex at or behind camera" if depth <= 0
        points << [x, y, z, WIDTH / 2 + x * FOCAL_LENGTH / depth, HEIGHT / 2 - y * FOCAL_LENGTH / depth]
      end
      points
    end

    def visible_faces(points, faces, gem)
      visible = []
      i = 0
      while i < faces.size
        face = faces[i]
        a = points[face[0]]
        b = points[face[1]]
        c = points[face[2]]
        ux = b[0] - a[0]; uy = b[1] - a[1]; uz = b[2] - a[2]
        vx = c[0] - a[0]; vy = c[1] - a[1]; vz = c[2] - a[2]
        nx = uy * vz - uz * vy
        ny = uz * vx - ux * vz
        nz = ux * vy - uy * vx
        if nx * a[0] + ny * a[1] + nz * (a[2] + CAMERA_Z) < 0
          light = -2 * nx + 3 * ny - 5 * nz
          light = 0 if light < 0
          shade = 2 + light / (nx.abs + ny.abs + nz.abs)
          shade = 7 if shade > 7
          polygon = []
          face.each { |index| polygon << points[index] }
          visible << [polygon, @palette[gem ? 6 : i][shade]]
        end
        i += 1
      end
      visible
    end

    def bounds(points)
      box = [points[0][3], points[0][4], points[0][3], points[0][4]]
      points.each do |v|
        box[0] = v[3] if v[3] < box[0]
        box[1] = v[4] if v[4] < box[1]
        box[2] = v[3] if v[3] > box[2]
        box[3] = v[4] if v[4] > box[3]
      end
      [box[0] - 2, box[1] - 2, box[2] + 2, box[3] + 2]
    end

    def dirty_bounds(current)
      box = [current[0], current[1], current[2], current[3]]
      if @previous
        box[0] = @previous[0] if @previous[0] < box[0]
        box[1] = @previous[1] if @previous[1] < box[1]
        box[2] = @previous[2] if @previous[2] > box[2]
        box[3] = @previous[3] if @previous[3] > box[3]
      end
      @previous = current
      box[0] = 0 if box[0] < 0
      box[1] = 0 if box[1] < 0
      box[2] = WIDTH - 1 if box[2] >= WIDTH
      box[3] = HEIGHT - 1 if box[3] >= HEIGHT
      box
    end

    def span(polygon, y, color)
      left = nil
      right = nil
      i = 0
      while i < polygon.size
        a = polygon[i]
        b = polygon[(i + 1) % polygon.size]
        if a[4] > b[4]
          swap = a; a = b; b = swap
        end
        # Half-open edges at pixel centers keep adjoining faces watertight.
        if a[4] <= y && y < b[4]
          x = a[3] * 256 + ((y - a[4]) * 256 + 128) * (b[3] - a[3]) / (b[4] - a[4])
          left = x if left.nil? || x < left
          right = x if right.nil? || x > right
        end
        i += 1
      end
      return nil if left.nil?
      [(left + 127) / 256, (right + 127) / 256, color]
    end

    def draw_row(y, x0, x1, faces)
      spans = []
      faces.each do |face|
        segment = span(face[0], y, face[1])
        if segment && segment[0] < segment[1]
          i = spans.size
          while i > 0 && segment[0] < spans[i - 1][0]
            spans[i] = spans[i - 1]
            i -= 1
          end
          spans[i] = segment
        end
      end
      row = ""
      cursor = x0
      spans.each do |segment|
        left = segment[0]
        right = segment[1]
        left = cursor if left < cursor
        right = x1 + 1 if right > x1 + 1
        if left < right
          row << BLACK * (left - cursor)
          row << segment[2] * (right - left)
          cursor = right
        end
      end
      row << BLACK * (x1 + 1 - cursor)
      @display.write_pixels(row)
    end

    def frame(count)
      gem = (count / MODEL_FRAMES) % 2 == 1
      points = project(gem ? GEM_VERTICES : CUBE_VERTICES, count)
      faces = visible_faces(points, gem ? GEM_FACES : CUBE_FACES, gem)
      box = dirty_bounds(bounds(points))
      return if box[0] > box[2] || box[1] > box[3]
      @display.window(box[0], box[1], box[2], box[3])
      y = box[1]
      while y <= box[3]
        draw_row(y, box[0], box[2], faces)
        y += 1
      end
    end
  end

  def self.run
    raise ArgumentError, "MODEL_FRAMES must be a positive integer" unless MODEL_FRAMES.is_a?(Integer) && MODEL_FRAMES > 0
    raise ArgumentError, "MAX_FRAMES must be a nonnegative integer" unless MAX_FRAMES.is_a?(Integer) && MAX_FRAMES >= 0
    # mruby/c lacks Float#finite?; subtraction also rejects NaN and infinity.
    unless (FRAME_PAUSE.is_a?(Integer) || FRAME_PAUSE.is_a?(Float)) && FRAME_PAUSE >= 0 && FRAME_PAUSE - FRAME_PAUSE == 0
      raise ArgumentError, "FRAME_PAUSE must be finite and nonnegative"
    end
    raise ArgumentError, "CAMERA_Z must be a positive integer" unless CAMERA_Z.is_a?(Integer) && CAMERA_Z > 0
    raise ArgumentError, "FOCAL_LENGTH must be a positive integer" unless FOCAL_LENGTH.is_a?(Integer) && FOCAL_LENGTH > 0
    raise ArgumentError, "X_OFFSET exceeds 16-bit addresses" unless X_OFFSET.is_a?(Integer) && X_OFFSET >= 0 && X_OFFSET <= 65536 - WIDTH
    raise ArgumentError, "Y_OFFSET exceeds 16-bit addresses" unless Y_OFFSET.is_a?(Integer) && Y_OFFSET >= 0 && Y_OFFSET <= 65536 - HEIGHT
    # PicoRuby uses the RP2040_SPI0 name for RP2350 hardware SPI0 too.
    spi = SPI.new(
      unit: :RP2040_SPI0, frequency: SPI_HZ, mode: SPI_MODE,
      sck_pin: SCK_PIN, cipo_pin: CIPO_PIN, copi_pin: COPI_PIN, cs_pin: CS_PIN
    )
    spi.select if USE_CS
    display = Display.new(spi, GPIO.new(DC_PIN, GPIO::OUT), GPIO.new(RESET_PIN, GPIO::OUT))
    scene = Scene.new(display)
    puts "pico2w3d: cube / ruby gem (ST7789 240x240)"
    count = 0
    while MAX_FRAMES == 0 || count < MAX_FRAMES
      scene.frame(count)
      count += 1
      # Wrap only where both model selection and rotation repeat.
      if MAX_FRAMES == 0 && count % (2 * MODEL_FRAMES) == 0 && count % 256 == 0
        count = 0
      end
      sleep FRAME_PAUSE if FRAME_PAUSE > 0
    end
  ensure
    spi.deselect if USE_CS && spi
  end
end

Pico2W3D.run
