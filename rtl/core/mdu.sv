// ============================================================
// Module  : mdu
// Purpose : Multi-cycle multiplier/divider for the RV32M
//           extension.
//
//   - MUL/MULH/MULHSU/MULHU : 4 MDU-internal cycles
//       S_IDLE    : latch pre-extended 64-bit operands (breaks
//                   the timing-critical start→multiply path so
//                   Vivado sees reg→DSP→reg in S_MUL_LOAD and
//                   supports timing closure on Artix-7).
//       S_MUL_LOAD: compute 64-bit product from latched operands.
//       S_MUL     : select and register the requested half.
//       S_DONE    : assert done for one cycle.
//
//   - DIV/DIVU/REM/REMU : 35 MDU-internal cycles
//       S_IDLE    : latch absolute-value operands, detect special
//                   cases, start 32-iteration restoring division.
//       S_DIV×32  : one restoring step per cycle.
//       S_DIV×1   : finalize quotient/remainder with sign correction.
//       S_DONE    : assert done for one cycle.
//                   Special cases (div-by-zero, signed overflow)
//                   follow the RV32M spec.
//
// CPU cycle counts (from instruction FETCH to WRITEBACK):
//   MUL/MULH/MULHSU/MULHU  : 7  (4 base + 3 STATE_MDU)
//   DIV/DIVU/REM/REMU      : 38 (4 base + 34 STATE_MDU)
// ============================================================

import alu_ops::*;

