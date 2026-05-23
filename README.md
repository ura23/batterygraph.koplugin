# BatteryGraph for KOReader

BatteryGraph is a lightweight, highly optimized plugin for [KOReader](https://github.com/koreader/koreader) that tracks your device's battery usage over time and displays it as an easy-to-read graph.

## Features

- **Accurate Tracking**: Automatically records battery percentage drops and charging sessions in the background.
- **E-Ink Optimized UI**: The graph rendering algorithm is specifically tailored for E-Ink displays, using an optimized Bresenham fast-path algorithm to ensure snappy performance and fast screen updates.
- **Ultra-Low Memory Footprint**: Uses a Structure of Arrays (SoA) data model. This allows the plugin to store up to a year of battery history with almost zero Lua Garbage Collection pressure and instant load times, even on older E-Readers.
- **Energy Efficient**: It doesn't waste your battery to track your battery! The plugin only writes to the database when a physical change occurs (e.g., capacity drops by 1% or the charger is plugged/unplugged), keeping background activity and disk I/O to an absolute minimum.
- **Flexible View Modes**: View your battery curve for the **Current Cycle** (since last charge), or look back over **30, 90, 180, or 365 days**.
- **Smooth Interpolation**: The graph smartly interpolates the battery discharge rate to the current moment, providing a smooth, realistic discharge curve rather than jagged artificial steps.

## Installation

1. Download or clone this repository.
2. Place the `batterygraph.koplugin` folder inside your KOReader plugins directory:
   - Usually located at `koreader/plugins/` on your device.
3. Restart KOReader.
4. You can now access the **Battery Graph** from the KOReader main menu.

## How it Works

The plugin relies on a lightweight background process that periodically checks the battery status, as well as listening to system events (like device suspend/resume and charger connections). Data is kept in memory and is only flushed to disk when necessary (like when the device goes to sleep), ensuring your E-Reader's flash memory isn't degraded by constant writes.
