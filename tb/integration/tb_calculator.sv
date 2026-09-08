// ============================================================
// Module  : tb_calculator
// Purpose : Integration test for the calculator demo firmware.
//           Stimulates switch and button inputs; verifies LED
//           output, 7-segment display register, and one UART
//           output line.
// ============================================================

module tb_calculator;

    localparam int UART_CLK_FREQ = 100_000_000;
    localparam int UART_BAUD     = 5_000_000;
    localparam int BAUD_DIV      = UART_CLK_FREQ / UART_BAUD;  // 20
    localparam int SIM_TIMEOUT   = 100_000;

    logic        clk_100mhz;
    logic        rst_n;
    logic        uart_tx;
    logic        uart_rx;
    logic [15:0] leds;
    logic [15:0] switches;
    logic [4:0]  buttons;
    logic [7:0]  an;
    logic [6:0]  seg;
    logic        dp;

    int  error_count;

    // UART capture buffers for Test 6 (must be module-scope for iverilog)
    logic [7:0] uart_buf [0:13];
    logic       uart_ok;
    logic       uart_capture_ok;
    integer     uart_i;

    soc_top #(
        .IMEM_FILE      ("sw/tests/calculator.mem"),
        .UART_CLK_FREQ  (UART_CLK_FREQ),
        .UART_BAUD_RATE (UART_BAUD)
    ) dut (
        .clk_100mhz (clk_100mhz),
        .rst_n      (rst_n),
        .uart_tx    (uart_tx),
        .uart_rx    (uart_rx),
        .leds       (leds),
        .switches   (switches),
        .buttons    (buttons),
        .an         (an),
        .seg        (seg),
        .dp         (dp),
        .spi_sck    (),
        .spi_cs_n   (),
        .spi_mosi   (),
        .spi_miso   (1'b0),
        .spi_wp_n   (),
        .spi_hold_n ()
    );

    initial clk_100mhz = 1'b0;
    always #5 clk_100mhz = ~clk_100mhz;

    // --- Receive one UART byte; waits up to `timeout_cyc` for start bit ---
    task automatic recv_uart_byte(
        output logic [7:0] value,
        output logic       ok,
        input  int         timeout_cyc
    );
        integer t, i;
        begin
            value = 8'h00;
            ok    = 1'b0;
            t     = 0;
            while (uart_tx !== 1'b0 && t < timeout_cyc) begin
                @(posedge clk_100mhz);
                t++;
            end
            if (t < timeout_cyc) begin
                // Start bit detected — sample at middle of each data bit
                repeat (BAUD_DIV + BAUD_DIV / 2) @(posedge clk_100mhz);
                for (i = 0; i < 8; i = i + 1) begin
                    value[i] = uart_tx;
                    repeat (BAUD_DIV) @(posedge clk_100mhz);
                end
                repeat (BAUD_DIV) @(posedge clk_100mhz);  // consume stop bit
                ok = 1'b1;
            end
        end
    endtask

    // --- Wait for leds == expected, timeout_cyc limit ---
    task automatic wait_leds(
        input  logic [15:0] expected,
        input  string       name,
        input  int          timeout_cyc
    );
        integer t;
        begin
            t = 0;
            while (leds !== expected && t < timeout_cyc) begin
                @(posedge clk_100mhz);
                t++;
            end
            if (leds !== expected) begin
                error_count++;
                $display("FAIL: %s — leds timeout: expected 0x%04h, got 0x%04h", name, expected, leds);
                $display("  DEBUG: pc=0x%08h buttons=0x%0h switches=0x%04h",
                    dut.u_cpu.u_datapath.pc, buttons, switches);
            end else
                $display("PASS: %s — leds=0x%04h after %0d cycles", name, leds, t);
        end
    endtask

    // --- Check 7-seg display register value ---
    task automatic check_display(input logic [31:0] expected, input string name);
        logic [31:0] actual;
        begin
            actual = dut.u_sevenseg.display_reg;
            if (actual !== expected) begin
                error_count++;
                $display("FAIL: %s — display_reg expected 0x%08h, got 0x%08h", name, expected, actual);
            end else
                $display("PASS: %s — display_reg=0x%08h", name, actual);
        end
    endtask

    // --- Assert button for hold_cyc clocks then release ---
    task automatic press_button(input logic [4:0] btn, input int hold_cyc);
        begin
            @(posedge clk_100mhz); #1;
            buttons = btn;
            repeat (hold_cyc) @(posedge clk_100mhz);
            #1;
            buttons = 5'b00000;
        end
    endtask

    // --- Inter-test gap: hold 3500 cycles to let UART busy-wait complete (~3000 cycles
    //     at BAUD_DIV=20) before the next button press polls the main loop again.
    task automatic gap();
        begin
            buttons = 5'b00000;
            repeat (3500) @(posedge clk_100mhz);
        end
    endtask

    // --- Main test sequence ---
    initial begin
        $dumpfile("sim_calculator.vcd");
        $dumpvars(0, tb_calculator);

        error_count = 0;
        rst_n       = 1'b0;
        uart_rx     = 1'b1;
        switches    = 16'h0000;
        buttons     = 5'b00000;

        @(posedge clk_100mhz); @(posedge clk_100mhz);
        rst_n = 1'b1;

        // Boot delay: let crt0 complete and main() reach the polling loop
        repeat (600) @(posedge clk_100mhz);

        // -------------------------------------------------------
        // Test 1: ADD — A=0x0A (10), B=0x05 (5) → 15 = 0x000F
        // -------------------------------------------------------
        switches = 16'h050A;
        @(posedge clk_100mhz);
        press_button(5'b00001, 300);         // BTNU = add
        wait_leds(16'h000F, "ADD leds",  3000);
        repeat (200) @(posedge clk_100mhz);
        #1; check_display(32'h0000000F,  "ADD display_reg");
        gap();

        // -------------------------------------------------------
        // Test 2: MUL — A=0x0A (10), B=0x05 (5) → 50 = 0x0032
        // -------------------------------------------------------
        press_button(5'b00100, 300);         // BTNR = mul
        wait_leds(16'h0032, "MUL leds",  3000);
        repeat (200) @(posedge clk_100mhz);
        #1; check_display(32'h00000032,  "MUL display_reg");
        gap();

        // -------------------------------------------------------
        // Test 3: SUB — A=0x0A (10), B=0x05 (5) → 5 = 0x0005
        // -------------------------------------------------------
        press_button(5'b00010, 300);         // BTNL = sub
        wait_leds(16'h0005, "SUB leds",  3000);
        repeat (200) @(posedge clk_100mhz);
        #1; check_display(32'h00000005,  "SUB display_reg");
        gap();

        // -------------------------------------------------------
        // Test 4: DIV by zero — A=0x07, B=0x00 → 0xFFFFFFFF
        // -------------------------------------------------------
        switches = 16'h0007;
        @(posedge clk_100mhz);
        press_button(5'b01000, 300);         // BTND = div
        wait_leds(16'hFFFF, "DIV/0 leds", 3000);
        repeat (200) @(posedge clk_100mhz);
        #1; check_display(32'hFFFFFFFF,  "DIV/0 display_reg");
        gap();

        // -------------------------------------------------------
        // Test 5: DIV normal — A=0x0A / B=0x05 → 2 = 0x0002
        // -------------------------------------------------------
        switches = 16'h050A;
        @(posedge clk_100mhz);
        press_button(5'b01000, 300);         // BTND = div
        wait_leds(16'h0002, "DIV leds",  3000);
        repeat (200) @(posedge clk_100mhz);
        #1; check_display(32'h00000002,  "DIV display_reg");
        gap();

        // -------------------------------------------------------
        // Test 6: UART output for ADD — press again after full gap
        //   Expected line for 0x0A+0x05=0x0000000F:
        //   "0A+05=0000000F\n" (14 bytes, no newline captured)
        // -------------------------------------------------------
        uart_capture_ok = 1'b1;

        // Start capture before pressing the button so the receiver cannot
        // miss the first UART start bit while press_button holds BTNU.
        fork
            begin
                press_button(5'b00001, 300);  // BTNU = add
                wait_leds(16'h000F, "ADD UART leds", 2000);
            end
            begin
                for (uart_i = 0; uart_i < 14; uart_i = uart_i + 1) begin
                    recv_uart_byte(uart_buf[uart_i], uart_ok, 500);
                    if (!uart_ok) begin
                        uart_capture_ok = 1'b0;
                        uart_i = 14;  // break
                    end
                end
            end
        join

        if (!uart_capture_ok) begin
            error_count++;
            $display("FAIL: ADD UART — timed out waiting for bytes");
        end else if (uart_buf[0] !== "0" || uart_buf[1]  !== "A" ||
                     uart_buf[2] !== "+" ||
                     uart_buf[3] !== "0" || uart_buf[4]  !== "5" ||
                     uart_buf[5] !== "=" ||
                     uart_buf[6]  !== "0" || uart_buf[7]  !== "0" ||
                     uart_buf[8]  !== "0" || uart_buf[9]  !== "0" ||
                     uart_buf[10] !== "0" || uart_buf[11] !== "0" ||
                     uart_buf[12] !== "0" || uart_buf[13] !== "F") begin
            error_count++;
            $write("FAIL: ADD UART line = '");
            for (uart_i = 0; uart_i < 14; uart_i = uart_i + 1) $write("%s", uart_buf[uart_i]);
            $display("'");
        end else
            $display("PASS: ADD UART = 0A+05=0000000F");

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        if (error_count == 0)
            $display("PASS: tb_calculator — all tests passed");
        else begin
            $display("FAIL: tb_calculator — %0d error(s)", error_count);
            $fatal(1);
        end
        $finish;
    end

    // --- Global simulation timeout ---
    initial begin
        repeat (SIM_TIMEOUT) @(posedge clk_100mhz);
        $display("FAIL: tb_calculator — global timeout after %0d cycles", SIM_TIMEOUT);
        $display("  DEBUG: leds=0x%04h pc=0x%08h buttons=0x%0h",
            leds, dut.u_cpu.u_datapath.pc, buttons);
        $fatal(1);
    end

endmodule
