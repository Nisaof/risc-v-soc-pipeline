// ============================================================
// File    : irq_demo.c
// Purpose : Machine timer interrupt demo for RV32IM SoC.
//
// - Timer fires every TIMER_INTERVAL clocks.
// - ISR: clears irq_flag, toggles LED[15], increments counter,
//        updates 7-segment display with counter value.
// - Main loop: echoes received UART bytes back to sender.
//
// Hardware (90 MHz): TIMER_INTERVAL = 45000000  → 0.5 s
// Simulation:         compile with -DSIM_MODE for short interval
//
// Build (hardware) : make compile_irq_demo
// Build (sim)      : make sim_irq_demo
// ============================================================

#include "../drivers/uart.h"
#include "../drivers/gpio.h"
#include "../drivers/timer.h"
#include "../drivers/sevenseg.h"

#ifdef SIM_MODE
#define TIMER_INTERVAL  500U        /* short interval for fast simulation */
#else
#define TIMER_INTERVAL  45000000U   /* 0.5 s at 90 MHz */
#endif

#define LED_IRQ_BIT  (1u << 15)     /* LED[15] toggles on each timer ISR */

static volatile unsigned int irq_count = 0;
static volatile unsigned int led_state = 0;

// Machine-mode interrupt service routine.
// GCC saves/restores all caller-saved regs and emits MRET.
void __attribute__((interrupt("machine"))) machine_trap_handler(void)
{
    unsigned int mcause;
    __asm__ volatile ("csrrs %0, mcause, x0" : "=r"(mcause));

    // Timer interrupt: bit 31 set, cause = 7
    if (mcause == 0x80000007u) {
        *((volatile unsigned int *)TIMER_STATUS) = 1; // clear sticky flag

        led_state ^= LED_IRQ_BIT;
        gpio_write((unsigned short)led_state);

        irq_count++;
        sevenseg_write(irq_count);
    }
    // All other causes (unexpected exceptions) are silently ignored here.
    // A production ISR would check MCAUSE and handle or log them.
}

static void uart_str(const char *s)
{
    while (*s) uart_putc(*s++);
}

int main(void)
{
    unsigned int uart_status;

    sevenseg_enable();
    sevenseg_write(0);
    gpio_set_direction(0xFFFF);  // all outputs
    gpio_write(0);

    uart_str("=== IRQ Demo ===\r\n");
    uart_str("Timer fires every ");
#ifdef SIM_MODE
    uart_str("500");
#else
    uart_str("45000000");
#endif
    uart_str(" clocks. Type to echo.\r\n");

    // Point MTVEC at our ISR (direct mode, bits[1:0]=00)
    __asm__ volatile ("csrrw x0, mtvec, %0" :: "r"((unsigned int)machine_trap_handler));

    // Enable machine timer interrupt in MIE (bit 7 = MTIE)
    // csrrsi immediate is 5-bit; 0x80 exceeds that, so use register form.
    { unsigned int mtie = 0x80u;
      __asm__ volatile ("csrrs x0, mie, %0" :: "r"(mtie)); }

    // Set up and start timer
    *((volatile unsigned int *)TIMER_COMPARE) = TIMER_INTERVAL;
    *((volatile unsigned int *)TIMER_CONTROL) = TIMER_ENABLE | TIMER_INT_ENABLE;

    // Enable global machine interrupts in MSTATUS (bit 3 = MIE)
    __asm__ volatile ("csrrsi x0, mstatus, 0x8");

    // Main loop: non-blocking UART echo
    for (;;) {
        uart_status = *((volatile unsigned int *)UART_STATUS);
        if (uart_status & UART_RX_VALID) {
            char c = (char)(*((volatile unsigned int *)UART_RX_DATA));
            uart_putc(c);
        }
    }

    return 0;
}
