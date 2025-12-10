# zprobe

A Zig-based embedded development tool for debugging and programming microcontrollers. The goal is to
provide a probe-rs equivalent written in Zig, though it's currently a work in progress.

## Features

- **Debug Probe Support**: Connects to CMSIS-DAP compatible debug probes via USB
- **Flash Programming**: Load ELF binaries onto microcontroller targets with integrated flash
  algorithms
- **Target Control**: Halt, run, reset, and interact with ARM Cortex-M based targets
- **RTT (Real-Time Transfer)**: Stream real-time logs and debug output from running embedded
  applications
- **Memory Operations**: Read and write memory at arbitrary addresses on target devices

### Supported Chips

- RP2040 (Raspberry Pi Pico and compatible boards)
- RP2350 (Raspberry Pi Pico 2 and compatible boards) (only arm for now)

### Supported Debug Interfaces

- ARM Debug Interface (Cortex-M)
- CMSIS-DAP probes

## Usage

### List Available Chips

```bash
# List in text format (default)
zprobe list chips

# List in JSON format
zprobe list chips --format json

# List in ZON format
zprobe list chips --format zon
```

### List Connected Probes

```bash
zprobe list probes
```

### Load an ELF Binary

Load and execute an ELF file on a target microcontroller:

```bash
# Basic usage (requires --chip option)
zprobe load --chip RP2040 firmware.elf

# Specify protocol speed
zprobe load --chip RP2040 --speed 1MHz firmware.elf
zprobe load --chip RP2040 --speed 100kHz firmware.elf

# Choose how to run the binary
zprobe load --chip RP2040 --run-method call_entry firmware.elf  # Call entry point
zprobe load --chip RP2040 --run-method reboot firmware.elf      # Reboot system

# Enable RTT logging after loading
zprobe load --chip RP2040 --rtt firmware.elf
```

### Command-Line Options

#### Global Options

- `-h, --help`: Display help information

#### `list` Command

List available probes or supported chips.

```
zprobe list [OPTIONS] <REQUEST>
```

**Options:**
- `--format <FORMAT>`: Output format (text, json, zon). Default: text
- `<REQUEST>`: What to list (probes, chips)

#### `load` Command

Load an ELF file onto a target microcontroller.

```
zprobe load [OPTIONS] <ELF_FILE>
```

**Options:**
- `--speed <SPEED>`: Protocol speed (e.g., 10MHz, 100kHz). Default: 10MHz
- `--chip <CHIP>`: Target chip (required). Use `zprobe list chips` to see available chips
- `--run-method <RUN>`: How to execute the binary (call_entry, reboot)
- `--rtt`: Print RTT logs after loading the image
- `<ELF_FILE>`: Path to the ELF binary to load
