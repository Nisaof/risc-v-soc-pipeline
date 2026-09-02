// ============================================================
// Module  : tb_cpu_exceptions
// Purpose : CPU integration tests for exception handling:
//           illegal instruction, load-address misaligned, and
//           store-address misaligned.
//
// Each test:
//   1. Sets MTVEC to a handler.
//   2. Executes the faulting instruction.
//   3. The handler reads MCAUSE / MTVAL, advances MEPC+4, MRET.
//   4. Execution continues past the faulting instruction.
//
// Test 1 — Illegal instruction (opcode 0x2B):
//   MCAUSE = 0x00000002,  MTVAL = 0x0000002B (instr word)
//
// Test 2 — Load address misaligned (LW to 0x20000001):
//   MCAUSE = 0x00000004,  MTVAL = 0x20000001 (faulting addr)
//
// Test 3 — Store address misaligned (SW to 0x20000001):
//   MCAUSE = 0x00000006,  MTVAL = 0x20000001 (faulting addr)
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_exceptions;

    logic        clk;
    logic        rst_n;
    logic [31:0] imem_addr;
    logic [31:0] imem_data;
    logic [31:0] dmem_addr;
    logic [31:0] dmem_write_data;
    logic [3:0]  dmem_byte_enable;
    logic        dmem_write_en;
    logic        dmem_read_en;
    logic [31:0] dmem_read_data;

    logic [31:0] imem [0:255];
    logic [31:0] dmem [0:255];

    int error_count;
    logic read_seen;
    logic [31:0] invalid_load_instr;
    logic [31:0] invalid_store_instr;

    cpu dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .irq_m_timer      (1'b0),
        .imem_addr        (imem_addr),
        .imem_data        (imem_data),
        .dmem_addr        (dmem_addr),
        .dmem_write_data  (dmem_write_data),
        .dmem_byte_enable (dmem_byte_enable),
        .dmem_write_en    (dmem_write_en),
        .dmem_read_en     (dmem_read_en),
        .dmem_read_data   (dmem_read_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always_ff @(posedge clk)
        imem_data <= imem[imem_addr[31:2]];

    always_ff @(posedge clk) begin
        dmem_read_data <= dmem[dmem_addr[9:2]];
        if (dmem_read_en)
            read_seen <= 1'b1;
        if (dmem_write_en) begin
            if (dmem_byte_enable[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_write_data[7:0];
            if (dmem_byte_enable[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_write_data[15:8];
            if (dmem_byte_enable[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_write_data[23:16];
            if (dmem_byte_enable[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_write_data[31:24];
        end
    end

    // ----------------------------------------------------------
    // Instruction encoders
    // ----------------------------------------------------------
    function automatic [31:0] encode_i(
        input int           imm,
        input logic [4:0]   rs1,
        input logic [2:0]   funct3,
        input logic [4:0]   rd,
        input logic [6:0]   opcode
    );
        encode_i = {imm[11:0], rs1, funct3, rd, opcode};
    endfunction

    function automatic [31:0] encode_s(
        input int           imm,
        input logic [4:0]   rs2,
        input logic [4:0]   rs1,
        input logic [2:0]   funct3,
        input logic [6:0]   opcode
    );
        encode_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], opcode};
    endfunction

    function automatic [31:0] encode_u(
        input int           imm,
        input logic [4:0]   rd,
        input logic [6:0]   opcode
    );
        encode_u = {imm[31:12], rd, opcode};
    endfunction

    function automatic [31:0] encode_j(
        input int           imm,
        input logic [4:0]   rd,
        input logic [6:0]   opcode
    );
        encode_j = {imm[20], imm[10:1], imm[11], imm[19:12], rd, opcode};
    endfunction

    // csrw csr, rs1  =  csrrw x0, csr, rs1
    function automatic [31:0] encode_csrw(
        input logic [11:0] csr,
        input logic [4:0]  rs1
    );
        encode_csrw = {csr, rs1, 3'b001, 5'b00000, 7'b1110011};
    endfunction

    // csrr rd, csr  =  csrrs rd, csr, x0
    function automatic [31:0] encode_csrr(
        input logic [4:0]  rd,
        input logic [11:0] csr
    );
        encode_csrr = {csr, 5'b00000, 3'b010, rd, 7'b1110011};
    endfunction

    // ----------------------------------------------------------
    // Check helpers
    // ----------------------------------------------------------
    task automatic check_reg(
        input logic [4:0]  reg_idx,
        input logic [31:0] expected,
        input string       name
    );
        logic [31:0] actual;
        begin
            actual = dut.u_datapath.u_register_file.registers[reg_idx];
            if (actual !== expected) begin
                error_count++;
                $display("FAIL: %s  expected 0x%08h  got 0x%08h", name, expected, actual);
            end else
                $display("PASS: %s = 0x%08h", name, actual);
        end
    endtask

    task automatic check_dmem(
        input int          idx,
        input logic [31:0] expected,
        input string       name
    );
        if (dmem[idx] !== expected) begin
            error_count++;
            $display("FAIL: %s  expected 0x%08h  got 0x%08h", name, expected, dmem[idx]);
        end else
            $display("PASS: %s = 0x%08h", name, dmem[idx]);
    endtask

    // ----------------------------------------------------------
    // Single sequential initial block
    // ----------------------------------------------------------
    integer i;
    initial begin
        $dumpfile("sim_cpu_exceptions.vcd");
        $dumpvars(0, tb_cpu_exceptions);

        error_count = 0;

        // ==========================================================
        // TEST 1: Illegal instruction (opcode 0x2B)
        //
        // Program layout:
        //  [0]  0x00  auipc x7, 0
        //  [1]  0x04  addi  x7, x7, 32     x7 = 0x20  (handler)
        //  [2]  0x08  csrw  mtvec, x7
        //  [3]  0x0C  lui   x5, 0x20000    x5 = 0x20000000 (DMEM base)
        //  [4]  0x10  0x0000_002B           ILLEGAL (opcode=0x2B)
        //  [5]  0x14  addi  x10, x0, 170   x10 = 0xAA  (post-trap)
        //  [6]  0x18  sw    x10, 0(x5)     DMEM[0] = 0xAA
        //  [7]  0x1C  jal   x0, 0          spin
        //
        // Handler at [8] = 0x20:
        //  [8]  0x20  csrr  x28, mepc      x28 = 0x10
        //  [9]  0x24  addi  x28, x28, 4   x28 = 0x14
        // [10]  0x28  csrw  mepc, x28
        // [11]  0x2C  csrr  x29, mcause    x29 = 2 (illegal)
        // [12]  0x30  sw    x29, 4(x5)     DMEM[1] = 2
        // [13]  0x34  csrr  x30, mtval     x30 = 0x0000_002B
        // [14]  0x38  sw    x30, 8(x5)     DMEM[2] = 0x2B
        // [15]  0x3C  mret               PC = 0x14
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(32, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = 32'h0000_002B;                                    // illegal opcode
        imem[5]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[7]  = 32'h0000_006F;                                    // jal x0, 0

        imem[8]  = encode_csrr(5'd28, CSR_MEPC);
        imem[9]  = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[10] = encode_csrw(CSR_MEPC, 5'd28);
        imem[11] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[12] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[13] = encode_csrr(5'd30, CSR_MTVAL);
        imem[14] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[15] = 32'h3020_0073;                                    // mret

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (200) @(posedge clk);

        $display("--- Test 1: Illegal instruction ---");
        check_reg(5'd10, 32'd170,       "x10 post-trap");
        check_reg(5'd28, 32'h0000_0014, "x28 MEPC+4");
        check_reg(5'd29, 32'h0000_0002, "x29 MCAUSE illegal");
        check_reg(5'd30, 32'h0000_002B, "x30 MTVAL instr word");
        check_dmem(0,    32'd170,       "DMEM[0] post-trap store");
        check_dmem(1,    32'h0000_0002, "DMEM[1] MCAUSE illegal");
        check_dmem(2,    32'h0000_002B, "DMEM[2] MTVAL instr word");

        // ==========================================================
        // TEST 2: Misaligned word load handled in hardware (no trap)
        //
        // lw x10, 0(x6) where x6 = 0x20000001.
        // DMEM[0]=0xAABBCCDD, DMEM[1]=0x11223344.
        // Bytes 1-4 in little-endian order: CC BB AA 44 → 0x44AABBCC.
        // No trap: execution continues to sw x10,0(x5) → DMEM[0]=0x44AABBCC.
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end
        dmem[0] = 32'hAABBCCDD;
        dmem[1] = 32'h11223344;

        // [0] lui  x5, 0x20000   x5 = 0x20000000
        // [1] addi x6, x5, 1    x6 = 0x20000001
        // [2] lw   x10, 0(x6)   x10 = 0x44AABBCC
        // [3] sw   x10, 0(x5)   DMEM[0] = 0x44AABBCC
        // [4] jal  x0, 0         spin
        imem[0] = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[1] = encode_i(1,   5'd5, F3_ADD_SUB, 5'd6,  OP_I_ALU);
        imem[2] = encode_i(0,   5'd6, F3_LW,      5'd10, OP_I_LOAD);
        imem[3] = encode_s(0,   5'd10, 5'd5, F3_SW, OP_S);
        imem[4] = 32'h0000_006F;

        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        repeat (60) @(posedge clk);

        $display("--- Test 2: Misaligned word load (hardware, no trap) ---");
        check_reg(5'd10, 32'h44AABBCC, "x10 misaligned lw result");
        check_dmem(0,    32'h44AABBCC, "DMEM[0] store-back of loaded value");

        // ==========================================================
        // TEST 3: Misaligned word store handled in hardware (no trap)
        //
        // sw x8, 0(x6) where x6=0x20000001, x8=0x12345678.
        // Byte layout after store (little-endian at addresses 1-4):
        //   DMEM[0]: byte0=0xDD(untouched) byte1=0x78 byte2=0x56 byte3=0x34
        //            → 0x345678DD
        //   DMEM[1]: byte0=0x12            bytes1-3=0x22,0x22,0x11(untouched)
        //            → 0x11222212... wait
        // Initial DMEM[0]=0xAABBCCDD, DMEM[1]=0x11223344.
        // After store: DMEM[0]=0x345678DD, DMEM[1]=0x11223312.
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end
        dmem[0] = 32'hAABBCCDD;
        dmem[1] = 32'h11223344;

        // [0] lui  x5, 0x20000   x5 = 0x20000000
        // [1] addi x6, x5, 1    x6 = 0x20000001
        // [2] lui  x8, 0x12345  x8 = 0x12345000
        // [3] addi x8, x8, 0x678 x8 = 0x12345678
        // [4] sw   x8, 0(x6)    misaligned store
        // [5] jal  x0, 0         spin
        imem[0] = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[1] = encode_i(1,       5'd5, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[2] = encode_u(32'h12345000, 5'd8, OP_LUI);
        imem[3] = encode_i(32'h678, 5'd8, F3_ADD_SUB, 5'd8, OP_I_ALU);
        imem[4] = encode_s(0, 5'd8, 5'd6, F3_SW, OP_S);
        imem[5] = 32'h0000_006F;

        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        repeat (60) @(posedge clk);

        $display("--- Test 3: Misaligned word store (hardware, no trap) ---");
        check_dmem(0, 32'h345678DD, "DMEM[0] after misaligned sw (byte0 preserved)");
        check_dmem(1, 32'h11223312, "DMEM[1] after misaligned sw (byte0 written)");

        // ==========================================================
        // TEST 4: EBREAK (MCAUSE = 3, MTVAL = 0)
        //
        // Program layout (identical structure to Test 1):
        //  [4]  0x10  0x00100073 (EBREAK)
        //  MCAUSE = 0x00000003,  MTVAL = 0x00000000
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(32, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = 32'h0010_0073;                                    // ebreak
        imem[5]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[7]  = 32'h0000_006F;                                    // jal x0, 0

        imem[8]  = encode_csrr(5'd28, CSR_MEPC);
        imem[9]  = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[10] = encode_csrw(CSR_MEPC, 5'd28);
        imem[11] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[12] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[13] = encode_csrr(5'd30, CSR_MTVAL);
        imem[14] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[15] = 32'h3020_0073;                                    // mret

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (200) @(posedge clk);

        $display("--- Test 4: EBREAK ---");
        check_reg(5'd10, 32'd170,       "x10 post-trap");
        check_reg(5'd28, 32'h0000_0014, "x28 MEPC+4");
        check_reg(5'd29, 32'h0000_0003, "x29 MCAUSE ebreak");
        check_reg(5'd30, 32'h0000_0000, "x30 MTVAL ebreak");
        check_dmem(0,    32'd170,       "DMEM[0] post-trap store");
        check_dmem(1,    32'h0000_0003, "DMEM[1] MCAUSE ebreak");
        check_dmem(2,    32'h0000_0000, "DMEM[2] MTVAL ebreak");

        // ==========================================================
        // TEST 5: FENCE is a NOP (not an illegal instruction trap)
        //
        // Program layout:
        //  [0]  0x00  addi  x10, x0, 1    x10 = 1
        //  [1]  0x04  0x0000000F (FENCE)   NOP — PC must advance to 0x08
        //  [2]  0x08  addi  x10, x0, 2    x10 = 2
        //  [3]  0x0C  addi  x11, x0, 42   x11 = 42
        //  [4]  0x10  jal   x0, 0          spin
        //
        // If FENCE trapped, PC would jump to MTVEC=0 and loop before
        // reaching [2], so x10 would remain 1.
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_i(1,  5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU); // addi x10, x0, 1
        imem[1]  = 32'h0000_000F;                                      // fence
        imem[2]  = encode_i(2,  5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU); // addi x10, x0, 2
        imem[3]  = encode_i(42, 5'd0, F3_ADD_SUB, 5'd11, OP_I_ALU); // addi x11, x0, 42
        imem[4]  = 32'h0000_006F;                                      // jal x0, 0

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (100) @(posedge clk);

        $display("--- Test 5: FENCE NOP ---");
        check_reg(5'd10, 32'd2,  "x10 after FENCE (2 = execution continued)");
        check_reg(5'd11, 32'd42, "x11 after FENCE");

        // ==========================================================
        // TEST 6: JALR to misaligned address (MCAUSE = 0, MTVAL = misaligned target)
        //
        // Program layout:
        //  [0]  0x00  auipc x7, 0
        //  [1]  0x04  addi  x7, x7, 48    x7 = 0x30 (handler)
        //  [2]  0x08  csrw  mtvec, x7
        //  [3]  0x0C  lui   x5, 0x20000   x5 = 0x20000000
        //  [4]  0x10  addi  x1, x0, 2     x1 = 2 (misaligned target — bit[1]=1)
        //  [5]  0x14  jalr  x0, x1, 0    TRAP: fetch misaligned (target=0x02)
        //  [6]  0x18  addi  x10, x0, 170  x10 = 0xAA (post-trap)
        //  [7]  0x1C  sw    x10, 0(x5)    DMEM[0] = 0xAA
        //  [8]  0x20  jal   x0, 0          spin
        //
        // Handler at [12] = 0x30:
        //  MCAUSE = 0x00000000,  MTVAL = 0x00000002 (jalr target addr)
        //  MEPC   = 0x00000014   (jalr instruction PC)
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(48, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = encode_i(2, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);   // addi x1, x0, 2
        imem[5]  = encode_i(0, 5'd1, 3'b000, 5'd0, OP_JALR);         // jalr x0, x1, 0
        imem[6]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[7]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[8]  = 32'h0000_006F;                                      // jal x0, 0

        imem[12] = encode_csrr(5'd28, CSR_MEPC);
        imem[13] = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[14] = encode_csrw(CSR_MEPC, 5'd28);
        imem[15] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[16] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[17] = encode_csrr(5'd30, CSR_MTVAL);
        imem[18] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[19] = 32'h3020_0073;                                      // mret

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (200) @(posedge clk);

        $display("--- Test 6: JALR to misaligned address ---");
        check_reg(5'd10, 32'd170,       "x10 post-trap");
        check_reg(5'd28, 32'h0000_0018, "x28 MEPC+4");
        check_reg(5'd29, 32'h0000_0000, "x29 MCAUSE fetch-misalign");
        check_reg(5'd30, 32'h0000_0002, "x30 MTVAL jalr target");
        check_dmem(0,    32'd170,       "DMEM[0] post-trap store");
        check_dmem(1,    32'h0000_0000, "DMEM[1] MCAUSE");
        check_dmem(2,    32'h0000_0002, "DMEM[2] MTVAL");

        // ==========================================================
        // TEST 7: Taken branch to misaligned address (MCAUSE = 0)
        //
        // Program layout:
        //  [0]  0x00  auipc x7, 0
        //  [1]  0x04  addi  x7, x7, 48    x7 = 0x30 (handler)
        //  [2]  0x08  csrw  mtvec, x7
        //  [3]  0x0C  lui   x5, 0x20000   x5 = 0x20000000
        //  [4]  0x10  0x00000163 (beq x0, x0, +2)  TRAP: target=0x12 (bit[1]=1)
        //  [5]  0x14  addi  x10, x0, 170  x10 = 0xAA (post-trap)
        //  [6]  0x18  sw    x10, 0(x5)    DMEM[0] = 0xAA
        //  [7]  0x1C  jal   x0, 0          spin
        //
        // Handler at [12] = 0x30:
        //  MCAUSE = 0x00000000,  MTVAL = 0x00000012 (branch target)
        //  MEPC   = 0x00000010   (branch instruction PC)
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(48, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = 32'h0000_0163;                                      // beq x0, x0, +2 → target 0x12
        imem[5]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[7]  = 32'h0000_006F;                                      // jal x0, 0

        imem[12] = encode_csrr(5'd28, CSR_MEPC);
        imem[13] = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[14] = encode_csrw(CSR_MEPC, 5'd28);
        imem[15] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[16] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[17] = encode_csrr(5'd30, CSR_MTVAL);
        imem[18] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[19] = 32'h3020_0073;                                      // mret

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (200) @(posedge clk);

        $display("--- Test 7: Taken branch to misaligned address ---");
        check_reg(5'd10, 32'd170,       "x10 post-trap");
        check_reg(5'd28, 32'h0000_0014, "x28 MEPC+4");
        check_reg(5'd29, 32'h0000_0000, "x29 MCAUSE fetch-misalign");
        check_reg(5'd30, 32'h0000_0012, "x30 MTVAL branch target");
        check_dmem(0,    32'd170,       "DMEM[0] post-trap store");
        check_dmem(1,    32'h0000_0000, "DMEM[1] MCAUSE");
        check_dmem(2,    32'h0000_0012, "DMEM[2] MTVAL");

        // ==========================================================
        // TEST 8: Invalid LOAD funct3 (011) is an illegal instruction.
        // The destination register and memory interface must be untouched,
        // then execution must resume at the following instruction.
        // ==========================================================

        rst_n = 1'b0;
        read_seen = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end
        dmem[3] = 32'hA5A5_5A5A;
        invalid_load_instr = encode_i(12, 5'd5, 3'b011, 5'd10, OP_I_LOAD);

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(48, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = encode_i(85, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[5]  = invalid_load_instr;
        imem[6]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd11, OP_I_ALU);
        imem[7]  = encode_s(0, 5'd11, 5'd5, F3_SW, OP_S);
        imem[8]  = 32'h0000_006F;

        imem[12] = encode_csrr(5'd28, CSR_MEPC);
        imem[13] = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[14] = encode_csrw(CSR_MEPC, 5'd28);
        imem[15] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[16] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[17] = encode_csrr(5'd30, CSR_MTVAL);
        imem[18] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[19] = 32'h3020_0073;

        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        repeat (200) @(posedge clk);

        $display("--- Test 8: Invalid LOAD funct3 ---");
        check_reg(5'd10, 32'd85, "x10 unchanged by invalid load");
        check_reg(5'd11, 32'd170, "x11 post-MRET execution");
        check_reg(5'd29, EXC_ILLEGAL_INSTR, "x29 MCAUSE invalid load");
        check_reg(5'd30, invalid_load_instr, "x30 MTVAL invalid load word");
        check_dmem(0, 32'd170, "DMEM[0] post-MRET store");
        check_dmem(1, EXC_ILLEGAL_INSTR, "DMEM[1] MCAUSE invalid load");
        check_dmem(2, invalid_load_instr, "DMEM[2] MTVAL invalid load");
        check_dmem(3, 32'hA5A5_5A5A, "DMEM[3] unchanged by invalid load");
        if (read_seen) begin
            error_count++;
            $display("FAIL: invalid load asserted dmem_read_en");
        end else
            $display("PASS: invalid load did not assert dmem_read_en");

        // ==========================================================
        // TEST 9: Invalid STORE funct3 (011) is an illegal instruction.
        // The target word must remain untouched and execution must resume.
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end
        dmem[3] = 32'hA5A5_5A5A;
        invalid_store_instr = encode_s(12, 5'd8, 5'd5, 3'b011, OP_S);

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(48, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = encode_i(90, 5'd0, F3_ADD_SUB, 5'd8, OP_I_ALU);
        imem[5]  = invalid_store_instr;
        imem[6]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd11, OP_I_ALU);
        imem[7]  = encode_s(0, 5'd11, 5'd5, F3_SW, OP_S);
        imem[8]  = 32'h0000_006F;

        imem[12] = encode_csrr(5'd28, CSR_MEPC);
        imem[13] = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[14] = encode_csrw(CSR_MEPC, 5'd28);
        imem[15] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[16] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[17] = encode_csrr(5'd30, CSR_MTVAL);
        imem[18] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[19] = 32'h3020_0073;

        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        repeat (200) @(posedge clk);

        $display("--- Test 9: Invalid STORE funct3 ---");
        check_reg(5'd11, 32'd170, "x11 post-MRET execution");
        check_reg(5'd29, EXC_ILLEGAL_INSTR, "x29 MCAUSE invalid store");
        check_reg(5'd30, invalid_store_instr, "x30 MTVAL invalid store word");
        check_dmem(0, 32'd170, "DMEM[0] post-MRET store");
        check_dmem(1, EXC_ILLEGAL_INSTR, "DMEM[1] MCAUSE invalid store");
        check_dmem(2, invalid_store_instr, "DMEM[2] MTVAL invalid store");
        check_dmem(3, 32'hA5A5_5A5A, "DMEM[3] unchanged by invalid store");

        // ==========================================================
        // TEST 10: JAL to a two-byte-aligned target must trap because
        // this core implements RV32I without the C extension.
        // The faulting JAL is at 0x18 and targets 0x1a.
        // ==========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(48, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = encode_i(85, 5'd0, F3_ADD_SUB, 5'd9, OP_I_ALU);
        imem[5]  = encode_i(0, 5'd0, F3_ADD_SUB, 5'd12, OP_I_ALU);
        imem[6]  = encode_j(2, 5'd9, OP_JAL);                          // 0x18 -> 0x1a
        imem[7]  = encode_i(1, 5'd12, F3_ADD_SUB, 5'd12, OP_I_ALU);  // execute once after MRET
        imem[8]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[9]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[10] = 32'h0000_006F;

        imem[12] = encode_csrr(5'd27, CSR_MEPC);                      // preserve faulting PC
        imem[13] = encode_i(4, 5'd27, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[14] = encode_csrw(CSR_MEPC, 5'd28);
        imem[15] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[16] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[17] = encode_csrr(5'd30, CSR_MTVAL);
        imem[18] = encode_s(8, 5'd30, 5'd5, F3_SW, OP_S);
        imem[19] = 32'h3020_0073;

        @(posedge clk); @(posedge clk);
        rst_n = 1'b1;
        repeat (220) @(posedge clk);

        $display("--- Test 10: JAL to misaligned address ---");
        check_reg(5'd9,  32'd85,        "x9 JAL link register unchanged");
        check_reg(5'd12, 32'd1,         "x12 younger instruction executes exactly once");
        check_reg(5'd27, 32'h0000_0018, "x27 MEPC faulting JAL PC");
        check_reg(5'd29, EXC_FETCH_MISALIGN, "x29 MCAUSE JAL fetch-misalign");
        check_reg(5'd30, 32'h0000_001A, "x30 MTVAL JAL target");
        check_reg(5'd10, 32'd170,       "x10 post-MRET execution");
        check_dmem(0, 32'd170,          "DMEM[0] post-MRET store");
        check_dmem(1, EXC_FETCH_MISALIGN, "DMEM[1] JAL MCAUSE");
        check_dmem(2, 32'h0000_001A,    "DMEM[2] JAL MTVAL");

        if (error_count != 0) begin
            $display("CPU exception test FAILED: %0d error(s).", error_count);
            $fatal(1);
        end

        $display("CPU exception test passed (59 checks).");
        $finish;
    end

endmodule
