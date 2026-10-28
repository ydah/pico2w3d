# pico2w3d

A PicoRuby / R2P2 demo that renders a rotating cube and a red gemstone in a continuous loop on a Raspberry Pi Pico 2 W with an ST7789 240×240 display.
A single file, [pico2w3d.rb](pico2w3d.rb), handles 3D calculations, shading, and display output. It draws updated regions one scanline at a time without a full-screen framebuffer.

**Hardware validation is still pending.** The host checks use simulated GPIO and SPI; display output, frame rate, and long-term operation on the board remain unverified.

## Firmware for Pico 2 W

The target board is **Raspberry Pi Pico 2 W (RP2350)**, identified as `pico2_w` by R2P2.
Select the `R2P2-PICORUBY` asset containing `PICO2_W` from the [PicoRuby 4.0.5 release](https://github.com/picoruby/picoruby/releases/tag/4.0.5), and extract the `.uf2` file before flashing.
For a source build, use the `pico2_w` target in the [R2P2 build instructions](https://github.com/picoruby/picoruby/blob/4.0.5/mrbgems/picoruby-r2p2/README.md).
The host tests below use simulated hardware and do not verify a flashed firmware image.

## Run checks on your computer

Check syntax and rendering logic with desktop Ruby. No additional gems are required.

```sh
ruby -c pico2w3d.rb
ruby test_host.rb
ruby test/adversarial_contract.rb
ruby test/adversarial_geometry.rb
```

`test_host.rb` uses simulated GPIO and SPI to check display commands and RGB565 byte sequences.
It writes preview images to `tmp/host/cube.ppm` and `tmp/host/gem.ppm`.
The adversarial tests cover 10 invalid configurations, independent matrix and rational-arithmetic checks, image comparisons over a full 11,520-frame cycle, and 6,144 cases with different camera distances and focal lengths.
Test framebuffers exist only on the host. Passing these checks does not verify physical SPI communication, display output, speed, or device memory usage.

If you have host builds of PicoRuby and FemtoRuby, use `test_pico.rb` to check execution on their VMs.
This test also replaces GPIO and SPI with simulations. Do not copy it to the device.
The command below sets `MAX_FRAMES = 400` only in the generated host test file. Replace `picoruby` and `femtoruby` with the paths to your host binaries:

```sh
mkdir -p tmp/host
{
  cat test_pico.rb
  sed 's/^  MAX_FRAMES = .*/  MAX_FRAMES = 400/' pico2w3d.rb
  cat test_pico.rb
} > tmp/host/pico_smoke.rb
picoruby tmp/host/pico_smoke.rb
femtoruby tmp/host/pico_smoke.rb
```

On 2026-10-28, all 12 host Ruby tests passed. They include bounded animation counters, unchanged model/rotation phases across counter wraps, and CS release after an interrupted continuous run.
Finite 400-frame runs on MRI and PicoRuby / FemtoRuby 4.0.6 (`bda0c673`) produced identical output: 13,367,000 transmitted bytes, a maximum write size of 480 bytes, and Adler32 `2475707764`.
Continuous runs with `MAX_FRAMES = 0` completed 23,042 frames on all three VMs before a controlled test interruption, crossing two full 11,520-frame counter periods. Each frame checked model/rotation phases, window bounds, and complete scanline writes. The runs matched in total transmitted bytes and a sampled fingerprint of each write; unlike the 400-frame test, this endurance check did not compare every byte.

**Source-loading RAM is separate from the scanline buffer.** A compiler-only measurement with 32-bit pointers and 64-bit Ruby integers recorded peak heap usage of 202,016 bytes and 8,226 bytes of bytecode. This excludes the C stack, VM, and firmware.
Loading and running the source on an existing R2P2 installation remain unverified.
See [test/compiler_memory.py](test/compiler_memory.py) for the measurement setup and requirements.

A separate native 64-bit mruby/c harness with a 128 KiB allocation pool reached frames 11,520 and 23,040 with the same sampled usage of 88,960 bytes. It then exited with an uncaught intentional test-stop exception (`exit 1`), so this harness is **not counted as a completed pass**; its final checksum and CS-release checks did not run. Short probes did not reproduce the exception-handling difference. These runtime samples exclude source compilation and do not establish memory fit or indefinite operation on the board.

## Wiring

Use a Pico 2 W with R2P2 installed and a 3.3V-compatible SPI display.
Disconnect USB before changing wiring, and identify display terminals by their printed signal names rather than their order.

The [BreadKit wiring guide](wiring/README.md) covers a seven-pin display without CS.
Open the [PNG](wiring/pico2w3d.png), [SVG](wiring/pico2w3d.svg), [interactive HTML](wiring/pico2w3d.html), or [editable source](wiring/pico2w3d.bk.rb).
The Pico 2 W's USB connector faces up in the diagram. BLK is left disconnected.

| Display | Pico 2 W | Physical pin |
|---|---|---:|
| GND | GND | 38 |
| VCC | 3V3(OUT) | 36 |
| SCL / SCK / CLK | GP18 | 24 |
| SDA / DIN / MOSI | GP19 | 25 |
| RES / RST | GP20 | 26 |
| DC / A0 | GP21 | 27 |
| CS, if present | GP17 | 22 |
| BLK / BL / LED | Follow the module specifications | — |

These connections match the [official Pico 2 W pinout](https://datasheets.raspberrypi.com/picow/pico-2-w-pinout.pdf): GP18 and GP19 use SPI0, with GP20 and GP21 controlling reset and data/command.

Leave GP16 disconnected. GP16 and GP17 are included in the SPI configuration, so do not use them for other purposes.
Do not connect display VCC to VBUS or VSYS. Leave BLK disconnected until you have checked the module specifications; do not connect it directly to a GPIO or 5V.

## Run the animation

Before connecting the display, confirm that your firmware provides the `gpio` and `spi` libraries and the APIs used in [pico2w3d.rb](pico2w3d.rb).
These include `GPIO#write`, binary-string writes through `SPI#write`, and `SPI#select` / `SPI#deselect` when CS is enabled.
Keep `unit: :RP2040_SPI0`: this is also the SPI0 identifier for RP2350 in [PicoRuby's shared SPI driver](https://github.com/picoruby/picoruby/blob/4.0.5/mrbgems/picoruby-spi/ports/rp2040/spi.c#L87-L110).
Edit the constants at the top of `pico2w3d.rb` to configure the demo.
`CAMERA_Z` and `FOCAL_LENGTH` must be positive integers, offsets must be non-negative integers, and `FRAME_PAUSE` must be finite and non-negative. Invalid values raise an error before SPI is initialized.

| Setting | Default | When to change it |
|---|---|---|
| `SPI_MODE` | `3` | Start with `0` for a display with CS |
| `USE_CS` | `false` | Set to `true` for a display with CS; CS is asserted during execution and released on exit |
| `SPI_HZ` | `8_000_000` | Try `4_000_000` if output is unstable |
| `X_OFFSET` / `Y_OFFSET` | `0` / `0` | Adjust for the panel; some panels need `Y_OFFSET = 80` |
| `MADCTL` | `0x00` | Try `0x08` if red and blue are swapped |
| `INVERT` | `true` | Set to `false` if colors appear inverted |
| `MODEL_FRAMES` | `180` | Frames between model changes; must be at least 1 |
| `FRAME_PAUSE` | `0.025` | Delay after drawing, in seconds; set to `0` for speed measurements |
| `MAX_FRAMES` | `0` | Continuous operation; set to `400` for a finite first-run check |

Use the defaults for a seven-pin module without CS, and dedicate this SPI bus to the display.
For a module with CS, set `USE_CS = true` and `SPI_MODE = 0`. The program already handles `spi.select`.

Copy `pico2w3d.rb` to `/home/pico2w3d.rb` on the Pico and run it from the R2P2 shell.
Keep any existing `/home/app.rb` during this first check.

```text
cd /home
./pico2w3d.rb
```

The program clears the screen to black and prints `pico2w3d: cube / ruby gem (ST7789 240x240)` to the shell.
It draws the cube for 180 frames, then the gemstone for 180 frames, and repeats until interrupted, powered off, or an error occurs.
The animation counter wraps at a shared model/rotation boundary so it does not grow indefinitely.
For a finite first-run check, set `MAX_FRAMES = 400`; restore `0` to loop continuously.
Check positioning, colors, and any trails left by previous frames. Record the firmware version and settings that work with your panel.

## Run from USB power

Keep `MAX_FRAMES = 0` for continuous operation. Check display output and frame rate with your panel, then test an extended run.
For automatic startup, back up any existing `/home/app.rb` to your computer and confirm how to restore or remove it.
Then save the following as `/home/app.rb`:

```ruby
load "/home/pico2w3d.rb"
```

Replacing `app.rb` stops any previous startup code in that file from running.
Disconnect the computer, use a USB power supply, and power-cycle the device three times to check that it starts each time.

## Troubleshooting

For API errors, record the error message and R2P2 version, then check the GPIO and SPI APIs listed above.
If the backlight is on but no image appears, check SPI mode, CS configuration, SCL/SDA, DC/RES, and GND in that order.
For shifted or incorrect colors, adjust the panel settings in the configuration table.

Loading arbitrary models, input handling, multiple objects, concave geometry, textures, and tearing prevention are outside the scope of this demo.
