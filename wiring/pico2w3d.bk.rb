# Reference layout: https://github.com/breadkit/breadkit/blob/main/examples/05_sensor_demo.bk.rb
title "pico2w3d · Pico 2 W + ST7789 · 3.3V · no CS"
board :half
use_parts "parts/*.yml"

# This source models the Pico's USB-powered regulator, not an external supply.
supply :PICO_3V3_REGULATOR, voltage: 3.3, plus: "T+1", minus: "T-1"
net :VCC_3V3, at: "T+1"
net :GND, at: "T-1"

part :PICO, :pico_2_w, at: "c3", unused: (1..40).to_a - [24, 25, 26, 27, 36, 38]
offboard :LCD, :st7789_240x240, side: :right, at: "a12", unused: ["BLK"],
         address: "240x240"

net :SPI_SCK, at: "PICO.GP18"
net :SPI_MOSI, at: "PICO.GP19"
net :RESET, at: "PICO.GP20"
net :DATA_COMMAND, at: "PICO.GP21"

wire "j7", "T+7", color: "#E24B4A", layer: "1 Power"
wire "j5", "T-5", color: "#888780", route: :edge, layer: "1 Power"
wire "LCD.GND", "T-10", color: "#888780", route: :edge, layer: "1 Power"
wire "LCD.VCC", "T+11", color: "#E24B4A", route: :edge, layer: "1 Power"
wire "LCD.SCL", "j19", color: "#EF9F27", route: :edge, layer: "2 SPI"
wire "LCD.SDA", "j18", color: "#378ADD", route: :edge, layer: "2 SPI"
wire "LCD.RES", "j17", color: "#D4537E", route: :edge, layer: "3 Control"
wire "LCD.DC", "j16", color: "#639922", route: :edge, layer: "3 Control"

# Signal names are authoritative; the LCD header order is an example only.
# GP16 (MISO), GP17 (CS), VBUS, VSYS and BLK have no external connection.
expect do
  connected "PICO.36", "LCD.VCC", :VCC_3V3
  connected "PICO.38", "LCD.GND", :GND
  connected "PICO.24", "LCD.SCL"
  connected "PICO.25", "LCD.SDA"
  connected "PICO.26", "LCD.RES"
  connected "PICO.27", "LCD.DC"
  isolated :VCC_3V3, :GND, "LCD.SCL", "LCD.SDA", "LCD.RES", "LCD.DC", "LCD.BLK",
           "PICO.GP16", "PICO.GP17"
end
