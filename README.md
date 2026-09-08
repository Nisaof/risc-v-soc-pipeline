# Custom RISC-V SoC — RV32IM on Nexys A7

A custom RISC-V System-on-Chip implemented in SystemVerilog and verified on the
Digilent Nexys A7-100T (Artix-7). The CPU implements **RV32IM** — the full base
integer ISA plus the multiply/divide extension — in a five-stage pipeline with
forwarding, hazard handling, precise machine-mode exceptions, CSR support, and
a complete bare-metal software stack.

---

## Features

- **RV32IM CPU** — all 47 base integer + multiply/divide instructions
- **Machine-mode exception handling** — ECALL, EBREAK, illegal instruction, fetch-misalignment, timer interrupt (MRET supported)
- **Hardware misaligned load/store** — cross-boundary accesses handled in silicon, no trap
- **CSR support** — MSTATUS, MIE, MTVEC, MSCRATCH, MEPC, MCAUSE, MTVAL, MIP, MHARTID, CYCLE, INSTRET
- **Five MMIO peripherals** — UART, timer, GPIO, 8-digit 7-segment display, SPI flash
- **UART bootloader** — upload new programs over serial without re-synthesizing
- **47 official RISC-V tests** passing (39 rv32ui + 8 rv32um)
- **Full testbench suite** — 20+ simulation targets, SVA properties, integration tests

### Validated FPGA result

- **Nexys A7-100T / xc7a100tcsg324-1** — fully routed at a real 90 MHz internal SoC clock generated from the 100 MHz board oscillator
- **Timing closed** — WNS +0.085 ns, TNS 0, WHS +0.110 ns, with zero setup or hold failures
- **Physical peripherals verified** — UART TX/RX, GPIO LEDs/switches/buttons, eight-digit seven-segment display, polling timer, and timer interrupts
- **Persistent applications verified** — UART upload, reserved SPI-flash save/load, reset reload, and real power-cycle retention
- **Physical benchmark** — checksum `0x1405C478`, 106052 cycles, 39030 instructions, CPI 2.7, and 33.1 MIPS at 90 MHz

---

## Installation

### 1. Clone the repository

```bash
git clone --recurse-submodules https://github.com/blackwh1p/risc-v-soc.git
cd risc-v-soc
```

If you already cloned without `--recurse-submodules`:

```bash
git submodule update --init --recursive
```

---

### 2. Install dependencies

#### Ubuntu / Debian / WSL2

```bash
# Icarus Verilog (simulator) — must be version 11 or later
sudo apt update
sudo apt install iverilog

# Verify version (must be ≥ 11.0)
iverilog -V

# RISC-V cross-compiler
sudo apt install gcc-riscv64-unknown-elf

# Python 3 (for .bin → .mem conversion scripts)
sudo apt install python3

# GTKWave (optional — for viewing VCD waveforms)
sudo apt install gtkwave
```

#### Toolchain version check

```bash
iverilog -V                          # must show 11.0 or later
riscv64-unknown-elf-gcc --version    # must show GCC 12 or later
python3 --version                    # must show 3.8 or later
```