module mdu (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        start,        // pulsed by control unit in EXECUTE
    input  logic [4:0]  operation,    // ALU_MUL / MULH / MULHSU / MULHU / DIV / DIVU / REM / REMU
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,

    output logic [31:0] result,
    output logic        busy,         // HIGH while a request is in flight
    output logic        done          // 1-cycle pulse when result is ready
);

    // --------------------------------------------------------
    // FSM states
    // --------------------------------------------------------
    localparam logic [2:0] S_IDLE     = 3'd0;
    localparam logic [2:0] S_MUL_LOAD = 3'd1; // multiply: latch pre-extended operands
    localparam logic [2:0] S_MUL      = 3'd2; // multiply: register product half
    localparam logic [2:0] S_DIV      = 3'd3;
    localparam logic [2:0] S_DONE     = 3'd4;

    logic [2:0]  state;

    // --------------------------------------------------------
    // Working registers
    // --------------------------------------------------------
    logic [63:0] mul_a_reg;          // 64-bit pre-extended multiplicand
    logic [63:0] mul_b_reg;          // 64-bit pre-extended multiplier
    logic [63:0] mul_full;           // registered DSP product
    logic [5:0]  iter;
    logic [63:0] div_acc;            // {remainder, in-flight quotient}
    logic [31:0] div_divisor;
    logic        latched_mulh;
    logic        latched_rem;
    logic        latched_neg_q;
    logic        latched_neg_r;
    logic        latched_special;
    logic [31:0] latched_special_value;
    logic [31:0] result_reg;

    // --------------------------------------------------------
    // Operation decode (combinational; held stable while busy)
    // --------------------------------------------------------
    logic is_mul, is_mulh, is_mulhsu, is_mulhu;
    logic is_div, is_divu, is_rem, is_remu;
    logic is_signed_div, is_mul_op, is_div_op;
    logic sign_a, sign_b;
    logic [31:0] abs_a, abs_b;

    assign is_mul        = (operation == ALU_MUL);
    assign is_mulh       = (operation == ALU_MULH);
    assign is_mulhsu     = (operation == ALU_MULHSU);
    assign is_mulhu      = (operation == ALU_MULHU);
    assign is_div        = (operation == ALU_DIV);
    assign is_divu       = (operation == ALU_DIVU);
    assign is_rem        = (operation == ALU_REM);
    assign is_remu       = (operation == ALU_REMU);
    assign is_signed_div = is_div || is_rem;
    assign is_mul_op     = is_mul || is_mulh || is_mulhsu || is_mulhu;
    assign is_div_op     = is_div || is_divu || is_rem || is_remu;
    assign sign_a        = operand_a[31];
    assign sign_b        = operand_b[31];
    assign abs_a         = (is_signed_div && sign_a) ? (~operand_a + 32'b1) : operand_a;
    assign abs_b         = (is_signed_div && sign_b) ? (~operand_b + 32'b1) : operand_b;

    // --------------------------------------------------------
    // One restoring-division step (combinational)
    // --------------------------------------------------------
    logic [63:0] div_shifted;
    logic [31:0] div_trial;
    logic        div_subtract;

    assign div_shifted  = div_acc << 1;
    assign div_trial    = div_shifted[63:32] - div_divisor;
    assign div_subtract = (div_shifted[63:32] >= div_divisor);

    // --------------------------------------------------------
    // FSM
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state                 <= S_IDLE;
            mul_a_reg             <= 64'b0;
            mul_b_reg             <= 64'b0;
            mul_full              <= 64'b0;
            iter                  <= 6'd0;
            div_acc               <= 64'b0;
            div_divisor           <= 32'b0;
            latched_mulh          <= 1'b0;
            latched_rem           <= 1'b0;
            latched_neg_q         <= 1'b0;
            latched_neg_r         <= 1'b0;
            latched_special       <= 1'b0;
            latched_special_value <= 32'b0;
            result_reg            <= 32'b0;
        end
        else begin
            case (state)

                // --------------------------------------------------
                // S_IDLE: accept a new request.
                // For multiply: pre-extend operands to 64 bits and
                // register them — this is the pipeline stage that
                // breaks the timing-critical start→multiply path.
                // For divide: latch absolute-value operands and flags.
                // --------------------------------------------------
                S_IDLE: begin
                    if (start && is_mul_op) begin
                        // Sign- or zero-extend operands based on op type.
                        // MULHU  : both zero-extended (treated as positive by $signed)
                        // MULHSU : a sign-extended, b zero-extended
                        // MUL/MULH: both sign-extended
                        if (is_mulhu) begin
                            mul_a_reg <= {32'b0, operand_a};
                            mul_b_reg <= {32'b0, operand_b};
                        end else if (is_mulhsu) begin
                            mul_a_reg <= {{32{operand_a[31]}}, operand_a};
                            mul_b_reg <= {32'b0, operand_b};
                        end else begin
                            mul_a_reg <= {{32{operand_a[31]}}, operand_a};
                            mul_b_reg <= {{32{operand_b[31]}}, operand_b};
                        end
                        latched_mulh <= !is_mul;
                        state        <= S_MUL_LOAD;
                    end
                    else if (start && is_div_op) begin
                        latched_rem   <= is_rem || is_remu;
                        latched_neg_q <= is_signed_div && (sign_a ^ sign_b) && (operand_b != 32'b0);
                        latched_neg_r <= is_signed_div && sign_a;

                        if (operand_b == 32'b0) begin
                            latched_special       <= 1'b1;
                            latched_special_value <= (is_rem || is_remu) ? operand_a : 32'hFFFF_FFFF;
                        end
                        else if (is_signed_div &&
                                 operand_a == 32'h8000_0000 &&
                                 operand_b == 32'hFFFF_FFFF) begin
                            latched_special       <= 1'b1;
                            latched_special_value <= is_rem ? 32'b0 : 32'h8000_0000;
                        end
                        else begin
                            latched_special       <= 1'b0;
                            latched_special_value <= 32'b0;
                        end

                        div_acc     <= {32'b0, abs_a};
                        div_divisor <= abs_b;
                        iter        <= 6'd32;
                        state       <= S_DIV;
                    end
                end

                // --------------------------------------------------
                // S_MUL_LOAD: compute 64-bit product from registered
                // operands.  The path is now reg→DSP→reg — Vivado
                // can properly pipeline DSP48E1 blocks for the target clock.
                // --------------------------------------------------
                S_MUL_LOAD: begin
                    mul_full <= $signed(mul_a_reg) * $signed(mul_b_reg);
                    state    <= S_MUL;
                end

                // --------------------------------------------------
                // S_MUL: select and register the requested half.
                // --------------------------------------------------
                S_MUL: begin
                    result_reg <= latched_mulh ? mul_full[63:32] : mul_full[31:0];
                    state      <= S_DONE;
                end

                // --------------------------------------------------
                // S_DIV: restoring division (32 iterations + finalize).
                // --------------------------------------------------
                S_DIV: begin
                    if (latched_special) begin
                        result_reg <= latched_special_value;
                        state      <= S_DONE;
                    end
                    else if (iter == 6'd0) begin
                        if (latched_rem)
                            result_reg <= latched_neg_r ? (~div_acc[63:32] + 32'b1)
                                                        :   div_acc[63:32];
                        else
                            result_reg <= latched_neg_q ? (~div_acc[31:0]  + 32'b1)
                                                        :   div_acc[31:0];
                        state <= S_DONE;
                    end
                    else begin
                        div_acc <= div_subtract ? {div_trial, div_shifted[31:1], 1'b1}
                                                : div_shifted;
                        iter    <= iter - 6'b1;
                    end
                end

                // --------------------------------------------------
                // S_DONE: done is asserted combinationally this cycle.
                // --------------------------------------------------
                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    assign result = result_reg;
    assign busy   = (state != S_IDLE);
    assign done   = (state == S_DONE);

endmodule
