// ============================================================
// File    : benchmark.c
// Purpose : CPU performance benchmark for RV32IM SoC.
//
// Runs 1000 iterations of a mixed workload (add, mul, div,
// branch) and reports via UART:
//   - Total cycles
//   - Total instructions retired
//   - Effective CPI  = cycles / instructions
//   - Effective MIPS = (instructions / cycles) * 90  (at 90 MHz)
//
// Build: make compile_benchmark
// ============================================================

#include "../drivers/uart.h"

static unsigned int rdcycle(void)
{
    unsigned int v;
    __asm__ volatile ("csrrs %0, cycle, x0" : "=r"(v));
    return v;
}

static unsigned int rdinstret(void)
{
    unsigned int v;
    __asm__ volatile ("csrrs %0, instret, x0" : "=r"(v));
    return v;
}

static void uart_uint(unsigned int v)
{
    char buf[12];
    int i = 0;
    if (v == 0) { uart_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) uart_putc(buf[i]);
}

static void uart_str(const char *s)
{
    while (*s) uart_putc(*s++);
}

static void uart_hex32(unsigned int v)
{
    int i;
    uart_putc('0'); uart_putc('x');
    for (i = 28; i >= 0; i -= 4) {
        unsigned int n = (v >> i) & 0xFu;
        uart_putc((char)(n < 10u ? '0' + n : 'A' + n - 10u));
    }
}

int main(void)
{
    unsigned int c0, c1, i0, i1, cycles, instrs;
    unsigned int acc = 0;
    unsigned int a, b;
    int k;

    uart_str("=== RV32IM Benchmark ===\r\n");
    uart_str("Workload: 1000 iterations (add, mul, div, branch)\r\n");

    c0 = rdcycle();
    i0 = rdinstret();

    for (k = 1; k <= 1000; k++) {
        a = (unsigned int)k;
        b = (unsigned int)(k + 1);

        acc += a + b;            // add
        acc += a * b;            // mul
        if (b != 0)
            acc += a / b;        // divu
        if (acc & 1u)
            acc ^= 0xDEADu;      // branch (taken ~50%)
    }

    c1 = rdcycle();
    i1 = rdinstret();

    cycles = c1 - c0;
    instrs = i1 - i0;

    uart_str("Result checksum : ");
    uart_hex32(acc);
    uart_str("\r\n");

    uart_str("Cycles          : ");
    uart_uint(cycles);
    uart_str("\r\n");

    uart_str("Instructions    : ");
    uart_uint(instrs);
    uart_str("\r\n");

    // CPI = cycles / instructions (integer, one decimal digit via remainder)
    if (instrs > 0) {
        unsigned int cpi_int  = cycles / instrs;
        unsigned int cpi_frac = (cycles % instrs) * 10u / instrs;
        uart_str("CPI             : ");
        uart_uint(cpi_int);
        uart_putc('.');
        uart_uint(cpi_frac);
        uart_str("\r\n");

        // MIPS at 90 MHz = (instructions / cycles) * 90
        // = instructions * 90 / cycles
        unsigned int mips_int  = instrs * 90u / cycles;
        unsigned int mips_frac = (instrs * 90u % cycles) * 10u / cycles;
        uart_str("MIPS @ 90 MHz   : ");
        uart_uint(mips_int);
        uart_putc('.');
        uart_uint(mips_frac);
        uart_str("\r\n");
    }

    uart_str("=== Done ===\r\n");

    for (;;) {}
    return 0;
}