> **Note for Ubuntu 20.04:** `apt install iverilog` may give version 10 which does not support SystemVerilog. If so, install a pre-built binary from the [Icarus Verilog GitHub releases](https://github.com/steveicarus/iverilog/releases) or build from source.

> **Note for older GCC:** If GCC reports `error: unknown ISA extension zicsr`, change `-march=rv32im_zicsr` to `-march=rv32im` in the `CFLAGS` line in the Makefile. The generated code is identical.

---

### 3. Vivado (for FPGA programming only)

Download and install [Xilinx Vivado 2025.2](https://www.xilinx.com/support/download.html) (WebPACK edition is free and sufficient). Required only for synthesizing and programming the Nexys A7 board. All simulations and firmware builds work without Vivado.

---

### 4. Verify the installation

Run the full simulation suite — all tests must pass:

```bash
make sim_all
```

Expected output: every test prints `PASS` and ends with `$finish`. No `FAIL` lines should appear.

---

## Quick Start

### Run a simulation

```bash
make sim_cpu          # basic CPU integration test
make sim_calculator   # full-SoC calculator demo
make sim_riscv_tests  # all 47 official RISC-V compliance tests
```

### View waveforms in GTKWave

Every simulation produces a `.vcd` file. Open it after running:

```bash
make sim_cpu
gtkwave sim_cpu.vcd
```

### Build and run a firmware program

```bash
# Compile the calculator demo
make compile_calculator
# → produces sw/tests/calculator.bin and sw/tests/calculator.mem

# Simulate it
make sim_calculator

# Upload to hardware over UART (board must be running the bootloader)
python3 scripts/uart_upload.py /dev/ttyUSB0 sw/tests/calculator.bin
```

### Write your own program

1. Create `sw/tests/myprogram.c`
2. Add a compile target to the Makefile following the `compile_calculator` pattern
3. Include `sw/startup/crt0.S` and use `sw/linker/linker.ld`
4. Run `make compile_<yourprogram>` → upload `.bin` via UART or patch into bitstream

---

## Architecture

### CPU Core

The CPU is a **five-stage IF/ID/EX/MEM/WB pipeline**. On the Nexys A7, the board's
100 MHz oscillator feeds an MMCM that generates the timing-closed 90 MHz SoC clock.

```
IF → ID → EX → MEM → WB
```

Forwarding and interlock logic resolve data hazards; memory and MDU busy conditions
stall the pipeline when necessary. Cross-boundary misaligned loads and stores are
handled in hardware. Precise trap control suppresses the faulting instruction,
flushes younger work, updates MEPC/MCAUSE/MTVAL, and redirects to MTVEC. MRET and
machine-timer interrupts are supported.

**Benchmark result** (1000 iterations of add + mul + divu + branch):
`106052 cycles · 39030 instructions · CPI = 2.7 · 33.1 MIPS @ 90 MHz`

### SoC Structure

```
nexys_a7_top (FPGA top — 2-FF reset synchronizer)
└── soc_top
    ├── cpu
    │   ├── control_unit   — instruction control decoding
    │   └── datapath       — five-stage pipeline, forwarding, hazards, ALU, MDU, CSRs
    ├── imem  0x00000000   32 KB  instruction memory (bootloader lives in top 2 KB)
    ├── dmem  0x20000000   32 KB  data RAM / stack
    ├── uart  0x40000000    4 KB  serial (115 200 baud default)
    ├── timer 0x40001000    4 KB  32-bit compare timer + machine timer IRQ
    ├── gpio  0x40002000    4 KB  16-bit LEDs and switches
    ├── seg7  0x40003000    4 KB  8-digit 7-segment display
    └── spi   0x40004000    4 KB  SPI flash controller (bootloader use)
```

---

## Memory Map

| Region | Base | Size | Description |
|--------|------|------|-------------|
| IMEM | `0x00000000` | 32 KB | Instruction ROM |
| DMEM | `0x20000000` | 32 KB | Data RAM / stack |
| UART | `0x40000000` | 4 KB | Serial UART |
| Timer | `0x40001000` | 4 KB | Interval timer |
| GPIO | `0x40002000` | 4 KB | 16-bit I/O |
| 7-Segment | `0x40003000` | 4 KB | 8-digit hex display |
| SPI flash | `0x40004000` | 4 KB | SPI flash controller |
| IMEM write | `0x50000000` | 32 KB | Bootloader write window into IMEM |

Full MMIO register-level detail is in [`docs/memory_map.md`](docs/memory_map.md).

---

## Toolchain Requirements

| Tool | Version | Purpose |
|------|---------|---------|
| `iverilog` + `vvp` | ≥ 11 | RTL simulation |
| `riscv64-unknown-elf-gcc` | ≥ 12 | Cross-compiler (`-march=rv32im_zicsr -mabi=ilp32`) |
| `python3` | ≥ 3.8 | `scripts/bin_to_mem.py` — `.bin` → `.mem` conversion |
| Xilinx Vivado | 2025.2 | FPGA synthesis, implementation, programming |

Install the RISC-V toolchain on Ubuntu/Debian:
```bash
sudo apt install gcc-riscv64-unknown-elf
```

---

## Simulation

### Run all tests
```bash
make sim_all          # ~20 simulation targets — all must pass before committing
```

### Unit tests
```bash
make sim_alu          # ALU operations
make sim_mdu          # MDU multiply/divide (all RV32M special cases)
make sim_csr          # CSR file (traps, MRET, irq_pending)
make sim_regfile      # Register file
make sim_imem         # Instruction memory
make sim_dmem         # Data memory
make sim_uart         # UART TX/RX, overrun
make sim_timer        # Timer counter, compare, interrupt
make sim_gpio         # GPIO direction, read, write
make sim_sevenseg     # 7-segment display multiplexer
make sim_spi_flash    # SPI flash controller
```

### CPU tests
```bash
make sim_cpu              # Basic CPU integration
make sim_cpu_regression   # Load/store/branch/jump regression
make sim_cpu_csr          # ECALL + timer interrupt end-to-end
make sim_cpu_exceptions   # Illegal instr, EBREAK, misalign, FENCE
make sim_cpu_isa          # Compiled ISA diagnostic (53 named tests)
make sim_sva              # SVA structural properties over 895 cycles
```

### Integration tests
```bash
make sim_soc_diag         # Full-SoC diagnostic firmware
make sim_calculator       # Calculator demo (ADD/MUL/SUB/DIV via switches)
make sim_benchmark        # Performance benchmark (CPI measurement)
make sim_irq_demo         # Timer ISR + UART echo + 7-seg demo
```

### Official RISC-V test suite
```bash
make sim_riscv_tests      # All 47 official tests (rv32ui + rv32um)
```

---

## Building Firmware

```bash
make compile_sw           # Minimal test program (main.c)
make compile_isa_diag     # ISA regression firmware (isa_diag.S)
make compile_soc_diag     # Full-SoC diagnostic (soc_diag.c)
make compile_calculator   # Interactive calculator demo
make compile_benchmark    # Performance benchmark
make compile_irq_demo     # Timer interrupt demo (hardware build, 0.5 s interval)
make compile_bootloader   # UART bootloader image (baked into IMEM top 2 KB)
```

Compiled `.mem` files are loaded into `imem` at simulation time via `$readmemh`.

---

## FPGA Programming

### First-time setup (full synthesis)

1. Open Vivado, create a project, add all files under `rtl/` and `constraints/nexys_a7.xdc`
2. Set top module to `nexys_a7_top`
3. Run Synthesis → Implementation → Generate Bitstream
4. **Program Device** (JTAG) — makes the FPGA live
5. **Program Configuration Memory** (`s25fl128sxxxxxx0-spi-x1_x2_x4`) — persists across power cycles

> The FPGA must be live (JTAG-programmed first) before programming the SPI flash,
> because Vivado uses the live FPGA as a proxy to reach the flash chip.

### Bitstream memory patching

After a full synthesis run exists in `impl_1/`:

```bash
# Source Vivado tools first (WSL):
source /mnt/c/Xilinx/Vivado/2025.2/settings64.sh

# Patch address-zero IMEM contents in an existing bitstream:
make update_bitstream PROG=sw/tests/calculator.elf
# → produces nexys_a7_top_updated.bit
```

The shipping FPGA top resets at the bootloader entry (`0x7800`). Therefore an
address-zero application patched this way is not entered directly: the bootloader
still runs first and may restore the saved SPI image. Use the UART bootloader for
normal application updates unless intentionally building a different reset-vector
configuration.

### UART bootloader (no Vivado needed)

Once the bootloader bitstream is in flash:
```bash
make compile_irq_demo          # or any other firmware
python3 scripts/uart_upload.py /dev/ttyUSB0 sw/tests/irq_demo.bin
# Press CPU reset — new program runs immediately
```

The bootloader occupies the top 2 KB of IMEM (`0x7800–0x7FFF`). Uploaded programs
are written to `0x0000–0x77FF` via the IMEM write window at `0x50000000`. Each
successful UART upload is saved in the reserved application sector at SPI-flash
address `0x00F00000`; hold BTNC during reset to force `BOOT` instead of `LOAD`.

---

## Demo Programs

| Program | Build target | What it does |
|---------|-------------|--------------|
| `soc_diag.c` | `compile_soc_diag` | Diagnostic: tests BSS/data init, DMEM, GPIO, timer, UART. Pass = LEDs 0xA5A5 |
| `calculator.c` | `compile_calculator` | SW[7:0]=A, SW[15:8]=B, buttons select +/−/×/÷. Result on LEDs + 7-seg + UART |
| `irq_demo.c` | `compile_irq_demo` | Timer ISR every 0.5 s: toggles LED[15], increments 7-seg counter, main loop echoes UART |
| `benchmark.c` | `compile_benchmark` | 1000-iteration mixed workload; prints cycles, instructions, CPI, MIPS over UART |
| `bootloader.c` | `compile_bootloader` | UART bootloader: receives `.bin` over serial, writes to IMEM, jumps to entry point |
| `isa_diag.S` | `compile_isa_diag` | Assembly-level regression covering all RV32IM opcodes (53 named test cases) |

---

## Verification

### Official RISC-V test suite — 47/47 passing

| Group | Tests | Coverage |
|-------|-------|----------|
| rv32ui | 39 | All RV32I instructions including misaligned memory (`ma_data`) |
| rv32um | 8 | All RV32M multiply/divide including edge cases (div-by-zero, INT_MIN/−1) |

### Testbench suite

| Testbench | Checks | What it verifies |
|-----------|--------|-----------------|
| `tb_alu.sv` | 11 | All ALU operations |
| `tb_mdu.sv` | 20 | All MDU ops, divide-by-zero, signed overflow |
| `tb_csr.sv` | 25 | All CSR instructions, trap entry, MRET, irq_pending |
| `tb_cpu_csr.sv` | 10 | ECALL end-to-end, timer interrupt end-to-end |
| `tb_cpu_exceptions.sv` | 34 | Illegal instr, EBREAK, misaligned fetch, FENCE, hardware misaligned load/store |
| `tb_cpu_isa_diag.sv` | — | Runs compiled ISA diagnostic; checks pass signature |
| `tb_cpu_regression.sv` | 10 | Load/store/branch/jump instruction mix |
| `tb_sva.sv` | 5 | SVA structural properties over full ISA diagnostic run |
| `tb_soc_diag.sv` | — | Full-SoC diagnostic firmware integration |
| `tb_calculator.sv` | 13 | Calculator: ADD, MUL, SUB, DIV/0, DIV via UART |
| `tb_irq_demo.sv` | — | Banner received, ISR fires ≥ 3×, LED[15] toggles, 7-seg non-zero |
| `tb_benchmark.sv` | — | Benchmark completes, "Done" sentinel received |

---

## Project Structure

```
risc-v-soc/
├── rtl/
│   ├── core/
│   │   ├── cpu.sv              — top-level CPU (connects control_unit + datapath)
│   │   ├── control_unit.sv     — instruction control decoder
│   │   ├── datapath.sv         — PC, register file, ALU, MDU, CSR file, mux network
│   │   ├── csr_file.sv         — machine-mode CSRs (MSTATUS, MIE, MEPC, …, CYCLE)
│   │   ├── mdu.sv              — multi-cycle multiply/divide unit (RV32M)
│   │   ├── alu.sv              — combinational ALU (RV32I ops only)
│   │   ├── register_file.sv    — 32×32 register file (x0 hardwired zero)
│   │   ├── imm_gen.sv          — immediate decoder (all 6 immediate types)
│   │   ├── alu_ops.sv          — ALU operation encodings
│   │   └── riscv_pkg.sv        — shared constants (opcodes, states, CSR addresses)
│   ├── memory/
│   │   ├── imem.sv             — 32 KB instruction ROM (with IMEM write window)
│   │   └── dmem.sv             — 32 KB data RAM (byte-enable write port)
│   ├── peripheral/
│   │   ├── uart.sv             — UART TX/RX (configurable baud)
│   │   ├── timer.sv            — 32-bit compare timer, sticky IRQ flag
│   │   ├── gpio.sv             — 16-bit GPIO with direction register
│   │   ├── sevenseg.sv         — 8-digit 7-segment display multiplexer
│   │   └── spi_flash.sv        — SPI flash controller
│   ├── soc_top.sv              — SoC integrator (CPU + memories + MMIO decoder)
│   └── nexys_a7_top.sv         — FPGA top (clock, 2-FF reset synchronizer)
├── tb/
│   ├── core/                   — CPU and CSR unit testbenches
│   ├── memory/                 — IMEM / DMEM testbenches
│   ├── peripheral/             — Peripheral unit testbenches
│   ├── integration/            — Full-SoC software integration testbenches
│   └── riscv-tests/            — Official RISC-V test runner
├── sw/
│   ├── startup/crt0.S          — Reset handler: zero BSS, copy .data, call main()
│   ├── startup/crt0_boot.S     — Bootloader reset handler
│   ├── linker/linker.ld        — Linker script (IMEM + DMEM split)
│   ├── linker/linker_boot.ld   — Bootloader linker script
│   ├── drivers/                — C peripheral drivers (uart, gpio, timer, sevenseg, spi_flash)
│   ├── tests/                  — Demo and test programs
│   └── riscv-tests/            — riscv_test.h header for official test suite
├── third_party/riscv-tests/    — Official RISC-V test suite (git submodule)
├── constraints/nexys_a7.xdc    — Nexys A7-100T pin + bitstream constraints
├── scripts/
│   ├── bin_to_mem.py           — .bin → $readmemh .mem converter
│   ├── make_boot_mem.py        — combines user slot + bootloader into one .mem
│   └── uart_upload.py          — uploads .bin over serial to the bootloader
├── docs/
│   └── memory_map.md           — Full MMIO register-level documentation
└── Makefile                    — All build, simulation, and FPGA targets
```

---

## Key References

- [RISC-V Unprivileged ISA Specification v20191213](https://github.com/riscv/riscv-isa-manual/releases/download/Ratified-IMAFDQC/riscv-spec-20191213.pdf)
- [RISC-V Privileged ISA Specification v1.12](https://github.com/riscv/riscv-isa-manual/releases/download/Priv-v1.12/riscv-privileged-20211203.pdf)
- [Digilent Nexys A7 Reference Manual](https://digilent.com/reference/programmable-logic/nexys-a7/reference-manual)
- [riscv-tests — Official ISA Test Suite](https://github.com/riscv-software-src/riscv-tests)

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.

The RISC-V ISA specification is © RISC-V International, licensed under
Creative Commons Attribution 4.0. This repository contains an original
implementation and is not a derivative of the specification document.
