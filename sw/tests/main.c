// ============================================================
// File    : main.c
// Purpose : First bare-metal test program for RV32IM SoC
//           Tests UART, GPIO, and Timer peripherals
// ============================================================

#include "../drivers/uart.h"
#include "../drivers/gpio.h"
#include "../drivers/timer.h"

int main(void)
{
    // --- Step 1: Send boot message over UART ---
    uart_puts("Hello, RISC-V!\n");

    // --- Step 2: Set all GPIO pins as output ---
    gpio_set_direction(0xFFFF);

    // --- Step 3: Turn on all LEDs ---
    gpio_write(0xFFFF);

    // --- Step 4: Loop forever ---
    while (1)
    {
        // --- Step 4a: Wait ~500ms using timer ---
        // Reset counter to 0, then enable with compare=max so the hardware
        // never resets the counter during our wait. Poll until count reaches
        // target — safe because the counter only increases monotonically.
        timer_clear();
        timer_set(0xFFFFFFFF);
        while (timer_read() < 45000000) {}

        // --- Step 4b: Toggle LEDs ---
        static unsigned int led_state = 0xFFFF;
        led_state = (~led_state) & 0xFFFF;
        gpio_write(led_state);

        // --- Step 4c: Send tick message ---
        uart_puts("Tick!\n");
    }
    return 0;
}
