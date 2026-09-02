// ============================================================
// Module  : tb_cpu_csr
// Purpose : CPU integration test for CSR instructions,
//           ECALL/MRET trap path, and timer IRQ delivery.
//
// Test 1: ECALL / MRET
//   Sets MTVEC, executes ECALL.  Handler reads MCAUSE, stores it
//   to DMEM, advances MEPC+4, and MRET.  Execution continues.
//
// Test 2: Timer interrupt
//   Enables MTIE + MIE, spins on a NOP.  Testbench asserts
//   irq_m_timer.  Handler stores MCAUSE, clears MTIE, sets
//   original MEPC, and MRET.  The interrupted instruction resumes.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_csr;

    logic        clk;
    logic        rst_n;
    logic        irq_m_timer;
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

    cpu dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .irq_m_timer      (irq_m_timer),
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

    // Synchronous memory models matching real BRAM latency.
    always_ff @(posedge clk)
        imem_data <= imem[imem_addr[31:2]];

    always_ff @(posedge clk) begin
        dmem_read_data <= dmem[dmem_addr[9:2]];
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
    // Single sequential initial block — avoids multi-driver races
    // ----------------------------------------------------------
    integer i;
    initial begin
        $dumpfile("sim_cpu_csr.vcd");
        $dumpvars(0, tb_cpu_csr);

        error_count  = 0;
        irq_m_timer  = 1'b0;

        // ===========================================================
        // TEST 1: ECALL / MRET
        //
        // Program layout (index → PC):
        //  [0]  0x00  auipc x7, 0          x7 = 0x00 (PC)
        //  [1]  0x04  addi  x7, x7, 40     x7 = 0x28 (handler)
        //  [2]  0x08  csrw  mtvec, x7       MTVEC = 0x28
        //  [3]  0x0C  lui   x5, 0x20000    x5 = 0x20000000
        //  [4]  0x10  ecall                trap → handler at 0x28
        //  [5]  0x14  addi  x10, x0, 170  x10 = 0xAA  (post-MRET)
        //  [6]  0x18  sw    x10, 0(x5)    DMEM[0] = 0xAA
        //  [7]  0x1C  jal   x0, 0         spin
        //  [8-9]      nop padding
        //
        // Handler at [10] = 0x28:
        // [10]  0x28  csrr  x28, mepc      x28 = 0x10 (ECALL PC)
        // [11]  0x2C  addi  x28, x28, 4   x28 = 0x14
        // [12]  0x30  csrw  mepc, x28      MEPC = 0x14
        // [13]  0x34  csrr  x29, mcause   x29 = 0xB
        // [14]  0x38  sw    x29, 4(x5)    DMEM[1] = 0xB
        // [15]  0x3C  mret               PC = MEPC = 0x14
        // ===========================================================

        rst_n = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(40, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = 32'h0000_0073;                                    // ecall
        imem[5]  = encode_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = encode_s(0, 5'd10, 5'd5, F3_SW, OP_S);
        imem[7]  = 32'h0000_006F;                                    // jal x0,0

        imem[10] = encode_csrr(5'd28, CSR_MEPC);
        imem[11] = encode_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[12] = encode_csrw(CSR_MEPC, 5'd28);
        imem[13] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[14] = encode_s(4, 5'd29, 5'd5, F3_SW, OP_S);
        imem[15] = 32'h3020_0073;                                    // mret

        // Hold reset for 2 posedges so FSM initialises to STATE_FETCH
        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        repeat (200) @(posedge clk);

        $display("--- Test 1: ECALL/MRET ---");
        check_reg(5'd10, 32'd170,       "x10 post-MRET");
        check_reg(5'd28, 32'h0000_0014, "x28 MEPC+4");
        check_reg(5'd29, 32'h0000_000B, "x29 MCAUSE ECALL");
        check_dmem(0,    32'd170,       "DMEM[0] post-MRET store");
        check_dmem(1,    32'h0000_000B, "DMEM[1] MCAUSE ECALL");

        // ===========================================================
        // TEST 2: Timer interrupt
        //
        // Program layout:
        //  [0]  0x00  auipc x7, 0          x7 = 0
        //  [1]  0x04  addi  x7, x7, 80     x7 = 0x50  (handler)
        //  [2]  0x08  csrw  mtvec, x7       MTVEC = 0x50
        //  [3]  0x0C  lui   x5, 0x20000    x5 = 0x20000000
        //  [4]  0x10  addi  x6, x0, 128    x6 = 0x80  (MTIE bit)
        //  [5]  0x14  csrw  mie, x6         MIE.MTIE = 1
        //  [6]  0x18  addi  x6, x0, 8      x6 = 0x8  (global MIE)
        //  [7]  0x1C  csrw  mstatus, x6    MSTATUS.MIE = 1
        //  [8]  0x20  addi  x10, x0, 203  x10 = 0xCB (older instruction)
        //  [9]  0x24  addi  x10, x10, 1   x10 = 0xCC exactly once after MRET
        // [10]  0x28  sw    x10, 4(x5)    DMEM[1] = 0xCC
        // [11]  0x2C  jal   x0, 0         spin
        // [12-19]     nop padding to 0x50
        //
        // Handler at [20] = 0x50:
        // [20]  0x50  csrr  x29, mcause   x29 = 0x80000007
        // [21]  0x54  sw    x29, 0(x5)    DMEM[0] = 0x80000007
        // [22]  0x58  csrw  mie, x0        clear MTIE
        // [23]  0x5C  csrr  x28, mepc      x28 = 0x24  (interrupted ADDI)
        // [24]  0x60  nop                  preserve MEPC
        // [25]  0x64  nop                  preserve MEPC
        // [26]  0x68  mret               PC = 0x24
        // ===========================================================

        // Reset everything for test 2
        rst_n       = 1'b0;
        irq_m_timer = 1'b0;
        for (i = 0; i < 256; i++) begin imem[i] = 32'h0000_0013; dmem[i] = 0; end

        imem[0]  = encode_u(0, 5'd7, OP_AUIPC);
        imem[1]  = encode_i(80, 5'd7, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[2]  = encode_csrw(CSR_MTVEC, 5'd7);
        imem[3]  = encode_u(32'h20000000, 5'd5, OP_LUI);
        imem[4]  = encode_i(128, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[5]  = encode_csrw(CSR_MIE, 5'd6);
        imem[6]  = encode_i(8, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[7]  = encode_csrw(CSR_MSTATUS, 5'd6);
        imem[8]  = encode_i(203, 5'd0,  F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[9]  = encode_i(1,   5'd10, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[10] = encode_s(4, 5'd10, 5'd5, F3_SW, OP_S);
        imem[11] = 32'h0000_006F;                                    // jal x0,0
        // [12-19] remain NOPs

        imem[20] = encode_csrr(5'd29, CSR_MCAUSE);
        imem[21] = encode_s(0, 5'd29, 5'd5, F3_SW, OP_S);
        imem[22] = encode_csrw(CSR_MIE, 5'd0);
        imem[23] = encode_csrr(5'd28, CSR_MEPC);
        // [24-25] remain NOPs so MRET uses the original interrupted MEPC.
        imem[26] = 32'h3020_0073;                                    // mret

        @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;

        // Pipeline version:
        // Assert the timer IRQ while the older setup ADDI at PC=0x20 is
        // in ID/EX. Interrupt enable becomes effective one cycle later,
        // when the interrupted increment at PC=0x24 is in ID/EX.
        wait (
            dut.u_datapath.id_ex_valid &&
            dut.u_datapath.id_ex_pc == 32'h0000_0020
        );

        @(negedge clk);
        irq_m_timer = 1'b1;

        repeat (250) @(posedge clk);

        $display("--- Test 2: Timer interrupt ---");
        check_reg(5'd10, 32'd204,        "x10 interrupted increment executed exactly once");
        check_reg(5'd28, 32'h0000_0024,  "x28 interrupted MEPC = 0x24");
        check_reg(5'd29, 32'h8000_0007,  "x29 MCAUSE timer IRQ");
        check_dmem(0,    32'h8000_0007,  "DMEM[0] MCAUSE timer IRQ");
        check_dmem(1,    32'd204,        "DMEM[1] post-interrupt store");

        if (error_count != 0) begin
            $display("CPU CSR test FAILED: %0d error(s).", error_count);
            $fatal(1);
        end

        $display("CPU CSR test passed (10 checks).");
        $finish;
    end

endmodule
