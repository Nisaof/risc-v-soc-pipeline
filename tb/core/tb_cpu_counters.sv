// ============================================================
// Module  : tb_cpu_counters
// Purpose : Directed CPU-level INSTRET retirement checks for the
//           active 5-stage pipeline.
//
// A second CSR read observes the counter before that read itself retires.
// Therefore each expected delta includes the first CSR read plus all
// architecturally retired instructions between the two reads.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_counters;
    logic clk, rst_n, irq_m_timer;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_write_data, dmem_read_data;
    logic [3:0] dmem_byte_enable;
    logic dmem_write_en, dmem_read_en;
    logic [31:0] imem [0:255];
    logic [31:0] dmem [0:255];
    int pass_count, fail_count;
    int pc0_retire_count;
    int trap_mret_accept_count;
    logic trap_mret_bad_target;
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
    always_ff @(posedge clk) imem_data <= imem[imem_addr[9:2]];
    always_ff @(posedge clk) begin
        if (dmem_read_en) dmem_read_data <= dmem[dmem_addr[9:2]];
        if (dmem_write_en) begin
            if (dmem_byte_enable[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_write_data[7:0];
            if (dmem_byte_enable[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_write_data[15:8];
            if (dmem_byte_enable[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_write_data[23:16];
            if (dmem_byte_enable[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_write_data[31:24];
        end
    end

    always_ff @(posedge clk) begin
        if (rst_n && dut.u_datapath.pipe_instret_en &&
            dut.u_datapath.mem_wb_pc_plus4 == 32'd4)
            pc0_retire_count <= pc0_retire_count + 1;

        if (rst_n && dut.u_datapath.pipe_mret_accept &&
            dut.u_datapath.id_ex_pc == 32'h0000_004c) begin
            trap_mret_accept_count <= trap_mret_accept_count + 1;
            if (dut.u_datapath.pipe_redirect_target != 32'h0000_0010)
                trap_mret_bad_target <= 1'b1;
        end

    end

    function automatic [31:0] enc_i(input int imm, input logic [4:0] rs1,
        input logic [2:0] f3, input logic [4:0] rd, input logic [6:0] op);
        enc_i = {imm[11:0], rs1, f3, rd, op};
    endfunction
    function automatic [31:0] enc_r(input logic [6:0] f7,
        input logic [4:0] rs2, input logic [4:0] rs1,
        input logic [2:0] f3, input logic [4:0] rd);
        enc_r = {f7, rs2, rs1, f3, rd, OP_R};
    endfunction
    function automatic [31:0] enc_b(input int imm, input logic [4:0] rs2,
        input logic [4:0] rs1, input logic [2:0] f3);
        enc_b = {imm[12], imm[10:5], rs2, rs1, f3, imm[4:1], imm[11], OP_B};
    endfunction
    function automatic [31:0] enc_u(input logic [31:0] imm,
        input logic [4:0] rd, input logic [6:0] op);
        enc_u = {imm[31:12], rd, op};
    endfunction
    function automatic [31:0] enc_csrr(input logic [4:0] rd,
        input logic [11:0] csr);
        enc_csrr = {csr, 5'd0, 3'b010, rd, OP_SYSTEM};
    endfunction
    function automatic [31:0] enc_csrw(input logic [11:0] csr,
        input logic [4:0] rs1);
        enc_csrw = {csr, rs1, 3'b001, 5'd0, OP_SYSTEM};
    endfunction

    task automatic prepare_test;
        begin
            rst_n = 1'b0;
            irq_m_timer = 1'b0;
            imem_data = 32'h0000_0013;
            dmem_read_data = 32'b0;
            for (i = 0; i < 256; i = i + 1) begin
                imem[i] = 32'h0000_0013;
                dmem[i] = 32'b0;
            end
        end
    endtask

    task automatic start_and_check(input string name,
        input logic [31:0] expected_delta, input int cycles);
        logic [31:0] actual;
        begin
            repeat (3) @(posedge clk);
            #1 rst_n = 1'b1;
            repeat (cycles) @(posedge clk);
            actual = dut.u_datapath.u_register_file.registers[5'd22];
            if (actual === expected_delta) begin
                pass_count++;
                $display("PASS: %s INSTRET delta=%0d", name, actual);
            end else begin
                fail_count++;
                $display("FAIL: %s INSTRET delta expected=%0d got=%0d (0x%08h)",
                         name, expected_delta, actual, actual);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_cpu_counters.vcd");
        $dumpvars(0, tb_cpu_counters);
        pass_count = 0;
        fail_count = 0;
        pc0_retire_count = 0;
        trap_mret_accept_count = 0;
        trap_mret_bad_target = 1'b0;

        // Startup duplicate check. Prime x1 to a known value, reset the CPU
        // without clearing the register file, then make the first instruction
        // a non-idempotent increment. It and its retirement must occur once.
        prepare_test();
        imem[0] = enc_i(0, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[1] = 32'h0000_006f;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (30) @(posedge clk);

        prepare_test();
        imem[0] = enc_i(1, 5'd1, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[1] = 32'h0000_006f;
        pc0_retire_count = 0;
        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        repeat (30) @(posedge clk);
        if (dut.u_datapath.u_register_file.registers[5'd1] === 32'd1 &&
            pc0_retire_count == 1) begin
            pass_count++;
            $display("PASS: startup PC=0 executes/retires exactly once");
        end else begin
            fail_count++;
            $display("FAIL: startup PC=0 expected x1=1/retirements=1 got x1=%0d/retirements=%0d",
                dut.u_datapath.u_register_file.registers[5'd1], pc0_retire_count);
        end

        // 1. First CSRR + three ordinary instructions = 4 retirements.
        prepare_test();
        imem[0] = enc_csrr(5'd20, CSR_INSTRET);
        imem[1] = enc_i(1, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[2] = enc_i(2, 5'd0, F3_ADD_SUB, 5'd2, OP_I_ALU);
        imem[3] = enc_r(F7_NORMAL, 5'd2, 5'd1, F3_ADD_SUB, 5'd3);
        imem[4] = enc_csrr(5'd21, CSR_INSTRET);
        imem[5] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[6] = 32'h0000_006f;
        start_and_check("straight-line", 32'd4, 100);

        // 2. A synchronous load stall adds cycles, but the load retires once.
        prepare_test();
        dmem[0] = 32'h1234_5678;
        imem[0] = enc_u(32'h2000_0000, 5'd5, OP_LUI);
        imem[1] = enc_csrr(5'd20, CSR_INSTRET);
        imem[2] = enc_i(0, 5'd5, F3_LW, 5'd6, OP_I_LOAD);
        imem[3] = enc_csrr(5'd21, CSR_INSTRET);
        imem[4] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[5] = 32'h0000_006f;
        start_and_check("synchronous load stall", 32'd2, 110);

        // 3. First CSRR + taken branch = 2. The younger ADDI is flushed.
        prepare_test();
        imem[0] = enc_i(0, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[1] = enc_csrr(5'd20, CSR_INSTRET);
        imem[2] = enc_b(8, 5'd0, 5'd0, F3_BEQ);
        imem[3] = enc_i(1, 5'd1, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[4] = enc_csrr(5'd21, CSR_INSTRET);
        imem[5] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[6] = 32'h0000_006f;
        start_and_check("taken-branch flush", 32'd2, 110);

        // 4. Policy: the illegal instruction does not retire. The first
        // CSRR plus handler CSRR/ADDI/CSRW/MRET do retire: delta = 5.
        prepare_test();
        imem[0]  = enc_i(64, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_csrr(5'd20, CSR_INSTRET);
        imem[3]  = 32'h0000_002b;
        imem[4]  = enc_csrr(5'd21, CSR_INSTRET);
        imem[5]  = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[6]  = 32'h0000_006f;
        imem[16] = enc_csrr(5'd28, CSR_MEPC);
        imem[17] = enc_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
        imem[18] = enc_csrw(CSR_MEPC, 5'd28);
        imem[19] = 32'h3020_0073;
        trap_mret_accept_count = 0;
        trap_mret_bad_target = 1'b0;
        start_and_check("synchronous trap plus MRET", 32'd5, 150);
        if (trap_mret_accept_count == 1 && !trap_mret_bad_target) begin
            pass_count++;
            $display("PASS: adjacent CSRW MEPC -> MRET redirects once to 0x10");
        end else begin
            fail_count++;
            $display("FAIL: adjacent CSRW MEPC -> MRET accepts=%0d bad_target=%0b",
                trap_mret_accept_count, trap_mret_bad_target);
        end

        // 5. Cross-boundary LW consumes multiple MEM cycles but retires once.
        prepare_test();
        dmem[0] = 32'h4433_2211;
        dmem[1] = 32'h8877_6655;
        imem[0] = enc_u(32'h2000_0000, 5'd5, OP_LUI);
        imem[1] = enc_csrr(5'd20, CSR_INSTRET);
        imem[2] = enc_i(1, 5'd5, F3_LW, 5'd6, OP_I_LOAD);
        imem[3] = enc_csrr(5'd21, CSR_INSTRET);
        imem[4] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[5] = 32'h0000_006f;
        start_and_check("cross-boundary load", 32'd2, 120);

        // 6. First CSRR + MUL + DIV = 3, independent of MDU latency.
        prepare_test();
        imem[0] = enc_i(20, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
        imem[1] = enc_i(3, 5'd0, F3_ADD_SUB, 5'd2, OP_I_ALU);
        imem[2] = enc_csrr(5'd20, CSR_INSTRET);
        imem[3] = enc_r(F7_MEXT, 5'd2, 5'd1, 3'b000, 5'd3);
        imem[4] = enc_r(F7_MEXT, 5'd2, 5'd1, 3'b100, 5'd4);
        imem[5] = enc_csrr(5'd21, CSR_INSTRET);
        imem[6] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[7] = 32'h0000_006f;
        start_and_check("MUL/DIV busy", 32'd3, 180);

        // 7. First CSRR + handler CSRW + MRET + restarted ADDI = 4.
        // The interrupted ADDI is squashed before the handler, then retires
        // exactly once after MRET.
        prepare_test();
        imem[0]  = enc_i(96, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);
        imem[1]  = enc_csrw(CSR_MTVEC, 5'd7);
        imem[2]  = enc_i(128, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[3]  = enc_csrw(CSR_MIE, 5'd6);
        imem[4]  = enc_i(8, 5'd0, F3_ADD_SUB, 5'd6, OP_I_ALU);
        imem[5]  = enc_csrw(CSR_MSTATUS, 5'd6);
        imem[6]  = enc_i(0, 5'd0, F3_ADD_SUB, 5'd12, OP_I_ALU);
        imem[7]  = 32'h0000_0013;
        imem[8]  = enc_csrr(5'd20, CSR_INSTRET);
        imem[9]  = enc_i(1, 5'd12, F3_ADD_SUB, 5'd12, OP_I_ALU);
        imem[10] = enc_csrr(5'd21, CSR_INSTRET);
        imem[11] = enc_r(F7_ALT, 5'd20, 5'd21, F3_ADD_SUB, 5'd22);
        imem[12] = 32'h0000_006f;
        imem[24] = enc_csrw(CSR_MIE, 5'd0);
        imem[25] = 32'h3020_0073;

        repeat (3) @(posedge clk);
        #1 rst_n = 1'b1;
        wait (dut.u_datapath.id_ex_valid &&
              dut.u_datapath.id_ex_pc == 32'h0000_0024);
        @(negedge clk) irq_m_timer = 1'b1;
        wait (dut.u_datapath.id_ex_valid &&
              dut.u_datapath.id_ex_pc == 32'h0000_0060);
        @(negedge clk) irq_m_timer = 1'b0;
        repeat (160) @(posedge clk);
        if (dut.u_datapath.u_register_file.registers[5'd22] === 32'd4 &&
            dut.u_datapath.u_register_file.registers[5'd12] === 32'd1) begin
            pass_count++;
            $display("PASS: timer flush/restart INSTRET delta=4, instruction executed once");
        end else begin
            fail_count++;
            $display("FAIL: timer flush/restart expected delta=4/x12=1 got delta=%0d/x12=%0d",
                dut.u_datapath.u_register_file.registers[5'd22],
                dut.u_datapath.u_register_file.registers[5'd12]);
        end

        $display("CPU COUNTER SUMMARY: %0d PASS, %0d FAIL, %0d cases",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count != 0)
            $fatal(1, "Pipeline INSTRET regression exposed retirement-counting errors");
        $finish;
    end
endmodule
