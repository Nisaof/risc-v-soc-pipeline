# Memory Map — Custom RISC-V SoC

## Address Space Overview

| Region           | Start        | End          | Size  | Description                              |
|------------------|--------------|--------------|-------|------------------------------------------|
| IMEM             | 0x00000000   | 0x00007FFF   | 32 KB | Instruction memory (read via fetch port) |
| Reserved         | 0x00008000   | 0x1FFFFFFF   | —     | Unused                                   |
| DMEM             | 0x20000000   | 0x20007FFF   | 32 KB | Data memory (RAM)                        |
| Reserved         | 0x20008000   | 0x3FFFFFFF   | —     | Unused                                   |
| MMIO             | 0x40000000   | 0x4000FFFF   | 64 KB | Memory-mapped peripherals (UART, Timer, GPIO, 7-seg) |
| IMEM write window| 0x50000000   | 0x50007FFF   | 32 KB | SW write port into IMEM (bootloader use) |

### IMEM write window (0x50000000)

SW stores to `0x50000000 + word_index * 4` write directly into IMEM instruction words
at the corresponding index. The CPU continues fetching from the normal IMEM read port
(`0x00000000`) without interruption. Used by the UART bootloader to receive a new program
over serial and write it into IMEM without a bitstream rebuild.

Bootloader layout within IMEM:
| Words     | Byte range           | Contents                                   |
|-----------|----------------------|--------------------------------------------|
| 0–7679    | 0x0000–0x77FF (30 KB)| User program (uploaded via UART)           |
| 7680–8191 | 0x7800–0x7FFF (2 KB) | Bootloader code (PC_RESET = 0x7800)        |

## MMIO Register Map

### UART (Base: 0x40000000)
| Offset | Register    | Description                  |
|--------|-------------|------------------------------|
| 0x00   | TX_DATA     | Write byte to transmit       |
| 0x04   | RX_DATA     | Read received byte (read clears RX_valid) |
| 0x08   | STATUS      | Bit0=TX_ready, Bit1=RX_valid, Bit2=RX_overrun (clears on RX_DATA read) |

### Timer (Base: 0x40001000)
| Offset | Register    | Description                  |
|--------|-------------|------------------------------|
| 0x00   | COUNTER     | Current counter value        |
| 0x04   | COMPARE     | Interrupt trigger value      |
| 0x08   | CONTROL     | Bit0=enable, Bit1=int_enable |

### GPIO (Base: 0x40002000)
| Offset | Register    | Description                  |
|--------|-------------|------------------------------|
| 0x00   | DIRECTION   | 1=output, 0=input per bit    |
| 0x04   | OUTPUT      | Write output values          |
| 0x08   | INPUT       | Read input values            |

### 7-Segment Display (Base: 0x40003000)
| Offset | Register    | Description                                      |
|--------|-------------|--------------------------------------------------|
| 0x00   | DISPLAY     | 32-bit value shown as 8 hex digits (nibble 0 = rightmost digit, nibble 7 = leftmost) |
| 0x04   | CONTROL     | Bit 0 = enable (0 = all digits off)              |

Scan rate: CLK_FREQ / 4000 (25 kHz period per digit ≈ 4 kHz multiplex rate).
Segments are active-LOW on the Nexys A7 (CA=seg[0] … CG=seg[6], DP always off).

## Reset Behavior
- PC starts at `PC_RESET` on reset (default 0x00000000; Nexys A7 bootloader build: 0x00003C00)
- Stack pointer initialized to 0x20003FFC (top of DMEM)

## Access Alignment Policy
- Byte accesses (`LB`, `LBU`, `SB`) use exact byte addresses.
- Halfword accesses (`LH`, `LHU`, `SH`) align down to an even address (`addr[0] = 0`).
- Word accesses (`LW`, `SW`) align down to a 4-byte boundary (`addr[1:0] = 0`).
