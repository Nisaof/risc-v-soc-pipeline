// ============================================================
// Module  : spi_flash
// Purpose : SPI master controller for the on-board N25Q128A
//           Quad-SPI flash (used in standard SPI mode only).
//           Provides a byte-transfer MMIO interface so the
//           bootloader can read and write the flash over MMIO.
//
// MMIO registers (base 0x40004000):
//   0x00  DATA   — write: start 8-bit transfer with this byte
//                  read:  byte received during last transfer
//   0x04  STATUS — bit 0 = busy (transfer in progress)
//   0x08  CS     — bit 0 = CS assert (1 drives CS_N low)
//
// SPI parameters:
//   Mode 0 (CPOL=0, CPHA=0), MSB first.
//   CLK_DIV = 4 → 8 system clocks per bit → 11.25 MHz at the FPGA's 90 MHz SoC clock.
//   Each byte transfer takes 64 system clock cycles.
//
// SCK note: spi_sck is a regular output port.  nexys_a7_top
// routes it into STARTUPE2.USRCCLKO to reach the board's CCLK
// pin.  Keeping STARTUPE2 out of this file lets Icarus simulate
// the peripheral without any Xilinx library dependency.
// ============================================================
module spi_flash (
    input  logic        clk,
    input  logic        rst_n,

    // MMIO register interface
    input  logic        reg_write_en,
    input  logic        reg_read_en,
    input  logic [3:0]  reg_addr,
    input  logic [31:0] reg_write_data,
    output logic [31:0] reg_read_data,

    // SPI pins
    output logic        spi_sck,
    output logic        spi_cs_n,
    output logic        spi_mosi,
    input  logic        spi_miso,
    output logic        spi_wp_n,    // tied HIGH: WP deasserted
    output logic        spi_hold_n   // tied HIGH: HOLD deasserted
);

    logic [7:0] tx_reg;
    logic [7:0] rx_reg;
    logic       busy;
    logic       cs_reg;
    logic [5:0] cnt;      // 0..63: 8 bits × 8 ticks per bit
    logic       running;

    // SCK toggles only during an active transfer.
    // cnt[2] is 0 for the first 4 ticks of each bit (SCK=0)
    // and 1 for the next 4 ticks (SCK=1).
    assign spi_sck    = running & cnt[2];
    assign spi_cs_n   = ~cs_reg;
    // MOSI: MSB first; cnt[5:3] = bit index (0=MSB, 7=LSB).
    // Changes on falling SCK edge (cnt[2:0] transitions 7→0),
    // which is correct for Mode 0.
    assign spi_mosi   = tx_reg[3'd7 - cnt[5:3]];
    assign spi_wp_n   = 1'b1;
    assign spi_hold_n = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_reg  <= 8'h00;
            rx_reg  <= 8'h00;
            busy    <= 1'b0;
            cs_reg  <= 1'b0;
            cnt     <= 6'h00;
            running <= 1'b0;
        end else begin
            // MMIO writes
            if (reg_write_en) begin
                case (reg_addr)
                    4'h0: if (!busy) begin  // DATA: start a byte transfer
                        tx_reg  <= reg_write_data[7:0];
                        cnt     <= 6'h00;
                        running <= 1'b1;
                        busy    <= 1'b1;
                    end
                    4'h8: cs_reg <= reg_write_data[0];  // CS control
                    default: ;
                endcase
            end

            // SPI transfer engine
            if (running) begin
                cnt <= cnt + 1;
                // Sample MISO one clock after the SCK rising edge.
                // Rising edge: cnt[2:0] transitions 3→4.
                // Sample at cnt[2:0]==4 (first cycle where SCK=1).
                if (cnt[2:0] == 3'b100)
                    rx_reg[3'd7 - cnt[5:3]] <= spi_miso;
                // Transfer complete after 64 ticks (last bit sampled at cnt=60)
                if (cnt == 6'd63) begin
                    running <= 1'b0;
                    busy    <= 1'b0;
                end
            end
        end
    end

    always_comb begin
        reg_read_data = 32'b0;
        if (reg_read_en) begin
            case (reg_addr)
                4'h0: reg_read_data = {24'b0, rx_reg};
                4'h4: reg_read_data = {31'b0, busy};
                4'h8: reg_read_data = {31'b0, cs_reg};
                default: reg_read_data = 32'b0;
            endcase
        end
    end

endmodule
