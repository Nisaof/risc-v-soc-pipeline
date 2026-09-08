// ============================================================
// Module  : uart
// Purpose : UART transmitter and receiver
//           Baud rate configurable via parameter
//           Connected to CPU via MMIO at 0x40000000
// Parameters:
//   CLK_FREQ  : system clock frequency in Hz (reusable default 100 MHz;
//               nexys_a7_top overrides it with the 90 MHz SoC clock)
//   BAUD_RATE : serial baud rate (default 115200)
// ============================================================
module uart #(
    parameter int CLK_FREQ  = 100_000_000,
    parameter int BAUD_RATE = 115_200
)(
    input  logic        clk,
    input  logic        rst_n,

    // MMIO register interface (from CPU)
    input  logic        reg_write_en,
    input  logic        reg_read_en,
    input  logic [3:0]  reg_addr,       // selects TX_DATA, RX_DATA, or STATUS
    input  logic [31:0] reg_write_data,
    output logic [31:0] reg_read_data,

    // Physical UART pins (go to Nexys A7 USB-UART bridge)
    output logic        uart_tx,        // transmit pin
    input  logic        uart_rx         // receive pin
);

    logic [$clog2(BAUD_DIV)-1:0] tx_baud_counter;
    logic [7:0]  tx_shift_reg;
    logic [3:0]  tx_bit_counter;
    logic [1:0]  tx_state;
    logic        tx_busy;
    logic [$clog2(BAUD_DIV)-1:0] rx_baud_counter;
    logic [7:0]  rx_shift_reg;
    logic [7:0]  rx_data_reg;
    logic [2:0]  rx_bit_counter;
    logic [1:0]  rx_state;
    logic        rx_valid;
    logic        rx_overrun;
    logic        uart_rx_sync_0;
    logic        uart_rx_sync_1;
    logic        rx_sample;

    // Baud rate counter limit
    localparam int BAUD_DIV = CLK_FREQ / BAUD_RATE;
    localparam int BAUD_HALF_DIV = BAUD_DIV / 2;

    // TX state definitions
    localparam logic [1:0] TX_IDLE  = 2'b00;
    localparam logic [1:0] TX_START = 2'b01;
    localparam logic [1:0] TX_DATA  = 2'b10;
    localparam logic [1:0] TX_STOP  = 2'b11;

    // RX state definitions
    localparam logic [1:0] RX_IDLE  = 2'b00;
    localparam logic [1:0] RX_START = 2'b01;
    localparam logic [1:0] RX_DATA  = 2'b10;
    localparam logic [1:0] RX_STOP  = 2'b11;

    // Synchronize asynchronous uart_rx input to clk domain
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            uart_rx_sync_0 <= 1'b1;
            uart_rx_sync_1 <= 1'b1;
        end
        else begin
            uart_rx_sync_0 <= uart_rx;
            uart_rx_sync_1 <= uart_rx_sync_0;
        end
    end

    assign rx_sample = uart_rx_sync_1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tx_state     <= TX_IDLE;
            uart_tx      <= 1'b1;    // idle HIGH
            tx_baud_counter <= 0;
            tx_bit_counter  <= 0;
            tx_busy      <= 0;
        end
        else begin
            case (tx_state)
                TX_IDLE: begin
                    uart_tx <= 1'b1;   // keep line HIGH
                    tx_busy <= 0;

                    if (reg_write_en && reg_addr == 4'h0) begin
                        tx_shift_reg[7:0] <= reg_write_data[7:0];
                        tx_busy      <= 1;
                        tx_state     <= TX_START;
                        tx_baud_counter <= 0;
                    end
                end

                TX_START: begin
                    uart_tx <= 1'b0;    // start bit — pull LOW
                    tx_busy <= 1;

                    tx_baud_counter <= tx_baud_counter + 1;
                    if (tx_baud_counter == BAUD_DIV - 1) begin
                        tx_baud_counter <= 0;
                        tx_state <= TX_DATA;
                        tx_bit_counter <= 0;
                    end
                end

                TX_DATA: begin
                    uart_tx <= tx_shift_reg[0];  // send LSB
                    tx_baud_counter <= tx_baud_counter + 1;

                    if (tx_baud_counter == BAUD_DIV - 1) begin
                        tx_baud_counter <= 0;
                        tx_shift_reg <= tx_shift_reg >> 1;
                        tx_bit_counter  <= tx_bit_counter + 1;

                        if (tx_bit_counter == 7) begin
                            tx_state    <= TX_STOP;
                            tx_bit_counter <= 0;
                        end
                    end
                end

                TX_STOP: begin
                    uart_tx <= 1'b1;    // stop bit — HIGH
                    tx_baud_counter <= tx_baud_counter + 1;

                    if (tx_baud_counter == BAUD_DIV - 1) begin
                        tx_baud_counter <= 0;
                        tx_state <= TX_IDLE;
                    end
                end
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rx_state <= RX_IDLE;
            rx_baud_counter <= 0;
            rx_bit_counter <= 0;
            rx_shift_reg <= 8'b0;
            rx_data_reg  <= 8'b0;
            rx_valid     <= 1'b0;
            rx_overrun   <= 1'b0;
        end
        else begin
            // Reading RX_DATA consumes one buffered byte and clears any overrun flag.
            if (reg_read_en && reg_addr == 4'h4) begin
                rx_valid   <= 1'b0;
                rx_overrun <= 1'b0;
            end

            case (rx_state)
                RX_IDLE: begin
                    rx_baud_counter <= 0;
                    rx_bit_counter <= 0;
                    if (rx_sample == 1'b0)
                        rx_state <= RX_START;
                end

                RX_START: begin
                    rx_baud_counter <= rx_baud_counter + 1;
                    if (rx_baud_counter == BAUD_HALF_DIV - 1) begin
                        rx_baud_counter <= 0;
                        if (rx_sample == 1'b0)
                            rx_state <= RX_DATA;
                        else
                            rx_state <= RX_IDLE;  // false start
                    end
                end

                RX_DATA: begin
                    rx_baud_counter <= rx_baud_counter + 1;
                    if (rx_baud_counter == BAUD_DIV - 1) begin
                        rx_baud_counter <= 0;
                        rx_shift_reg[rx_bit_counter] <= rx_sample;
                        if (rx_bit_counter == 3'd7) begin
                            rx_bit_counter <= 0;
                            rx_state <= RX_STOP;
                        end
                        else begin
                            rx_bit_counter <= rx_bit_counter + 1;
                        end
                    end
                end

                RX_STOP: begin
                    rx_baud_counter <= rx_baud_counter + 1;
                    if (rx_baud_counter == BAUD_DIV - 1) begin
                        rx_baud_counter <= 0;
                        if (rx_sample == 1'b1) begin
                            if (rx_valid)
                                rx_overrun <= 1'b1; // previous byte was not consumed
                            rx_data_reg <= rx_shift_reg;
                            rx_valid    <= 1'b1;
                        end
                        rx_state <= RX_IDLE;
                    end
                end
            endcase
        end
    end

    // MMIO read logic
    always @(*) begin
        reg_read_data = 32'b0;
        if (reg_read_en) begin
            case (reg_addr)
                4'h0: reg_read_data = 32'b0;                    // TX_DATA not readable
                4'h4: reg_read_data = {24'b0, rx_data_reg};     // RX_DATA byte in [7:0]
                4'h8: reg_read_data = {29'b0, rx_overrun, rx_valid, ~tx_busy}; // bit2=OVR, bit1=RXV, bit0=TXR
                default: reg_read_data = 32'b0;
            endcase
        end
    end

endmodule
