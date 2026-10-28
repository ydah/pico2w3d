# Host-only ST7789 decoder: the full framebuffer is never deployed to PicoRuby.
module Host
  class Stopped < StandardError; end
  class << self
    attr_accessor :events
  end
  self.events = []

  def self.assert(condition, message)
    raise message unless condition
  end
end

class GPIO
  OUT = 1
  @pins = {}
  class << self
    attr_reader :pins
  end
  attr_reader :pin, :value

  def initialize(pin, direction)
    Host.assert(direction == OUT, "GPIO must be an output")
    @pin = pin
    self.class.pins[pin] = nil
  end

  def write(value)
    Host.assert([0, 1].include?(value), "invalid GPIO value")
    @value = value
    self.class.pins[@pin] = value
    Host.events << [:gpio, @pin, value]
  end
end

class SPI
  @instances = []
  class << self
    attr_reader :instances
    attr_accessor :stop_after_windows
  end
  attr_reader :options, :screen, :commands, :windows, :row_lengths,
              :byte_count, :write_count, :select_count, :deselect_count

  def initialize(**options)
    @options = options
    @screen = Array.new(240 * 240, 0)
    @commands = []
    @windows = []
    @row_lengths = []
    @byte_count = @write_count = @select_count = @deselect_count = 0
    @pending = 0
    self.class.instances << self
  end

  def select
    @select_count += 1
    @selected = true
  end

  def deselect
    @deselect_count += 1
    @selected = false
  end

  def write(data)
    Host.assert(data.is_a?(String), "SPI must receive bytes as a String")
    Host.assert(!Pico2W3D::USE_CS || @selected, "write while CS is inactive")
    dc = GPIO.pins.fetch(Pico2W3D::DC_PIN)
    @byte_count += data.bytesize
    @write_count += 1
    if dc == 0
      finish!
      Host.assert(data.bytesize == 1, "commands are exactly one byte")
      @command = data.getbyte(0)
      @commands << [@command, "".b]
      start_window if @command == 0x2c
    else
      Host.assert(dc == 1 && @command, "data sent without a command")
      if @command == 0x2c
        write_row(data)
      else
        @commands.last[1] << data
        @columns = data.unpack("n2") if @command == 0x2a
        @rows = data.unpack("n2") if @command == 0x2b
      end
    end
    data.bytesize
  end

  def finish!
    Host.assert(@pending.zero?, "window was not completely filled: #{@pending} pixels remain")
  end

  def start_window
    raise Host::Stopped, "simulated SPI failure" if self.class.stop_after_windows == @windows.length
    Host.assert(@columns && @rows, "RAMWR before address window")
    x0, x1 = @columns.map { |x| x - Pico2W3D::X_OFFSET }
    y0, y1 = @rows.map { |y| y - Pico2W3D::Y_OFFSET }
    Host.assert(0 <= x0 && x0 <= x1 && x1 < 240, "columns outside the screen")
    Host.assert(0 <= y0 && y0 <= y1 && y1 < 240, "rows outside the screen")
    @windows << [x0, y0, x1, y1]
    @width = x1 - x0 + 1
    @pending = @width * (y1 - y0 + 1)
    @cursor_x = x0
    @cursor_y = y0
  end

  def write_row(data)
    Host.assert(data.bytesize == @width * 2, "each SPI pixel write must contain one complete row")
    Host.assert(data.bytesize <= 480, "full-screen framebuffer sent instead of a row")
    Host.assert(@pending >= @width, "too many pixels for the address window")
    @row_lengths << data.bytesize
    @screen[@cursor_y * 240 + @cursor_x, @width] = data.unpack("n*")
    @cursor_y += 1
    @pending -= @width
  end
end

module Kernel
  def sleep(seconds)
    Host.events << [:sleep, seconds]
    0
  end
end
