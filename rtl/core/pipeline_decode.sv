// ============================================================
// Module  : pipeline_decode
// Purpose : Instruction decode for 5-stage RV32IM pipeline
//           Generates control information in the ID stage.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module pipeline_decode (
    input  logic [31:0] instruction,

    output logic [4:0]  alu_operation,
    output logic [1:0]  alu_src_a_sel,
    output logic        alu_src_b,

    output logic        reg_write,
    output logic        mem_read,
    output logic        mem_write,
    output logic        mem_to_reg,
    output logic        jump,

    output logic        uses_rs1,
    output logic        uses_rs2,

    output logic        mdu_en,
    output logic        illegal_instruction
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    assign opcode = instruction[6:0];
    assign funct3 = instruction[14:12];
    assign funct7 = instruction[31:25];

    always @(*) begin
        // Safe defaults
        alu_operation       = ALU_ADD;
        alu_src_a_sel       = 2'b00;
        alu_src_b           = 1'b0;

        reg_write           = 1'b0;
        mem_read            = 1'b0;
        mem_write           = 1'b0;
        mem_to_reg          = 1'b0;
        jump                = 1'b0;

        uses_rs1            = 1'b0;
        uses_rs2            = 1'b0;

        mdu_en              = 1'b0;
        illegal_instruction = 1'b0;

       case (opcode)

    // --------------------------------------------------------
    // R-type ALU / M-extension
    // --------------------------------------------------------
    OP_R: begin
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;
        reg_write = 1'b1;

        if (funct7 == F7_MEXT) begin
            mdu_en = 1'b1;

            case (funct3)
                3'b000: alu_operation = ALU_MUL;
                3'b001: alu_operation = ALU_MULH;
                3'b010: alu_operation = ALU_MULHSU;
                3'b011: alu_operation = ALU_MULHU;
                3'b100: alu_operation = ALU_DIV;
                3'b101: alu_operation = ALU_DIVU;
                3'b110: alu_operation = ALU_REM;
                3'b111: alu_operation = ALU_REMU;
                default: begin
                    alu_operation       = ALU_ADD;
                    illegal_instruction = 1'b1;
                end
            endcase

        end
        else begin
            case (funct3)
                F3_ADD_SUB: begin
                    if (funct7 == F7_ALT)
                        alu_operation = ALU_SUB;
                    else
                        alu_operation = ALU_ADD;
                end

                F3_AND:  alu_operation = ALU_AND;
                F3_OR:   alu_operation = ALU_OR;
                F3_XOR:  alu_operation = ALU_XOR;
                F3_SLL:  alu_operation = ALU_SLL;

                F3_SR: begin
                    if (funct7 == F7_ALT)
                        alu_operation = ALU_SRA;
                    else
                        alu_operation = ALU_SRL;
                end

                F3_SLT:  alu_operation = ALU_SLT;
                F3_SLTU: alu_operation = ALU_SLTU;

                default: begin
                    alu_operation       = ALU_ADD;
                    illegal_instruction = 1'b1;
                end
            endcase
        end
    end

    // --------------------------------------------------------
    // I-type ALU
    // --------------------------------------------------------
    OP_I_ALU: begin
        uses_rs1      = 1'b1;
        reg_write     = 1'b1;
        alu_src_b     = 1'b1;

        case (funct3)
            F3_ADD_SUB: alu_operation = ALU_ADD;
            F3_AND:     alu_operation = ALU_AND;
            F3_OR:      alu_operation = ALU_OR;
            F3_XOR:     alu_operation = ALU_XOR;
            F3_SLL:     alu_operation = ALU_SLL;

            F3_SR: begin
                if (funct7 == F7_ALT)
                    alu_operation = ALU_SRA;
                else
                    alu_operation = ALU_SRL;
            end

            F3_SLT:     alu_operation = ALU_SLT;
            F3_SLTU:    alu_operation = ALU_SLTU;

            default: begin
                alu_operation       = ALU_ADD;
                illegal_instruction = 1'b1;
            end
        endcase
    end

    // --------------------------------------------------------
    // LOAD
    // --------------------------------------------------------
    OP_I_LOAD: begin
        uses_rs1      = 1'b1;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;

        mem_read      = 1'b1;
        mem_to_reg    = 1'b1;
        reg_write     = 1'b1;
    end

    // --------------------------------------------------------
    // STORE
    // --------------------------------------------------------
    OP_S: begin
        uses_rs1      = 1'b1;
        uses_rs2      = 1'b1;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;

        mem_write     = 1'b1;
    end
        // --------------------------------------------------------
    // BRANCH
    // --------------------------------------------------------
    OP_B: begin
        uses_rs1  = 1'b1;
        uses_rs2  = 1'b1;

        // Branch comparison itself will be handled in EX.
        alu_operation = ALU_SUB;
    end

    // --------------------------------------------------------
    // JAL
    // --------------------------------------------------------
    OP_JAL: begin
        reg_write     = 1'b1;
        jump          = 1'b1;

        // PC + immediate target is formed in EX.
        alu_src_a_sel = 2'b01;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;
    end

    // --------------------------------------------------------
    // JALR
    // --------------------------------------------------------
    OP_JALR: begin
        uses_rs1      = 1'b1;
        reg_write     = 1'b1;
        jump          = 1'b1;

        alu_src_a_sel = 2'b00;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;
    end

    // --------------------------------------------------------
    // LUI
    // --------------------------------------------------------
    OP_LUI: begin
        reg_write     = 1'b1;

        alu_src_a_sel = 2'b10;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;
    end

    // --------------------------------------------------------
    // AUIPC
    // --------------------------------------------------------
    OP_AUIPC: begin
        reg_write     = 1'b1;

        alu_src_a_sel = 2'b01;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;
    end

    default: begin
        illegal_instruction = 1'b1;
    end

endcase
    end

endmodule