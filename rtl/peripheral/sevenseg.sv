// ============================================================
// Module  : sevenseg
// Purpose : Hardware-multiplexed 8-digit 7-segment display
//           controller for the Nexys A7-100T.
//           Scans through all 8 digits at ~4 kHz (one digit
//           shown for CLK_FREQ/4000 clock cycles).
//           CPU writes a 32-bit hex value; nibble N drives
//           digit N (digit 0 = rightmost, digit 7 = leftmost).
//           MMIO base: 0x40003000
// Registers:
//   0x00  DISPLAY  — 32-bit value to show as 8 hex digits
//   0x04  CONTROL  — bit 0 = enable (0 = all digits off)
// ============================================================
module sevenseg #(
    // Reusable default; nexys_a7_top supplies the active 90 MHz SoC frequency.
    parameter int CLK_FREQ = 100_000_000
) (
    input  logic        clk,
    input  logic        rst_n,

    // MMIO register interface
    input  logic        reg_write_en,
    input  logic        reg_read_en,
    input  logic [3:0]  reg_addr,
    input  logic [31:0] reg_write_data,
    output logic [31:0] reg_read_data,

    // Nexys A7 7-segment display pins (all active LOW)
    output logic [7:0]  an,   // digit anodes: an[0]=rightmost, an[7]=leftmost
    output logic [6:0]  seg,  // segments: seg[0]=CA(a) … seg[6]=CG(g)
    output logic        dp    // decimal point (always off)
);

    localparam int SCAN_DIV = CLK_FREQ / 4_000;

    logic [31:0] display_reg;
    logic        enable_reg;

    logic [$clog2(SCAN_DIV)-1:0] scan_ctr;
    logic [2:0]  digit_sel;
    logic [3:0]  nibble;
    logic [6:0]  seg_pattern;  // active-high, bit order: gfedcba

    // --------------------------------------------------------
    // MMIO register writes
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            display_reg <= 32'b0;
            enable_reg  <= 1'b0;
        end else if (reg_write_en) begin
            case (reg_addr)
                4'h0: display_reg <= reg_write_data;
                4'h4: enable_reg  <= reg_write_data[0];
            endcase
        end
    end

    // --------------------------------------------------------
    // MMIO register reads
    // --------------------------------------------------------
    always @(*) begin
        reg_read_data = 32'b0;
        if (reg_read_en) begin
            case (reg_addr)
                4'h0:    reg_read_data = display_reg;
                4'h4:    reg_read_data = {31'b0, enable_reg};
                default: reg_read_data = 32'b0;
            endcase
        end
    end

    // --------------------------------------------------------
    // Scan counter → digit selector
    // Advances digit_sel every SCAN_DIV clock cycles
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            scan_ctr  <= 0;
            digit_sel <= 3'd0;
        end else begin
            if (scan_ctr == SCAN_DIV - 1) begin
                scan_ctr  <= 0;
                digit_sel <= digit_sel + 1;
            end else begin
                scan_ctr <= scan_ctr + 1;
            end
        end
    end

    // --------------------------------------------------------
    // Nibble select — display_reg[3:0] → digit 0 (rightmost)
    // --------------------------------------------------------
    always @(*) begin
        case (digit_sel)
            3'd0: nibble = display_reg[3:0];
            3'd1: nibble = display_reg[7:4];
            3'd2: nibble = display_reg[11:8];
            3'd3: nibble = display_reg[15:12];
            3'd4: nibble = display_reg[19:16];
            3'd5: nibble = display_reg[23:20];
            3'd6: nibble = display_reg[27:24];
            3'd7: nibble = display_reg[31:28];
        endcase
    end

    // --------------------------------------------------------
    // Hex → 7-segment lookup (active-high, gfedcba bit order)
    //   bit 0 = a (top)    bit 1 = b (top-right)
    //   bit 2 = c (bot-right) bit 3 = d (bottom)
    //   bit 4 = e (bot-left)  bit 5 = f (top-left)
    //   bit 6 = g (middle)
    // --------------------------------------------------------
    always @(*) begin
        case (nibble)
            4'h0: seg_pattern = 7'h3F;  // 0111111
            4'h1: seg_pattern = 7'h06;  // 0000110
            4'h2: seg_pattern = 7'h5B;  // 1011011
            4'h3: seg_pattern = 7'h4F;  // 1001111
            4'h4: seg_pattern = 7'h66;  // 1100110
            4'h5: seg_pattern = 7'h6D;  // 1101101
            4'h6: seg_pattern = 7'h7D;  // 1111101
            4'h7: seg_pattern = 7'h07;  // 0000111
            4'h8: seg_pattern = 7'h7F;  // 1111111
            4'h9: seg_pattern = 7'h6F;  // 1101111
            4'hA: seg_pattern = 7'h77;  // 1110111
            4'hB: seg_pattern = 7'h7C;  // 1111100
            4'hC: seg_pattern = 7'h39;  // 0111001
            4'hD: seg_pattern = 7'h5E;  // 1011110
            4'hE: seg_pattern = 7'h79;  // 1111001
            default: seg_pattern = 7'h71; // F: 1110001
        endcase
    end

    // --------------------------------------------------------
    // Drive outputs — invert for active-LOW Nexys A7 pins
    // --------------------------------------------------------
    assign an  = enable_reg ? ~(8'h01 << digit_sel) : 8'hFF;
    assign seg = ~seg_pattern;
    assign dp  = 1'b1;  // decimal point always off

endmodule
