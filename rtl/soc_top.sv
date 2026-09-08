// ============================================================
// Module  : soc_top
// Purpose : Top-level SoC module
//           Instantiates CPU, memories, and all peripherals
//           This is the root module for Vivado synthesis
// ============================================================
module soc_top #(
    parameter int          IMEM_DEPTH     = 8192,
    parameter              IMEM_FILE      = "soc_diag.mem",
    parameter int          DMEM_DEPTH     = 8192,
    parameter int          UART_CLK_FREQ  = 100_000_000,
    parameter int          UART_BAUD_RATE = 115_200,
    parameter logic [31:0] PC_RESET       = 32'h0000_0000
) (
    // SoC-domain clock input. The FPGA top drives this legacy-named port at 90 MHz.
    input  logic        clk_100mhz,

    // Nexys A7 CPU reset button (active low)
    input  logic        rst_n,

    // UART pins (connected to USB-UART bridge on Nexys A7)
    output logic        uart_tx,
    input  logic        uart_rx,

    // LED outputs (16 LEDs on Nexys A7)
    output logic [15:0] leds,

    // Switch inputs (16 switches on Nexys A7)
    input  logic [15:0] switches,

    // Button inputs: [0]=BTNU [1]=BTNL [2]=BTNR [3]=BTND [4]=BTNC
    input  logic [4:0]  buttons,

    // 7-segment display (8-digit, active LOW — Nexys A7)
    output logic [7:0]  an,
    output logic [6:0]  seg,
    output logic        dp,

    // SPI flash (N25Q128A on-board Quad-SPI flash)
    output logic        spi_sck,
    output logic        spi_cs_n,
    output logic        spi_mosi,
    input  logic        spi_miso,
    output logic        spi_wp_n,
    output logic        spi_hold_n
);

    // CPU memory interface
    logic [31:0] imem_addr, imem_data, imem_read_data;
    logic [31:0] dmem_addr, dmem_write_data, dmem_read_data, dmem_read_data_raw;
    logic [3:0]  dmem_byte_enable;
    logic        dmem_write_en, dmem_read_en;

    // Peripheral MMIO interface
    logic        mmio_write_en, mmio_read_en;
    logic [3:0]  mmio_reg_addr;
    logic [31:0] mmio_write_data, mmio_read_data;
    logic        dmem_sel, imem_sel;

    // Peripheral select signals
    logic        uart_sel, timer_sel, gpio_sel, sevenseg_sel, flash_sel, imem_win_sel;

    // IMEM bootloader write port
    logic        imem_write_en;
    logic [12:0] imem_write_addr;
    logic [31:0] imem_write_data;

    // Timer interrupt wire
    logic        timer_irq;

    // Peripheral read data
    logic [31:0] uart_read_data, timer_read_data, gpio_read_data, sevenseg_read_data, flash_read_data;

    // Registered MMIO read data — captures combinational peripheral output at the
    // end of STATE_MEMORY so STATE_WRITEBACK sees stable data without re-asserting
    // mem_read (which would double-fire any future FIFO pop or auto-clearing flag).
    logic [31:0] mmio_read_data_reg;

    always_ff @(posedge clk_100mhz) begin
        if (!rst_n)
            mmio_read_data_reg <= 32'b0;
        else if (dmem_read_en && (dmem_addr[31:16] == 16'h4000))
            mmio_read_data_reg <= mmio_read_data;
        // SPI flash STATUS/DATA reads bypass the register (must be live for polling)
        else if (dmem_read_en && flash_sel)
            mmio_read_data_reg <= flash_read_data;
    end

    // Select which peripheral based on address
    assign dmem_sel     = (dmem_addr[31:15] == 17'h4000);               // 0x20000000–0x20007FFF
    assign imem_sel     = (dmem_addr[31:15] == 17'h0);                  // 0x00000000–0x00007FFF
    assign imem_win_sel = (dmem_addr[31:15] == 17'hA000);              // 0x50000000–0x50007FFF (IMEM write window)
    assign uart_sel     = (dmem_addr[31:16] == 16'h4000) && (dmem_addr[15:12] == 4'h0);
    assign timer_sel    = (dmem_addr[31:16] == 16'h4000) && (dmem_addr[15:12] == 4'h1);
    assign gpio_sel     = (dmem_addr[31:16] == 16'h4000) && (dmem_addr[15:12] == 4'h2);
    assign sevenseg_sel = (dmem_addr[31:16] == 16'h4000) && (dmem_addr[15:12] == 4'h3);
    assign flash_sel    = (dmem_addr[31:16] == 16'h4000) && (dmem_addr[15:12] == 4'h4);

    assign imem_write_en   = dmem_write_en && imem_win_sel;
    assign imem_write_addr = dmem_addr[14:2];
    assign imem_write_data = dmem_write_data;

    // Route MMIO signals to correct peripheral
    assign mmio_write_en   = dmem_write_en;
    assign mmio_read_en    = dmem_read_en;
    assign mmio_reg_addr   = dmem_addr[3:0];
    assign mmio_write_data = dmem_write_data;

    cpu #(
        .PC_RESET         (PC_RESET)
    ) u_cpu (
        .clk              (clk_100mhz),
        .rst_n            (rst_n),
        .irq_m_timer      (timer_irq),
        .imem_addr        (imem_addr),
        .imem_data        (imem_data),
        .dmem_addr        (dmem_addr),
        .dmem_write_data  (dmem_write_data),
        .dmem_byte_enable (dmem_byte_enable),
        .dmem_write_en    (dmem_write_en),
        .dmem_read_en     (dmem_read_en),
        .dmem_read_data   (dmem_read_data)
    );

    imem #(
        .MEM_DEPTH (IMEM_DEPTH),
        .MEM_FILE  (IMEM_FILE)
    ) u_imem (
        .clk            (clk_100mhz),
        .addr           (imem_addr),
        .data           (imem_data),
        .data_addr      (dmem_addr),
        .data_read_data (imem_read_data),
        .write_en       (imem_write_en),
        .write_addr     (imem_write_addr),
        .write_data     (imem_write_data)
    );

    dmem #(
        .MEM_DEPTH (DMEM_DEPTH)
    ) u_dmem (
        .clk         (clk_100mhz),
        .read_en     (dmem_read_en && dmem_sel),
        .addr        (dmem_addr),
        .read_data   (dmem_read_data_raw),
        .write_en    (dmem_write_en && dmem_sel),
        .byte_enable (dmem_byte_enable),
        .write_data  (dmem_write_data)
    );

    gpio u_gpio (
        .clk (clk_100mhz),
        .rst_n (rst_n),

        .reg_write_en (mmio_write_en && gpio_sel),
        .reg_read_en (mmio_read_en && gpio_sel),
        .reg_addr (mmio_reg_addr),
        .reg_write_data (mmio_write_data),
        .reg_read_data (gpio_read_data),

        .gpio_out (leds),
        .gpio_in (switches),
        .gpio_buttons (buttons)
    );

    timer u_timer (
        .clk (clk_100mhz),
        .rst_n (rst_n),

        .reg_write_en (mmio_write_en && timer_sel),
        .reg_read_en (mmio_read_en && timer_sel),
        .reg_addr (mmio_reg_addr),
        .reg_write_data (mmio_write_data),
        .reg_read_data (timer_read_data),

        .timer_interrupt (timer_irq)
    );

    sevenseg #(
        .CLK_FREQ (UART_CLK_FREQ)
    ) u_sevenseg (
        .clk           (clk_100mhz),
        .rst_n         (rst_n),
        .reg_write_en  (mmio_write_en && sevenseg_sel),
        .reg_read_en   (mmio_read_en  && sevenseg_sel),
        .reg_addr      (mmio_reg_addr),
        .reg_write_data(mmio_write_data),
        .reg_read_data (sevenseg_read_data),
        .an            (an),
        .seg           (seg),
        .dp            (dp)
    );

    uart #(
        .CLK_FREQ  (UART_CLK_FREQ),
        .BAUD_RATE (UART_BAUD_RATE)
    ) u_uart (
        .clk (clk_100mhz),
        .rst_n (rst_n),

        .reg_write_en (mmio_write_en && uart_sel),
        .reg_read_en (mmio_read_en && uart_sel),
        .reg_addr (mmio_reg_addr),
        .reg_write_data (mmio_write_data),
        .reg_read_data (uart_read_data),

        .uart_tx (uart_tx),
        .uart_rx (uart_rx)
    );

    spi_flash u_spi_flash (
        .clk           (clk_100mhz),
        .rst_n         (rst_n),
        .reg_write_en  (mmio_write_en && flash_sel),
        .reg_read_en   (mmio_read_en  && flash_sel),
        .reg_addr      (mmio_reg_addr),
        .reg_write_data(mmio_write_data),
        .reg_read_data (flash_read_data),
        .spi_sck       (spi_sck),
        .spi_cs_n      (spi_cs_n),
        .spi_mosi      (spi_mosi),
        .spi_miso      (spi_miso),
        .spi_wp_n      (spi_wp_n),
        .spi_hold_n    (spi_hold_n)
    );

    // Combine peripheral read data
    always @(*) begin
        mmio_read_data = 32'b0;
        if (uart_sel)           mmio_read_data = uart_read_data;
        else if (timer_sel)     mmio_read_data = timer_read_data;
        else if (gpio_sel)      mmio_read_data = gpio_read_data;
        else if (sevenseg_sel)  mmio_read_data = sevenseg_read_data;
        else if (flash_sel)     mmio_read_data = flash_read_data;
    end

    // Route read data back to CPU. Out-of-region reads return
    // zero rather than stale DMEM data so a stray pointer is
    // visibly wrong instead of silently aliasing.
    assign dmem_read_data = (dmem_addr[31:28] == 4'h4) ? mmio_read_data_reg :
                            imem_sel                    ? imem_read_data :
                            dmem_sel                    ? dmem_read_data_raw :
                                                          32'b0;

endmodule
