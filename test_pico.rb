# Host-only smoke test: never run on the board.
# Build a temporary copy with MAX_FRAMES = 400, then concatenate this file,
# that copy, and this file (see the exact command in README.md).
# Run that combined file with picoruby or femtoruby (see README.md).
# The first visit installs stubs; the second checks the completed application.

def smoke_assert(condition, message)
  raise "FAIL: #{message}" unless condition
end

if $pico2w3d_smoke_ready
  smoke_assert($pico2w3d_smoke_spi, "application must start automatically")
  $pico2w3d_smoke_spi.finish
  puts "PASS: #{RUBY_ENGINE}, #{Pico2W3D::MAX_FRAMES} frames, #{$pico2w3d_smoke_spi.total_bytes} SPI bytes, max write #{$pico2w3d_smoke_spi.max_row_bytes} bytes, Adler32 #{$pico2w3d_smoke_spi.checksum}"
else
  $pico2w3d_smoke_ready = true
  $pico2w3d_smoke_dc = 1
  $pico2w3d_smoke_spi = nil
  $LOADED_FEATURES << "gpio"
  $LOADED_FEATURES << "spi"

  class Object
    def sleep(duration)
      smoke_assert(duration >= 0, "negative sleep")
    end
  end

  class GPIO
    OUT = 1

    def initialize(pin, direction)
      smoke_assert(direction == OUT, "GPIO output mode")
      @pin = pin
    end

    def write(value)
      smoke_assert(value == 0 || value == 1, "GPIO level")
      $pico2w3d_smoke_dc = value if @pin == Pico2W3D::DC_PIN
    end
  end

  class SPI
    attr_reader :windows, :total_bytes, :max_row_bytes, :selected

    def initialize(unit:, frequency:, mode:, sck_pin:, cipo_pin:, copi_pin:, cs_pin:)
      smoke_assert(Pico2W3D::MAX_FRAMES > 0, "use a finite MAX_FRAMES for the smoke test")
      smoke_assert(unit == :RP2040_SPI0, "SPI unit")
      smoke_assert(frequency == Pico2W3D::SPI_HZ && mode == Pico2W3D::SPI_MODE, "SPI configuration")
      smoke_assert(sck_pin == Pico2W3D::SCK_PIN && copi_pin == Pico2W3D::COPI_PIN, "SPI output pins")
      smoke_assert(cipo_pin == Pico2W3D::CIPO_PIN && cs_pin == Pico2W3D::CS_PIN, "SPI input/CS pins")
      @windows = 0
      @total_bytes = 0
      @max_row_bytes = 0
      @remaining = 0
      @selected = false
      @sum1 = 1
      @sum2 = 0
      $pico2w3d_smoke_spi = self
    end

    def select
      @selected = true
    end

    def deselect
      @selected = false
    end

    def write(data)
      smoke_assert(data.is_a?(String), "SPI writes must use Strings")
      size = data.bytesize
      smoke_assert(size > 0 && size <= 480, "bounded nonempty SPI write")
      @total_bytes += size
      # Adler32 covers every transmitted byte without allocating a byte array.
      a = @sum1
      b = @sum2
      i = 0
      while i < size
        a += data.getbyte(i)
        b += a
        i += 1
      end
      @sum1 = a % 65521
      @sum2 = b % 65521
      if $pico2w3d_smoke_dc == 0
        smoke_assert(size == 1, "one-byte command")
        smoke_assert(@remaining == 0, "previous window completed")
        @command = data.getbyte(0)
        start_window if @command == 0x2c
      elsif @command == 0x2a || @command == 0x2b
        smoke_assert(size == 4, "four-byte coordinate range")
        first = data.getbyte(0) * 256 + data.getbyte(1)
        last = data.getbyte(2) * 256 + data.getbyte(3)
        if @command == 0x2a
          @left = first - Pico2W3D::X_OFFSET
          @right = last - Pico2W3D::X_OFFSET
        else
          @top = first - Pico2W3D::Y_OFFSET
          @bottom = last - Pico2W3D::Y_OFFSET
        end
      elsif @command == 0x2c
        smoke_assert(size == (@right - @left + 1) * 2, "one complete scanline per write")
        @remaining -= size
        smoke_assert(@remaining >= 0, "no window overrun")
        @max_row_bytes = size if size > @max_row_bytes
      end
      size
    end

    def start_window
      smoke_assert(0 <= @left && @left <= @right && @right < Pico2W3D::WIDTH, "window columns")
      smoke_assert(0 <= @top && @top <= @bottom && @bottom < Pico2W3D::HEIGHT, "window rows")
      @remaining = (@right - @left + 1) * (@bottom - @top + 1) * 2
      @windows += 1
    end

    def finish
      smoke_assert(@remaining == 0, "last window completed")
      smoke_assert(@windows == Pico2W3D::MAX_FRAMES + 1, "clear plus configured number of frames")
      smoke_assert(!@selected, "CS released after run")
    end

    def checksum
      (@sum2 << 16) | @sum1
    end
  end
end
