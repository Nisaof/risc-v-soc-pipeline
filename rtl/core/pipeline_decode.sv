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

    output logic        csr_en,
    output logic        csr_write,
    output logic [1:0]  csr_op,
    output logic        csr_use_imm,

    output logic        illegal_instruction
);

    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;
    logic [11:0] csr_addr;
    logic        csr_addr_supported;
    logic        csr_addr_read_only;
    logic        csr_funct3_legal;
    logic        csr_write_attempt;

    assign opcode = instruction[6:0];
    assign funct3 = instruction[14:12];
    assign funct7 = instruction[31:25];
    assign csr_addr = instruction[31:20];

    assign csr_addr_supported =
        (csr_addr == CSR_MSTATUS)  ||
        (csr_addr == CSR_MIE)      ||
        (csr_addr == CSR_MTVEC)    ||
        (csr_addr == CSR_MSCRATCH) ||
        (csr_addr == CSR_MEPC)     ||
        (csr_addr == CSR_MCAUSE)   ||
        (csr_addr == CSR_MTVAL)    ||
        (csr_addr == CSR_MIP)      ||
        (csr_addr == CSR_MHARTID)  ||
        (csr_addr == CSR_CYCLE)    ||
        (csr_addr == CSR_INSTRET);

    assign csr_addr_read_only =
        (csr_addr == CSR_MIP)     ||
        (csr_addr == CSR_MHARTID) ||
        (csr_addr == CSR_CYCLE)   ||
        (csr_addr == CSR_INSTRET);

    assign csr_funct3_legal =
        (funct3 == 3'b001) || (funct3 == 3'b010) ||
        (funct3 == 3'b011) || (funct3 == 3'b101) ||
        (funct3 == 3'b110) || (funct3 == 3'b111);

    // CSRRW/CSRRWI always attempt a write. Set/clear variants write
    // only when their rs1/zimm field is non-zero.
    assign csr_write_attempt =
        (funct3 == 3'b001) || (funct3 == 3'b101) ||
        (((funct3 == 3'b010) || (funct3 == 3'b011) ||
          (funct3 == 3'b110) || (funct3 == 3'b111)) &&
         (instruction[19:15] != 5'd0));

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
        csr_en      = 1'b0;
        csr_write   = 1'b0;
        csr_op      = 2'b00;
        csr_use_imm = 1'b0;
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

        case (funct3)
            F3_LB, F3_LH, F3_LW, F3_LBU, F3_LHU: begin
                mem_read   = 1'b1;
                mem_to_reg = 1'b1;
                reg_write  = 1'b1;
            end
            default: illegal_instruction = 1'b1;
        endcase
    end

    // --------------------------------------------------------
    // STORE
    // --------------------------------------------------------
    OP_S: begin
        uses_rs1      = 1'b1;
        uses_rs2      = 1'b1;
        alu_src_b     = 1'b1;
        alu_operation = ALU_ADD;

        case (funct3)
            F3_SB, F3_SH, F3_SW: mem_write = 1'b1;
            default:             illegal_instruction = 1'b1;
        endcase
    end
    // --------------------------------------------------------
    // FENCE
    // Treat base RV32I FENCE as a legal NOP in this core.
    // --------------------------------------------------------
    7'b0001111: begin
        if (funct3 == 3'b000) begin
            // FENCE: no architectural state change.
            // All control outputs remain at their defaults.
        end
        else begin
            illegal_instruction = 1'b1;
        end
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

    // --------------------------------------------------------
    // SYSTEM / CSR
    // --------------------------------------------------------
    OP_SYSTEM: begin
        // funct3 == 000:
        // ECALL / EBREAK / MRET
        // These do not perform a normal CSR rd write here.
        if (funct3 == 3'b000) begin
            if ((instruction != 32'h0000_0073) &&
                (instruction != 32'h0010_0073) &&
                (instruction != 32'h3020_0073)) begin
                illegal_instruction = 1'b1;
            end
        end
        else if (!csr_funct3_legal ||
                 !csr_addr_supported ||
                 (csr_addr_read_only && csr_write_attempt)) begin
            illegal_instruction = 1'b1;
        end
        else begin
            // CSRRW / CSRRS / CSRRC
            // CSRRWI / CSRRSI / CSRRCI
            csr_en    = 1'b1;
            reg_write = 1'b1;

            csr_use_imm = funct3[2];

            case (funct3[1:0])
                2'b01: csr_op = 2'b00; // write
                2'b10: csr_op = 2'b01; // set
                2'b11: csr_op = 2'b10; // clear
                default: csr_op = 2'b00;
            endcase

            // Register CSR variants consume rs1.
            if (!funct3[2])
                uses_rs1 = 1'b1;

            // CSRRS/CSRRC(/I) with rs1/zimm=x0 must not write.
            if (funct3[1] && (instruction[19:15] == 5'd0))
                csr_write = 1'b0;
            else
                csr_write = 1'b1;
        end
    end
    default: begin
        illegal_instruction = 1'b1;
    end

endcase
    end

endmodule
