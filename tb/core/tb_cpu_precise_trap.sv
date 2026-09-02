// ============================================================
// Module  : tb_cpu_precise_trap
// Purpose : Directed CPU-level checks for precise trap acceptance,
//           EX-stage squash, and trap/MRET interaction with MEM busy.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_precise_trap;

    logic clk, rst_n, irq_m_timer;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_write_data, dmem_read_data;
    logic [3:0]  dmem_byte_enable;
    logic dmem_write_en, dmem_read_en;

    logic [31:0] imem [0:255];
    logic [31:0] dmem [0:255];
    int pass_count, fail_count;
    integer i;

    cpu dut (
        .clk(clk), .rst_n(rst_n), .irq_m_timer(irq_m_timer),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_write_data(dmem_write_data),
        .dmem_byte_enable(dmem_byte_enable), .dmem_write_en(dmem_write_en),
        .dmem_read_en(dmem_read_en), .dmem_read_data(dmem_read_data)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    always_ff @(posedge clk)
        imem_data <= imem[imem_addr[9:2]];

    always_ff @(posedge clk) begin
        if (dmem_read_en)
            dmem_read_data <= dmem[dmem_addr[9:2]];
        if (dmem_write_en) begin
            if (dmem_byte_enable[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_write_data[7:0];
            if (dmem_byte_enable[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_write_data[15:8];
            if (dmem_byte_enable[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_write_data[23:16];
            if (dmem_byte_enable[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_write_data[31:24];
        end
    end

    function automatic [31:0] enc_i(input int imm, input logic [4:0] rs1,
        input logic [2:0] f3, input logic [4:0] rd, input logic [6:0] op);
        enc_i = {imm[11:0], rs1, f3, rd, op};
    endfunction

    function automatic [31:0] enc_s(input int imm, input logic [4:0] rs2,
        input logic [4:0] rs1, input logic [2:0] f3, input logic [6:0] op);
        enc_s = {imm[11:5], rs2, rs1, f3, imm[4:0], op};
    endfunction

    function automatic [31:0] enc_u(input logic [31:0] imm,
        input logic [4:0] rd, input logic [6:0] op);
        enc_u = {imm[31:12], rd, op};
    endfunction

    function automatic [31:0] enc_csrw(input logic [11:0] csr,
        input logic [4:0] rs1);
        enc_csrw = {csr, rs1, 3'b001, 5'd0, OP_SYSTEM};
    endfunction

    function automatic [31:0] enc_csrr(input logic [4:0] rd,
        input logic [11:0] csr);
        enc_csrr = {csr, 5'd0, 3'b010, rd, OP_SYSTEM};
    endfunction

    task automatic reset_test;
        begin
            rst_n = 1'b0;
            irq_m_timer = 1'b0;
            imem_data = 32'h0000_0013;
            dmem_read_data = 32'b0;
            for (i = 0; i < 256; i = i + 1) begin
                imem[i] = 32'h0000_0013;
                dmem[i] = 32'b0;
            end
            repeat (3) @(posedge clk);
            #1 rst_n = 1'b1;
        end
    endtask

    task automatic check_reg(input logic [4:0] idx,
        input logic [31:0] expected, input string name);
        logic [31:0] actual;
        begin
            actual = dut.u_datapath.u_register_file.registers[idx];
            if (actual === expected) begin
                pass_count++;
                $display("PASS: %s = 0x%08h", name, actual);
            end else begin
                fail_count++;
                $display("FAIL: %s expected 0x%08h got 0x%08h", name, expected, actual);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_cpu_precise_trap.vcd");
        $dumpvars(0, tb_cpu_precise_trap);
        pass_count = 0;
        fail_count = 0;

        // TEST 1: A faulting JALR must not write its link register.
        reset_test();
        imem[0]  = enc_i(64, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU); // mtvec=0x40
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_i(85, 5'd0, F3_ADD_SUB, 5'd9, OP_I_ALU); // link sentinel
        imem[3]  = enc_i(2, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[4]  = enc_i(0, 5'd1, 3'b000, 5'd9, OP_JALR);       // target=2
        imem[5]  = enc_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = 32'h0000_006f;
        imem[16] = enc_csrr(5'd28, CSR_MEPC);
        imem[17] = enc_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[18] = enc_csrw(CSR_MEPC, 5'd28);
        imem[19] = enc_csrr(5'd29, CSR_MCAUSE);
        imem[20] = enc_csrr(5'd30, CSR_MTVAL);
        imem[21] = 32'h3020_0073;
        repeat (100) @(posedge clk);
        $display("--- TEST 1: faulting JALR rd squash ---");
        check_reg(5'd9,  32'd85,  "JALR link register unchanged");
        check_reg(5'd29, 32'd0,   "JALR MCAUSE");
        check_reg(5'd30, 32'd2,   "JALR MTVAL");
        check_reg(5'd10, 32'd170, "post-JALR execution");

        // TEST 2: The instruction behind a synchronous trap is skipped by
        // the handler and must never have committed speculatively.
        reset_test();
        imem[0]  = enc_i(64, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_i(17, 5'd0, F3_ADD_SUB, 5'd12, OP_I_ALU);
        imem[3]  = 32'h0000_002b;                                      // illegal
        imem[4]  = enc_i(1, 5'd12, F3_ADD_SUB, 5'd12, OP_I_ALU);       // must squash
        imem[5]  = enc_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = 32'h0000_006f;
        imem[16] = enc_csrr(5'd28, CSR_MEPC);
        imem[17] = enc_i(8, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);       // skip fault + younger
        imem[18] = enc_csrw(CSR_MEPC, 5'd28);
        imem[19] = 32'h3020_0073;
        repeat (100) @(posedge clk);
        $display("--- TEST 2: younger synchronous-trap squash ---");
        check_reg(5'd12, 32'd17,  "younger register write squashed");
        check_reg(5'd10, 32'd170, "post-trap execution");

        // TEST 3: Raise a level timer IRQ while an older synchronous load is
        // busy and the interrupted ADDI is held in EX.
        reset_test();
        dmem[0]  = 32'h1234_5678;
        imem[0]  = enc_i(96, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);         // mtvec=0x60
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_i(128, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[3]  = enc_csrw(CSR_MIE, 5'd6);
        imem[4]  = enc_i(8, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[5]  = enc_csrw(CSR_MSTATUS, 5'd6);
        imem[6]  = enc_u(32'h2000_0000, 5'd5, OP_LUI);
        imem[7]  = enc_i(0, 5'd0, F3_ADD_SUB, 5'd12, OP_I_ALU);        // observed instruction starts at zero
        imem[8]  = enc_i(0, 5'd0, F3_ADD_SUB, 5'd20, OP_I_ALU);        // handler count starts at zero
        imem[9]  = enc_i(51, 5'd0, F3_ADD_SUB, 5'd11, OP_I_ALU);       // older commit
        imem[10] = enc_i(0, 5'd5, F3_LW, 5'd14, OP_I_LOAD);            // busy load
        imem[11] = enc_i(1, 5'd12, F3_ADD_SUB, 5'd12, OP_I_ALU);       // restart PC 0x2c
        imem[12] = enc_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[13] = 32'h0000_006f;
        imem[24] = enc_csrw(CSR_MIE, 5'd0);                            // stop retrigger
        imem[25] = enc_i(1, 5'd20, F3_ADD_SUB, 5'd20, OP_I_ALU);      // handler count
        imem[26] = enc_csrr(5'd28, CSR_MEPC);
        imem[27] = enc_csrr(5'd29, CSR_MCAUSE);
        imem[28] = 32'h3020_0073;
        wait (dut.u_datapath.pipe_mem_busy &&
              dut.u_datapath.ex_mem_mem_read &&
              dut.u_datapath.id_ex_valid &&
              dut.u_datapath.id_ex_pc == 32'h2c);
        @(negedge clk) irq_m_timer = 1'b1;
        // Model the timer's sticky level: keep IRQ asserted until the
        // handler has actually entered the pipeline, not merely until an
        // early/stalled fetch address happens to equal MTVEC.
        wait (dut.u_datapath.id_ex_valid &&
              dut.u_datapath.id_ex_pc == 32'h60);
        @(negedge clk) irq_m_timer = 1'b0;
        repeat (140) @(posedge clk);
        $display("--- TEST 3: mem_busy plus timer interrupt ---");
        check_reg(5'd11, 32'd51,          "older instruction committed");
        check_reg(5'd14, 32'h1234_5678,   "older load completed");
        check_reg(5'd28, 32'h0000_002c,   "interrupt restart MEPC");
        check_reg(5'd29, 32'h8000_0007,   "timer MCAUSE");
        check_reg(5'd20, 32'd1,           "single handler entry");
        check_reg(5'd12, 32'd1,           "interrupted instruction executes once");
        check_reg(5'd10, 32'd170,         "post-interrupt execution");

        // TEST 4: Trap entry starts with MIE=0, hence MPIE=0. A single MRET
        // must leave MIE=0/MPIE=1 (MSTATUS read value 0x1880). Reapplying
        // MRET while the preceding load is busy changes MIE incorrectly.
        reset_test();
        dmem[0]  = 32'hCAFE_BABE;
        imem[0]  = enc_i(80, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);        // mtvec=0x50
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_u(32'h2000_0000, 5'd5, OP_LUI);
        imem[3]  = 32'h0000_0073;                                     // ECALL, MIE=0
        imem[4]  = enc_csrr(5'd16, CSR_MSTATUS);
        imem[5]  = enc_i(170, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
        imem[6]  = 32'h0000_006f;
        imem[20] = enc_csrr(5'd28, CSR_MEPC);
        imem[21] = enc_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[22] = enc_csrw(CSR_MEPC, 5'd28);
        imem[23] = enc_i(0, 5'd5, F3_LW, 5'd15, OP_I_LOAD);
        imem[24] = 32'h3020_0073;                                     // MRET behind load
        repeat (140) @(posedge clk);
        $display("--- TEST 4: mem_busy plus MRET ---");
        check_reg(5'd15, 32'hCAFE_BABE, "handler load completed");
        check_reg(5'd16, 32'h0000_1880, "MSTATUS after one MRET");
        check_reg(5'd10, 32'd170,       "post-MRET execution");

        $display("PRECISE TRAP SUMMARY: %0d PASS, %0d FAIL, %0d checks",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count != 0)
            $fatal(1, "CPU precise-trap regression failed");
        $finish;
    end
endmodule
