// ============================================================
// Module  : tb_cpu_system_legality
// Purpose : Directed architectural checks for illegal SYSTEM and
//           CSR encodings. This test intentionally targets legality,
//           not the currently implemented permissive behavior.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_system_legality;
    logic clk, rst_n;
    logic [31:0] imem_addr, imem_data;
    logic [31:0] dmem_addr, dmem_write_data, dmem_read_data;
    logic [3:0] dmem_byte_enable;
    logic dmem_write_en, dmem_read_en;
    logic [31:0] imem [0:255];
    logic [31:0] dmem [0:255];
    int pass_count, fail_count, case_pass_count, case_fail_count;
    integer i;

    cpu dut (
        .clk(clk), .rst_n(rst_n), .irq_m_timer(1'b0),
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
    function automatic [31:0] enc_csr(input logic [11:0] csr,
        input logic [4:0] rs1_zimm, input logic [2:0] f3, input logic [4:0] rd);
        enc_csr = {csr, rs1_zimm, f3, rd, OP_SYSTEM};
    endfunction
    function automatic [31:0] enc_system0(input logic [11:0] funct12,
        input logic [4:0] rs1, input logic [4:0] rd);
        enc_system0 = {funct12, rs1, 3'b000, rd, OP_SYSTEM};
    endfunction

    task automatic check32(input logic [31:0] actual,
        input logic [31:0] expected, input string label);
        begin
            if (actual === expected) begin
                pass_count++; case_pass_count++;
                $display("  PASS: %s = 0x%08h", label, actual);
            end else begin
                fail_count++; case_fail_count++;
                $display("  FAIL: %s expected 0x%08h got 0x%08h", label, expected, actual);
            end
        end
    endtask

    task automatic run_illegal_case(input string name, input logic [31:0] bad_instr);
        begin
            rst_n = 1'b0;
            imem_data = 32'h0000_0013;
            dmem_read_data = 32'b0;
            for (i = 0; i < 256; i = i + 1) begin
                imem[i] = 32'h0000_0013;
                dmem[i] = 32'b0;
            end

            // Main program; offending instruction is at PC 0x1c.
            imem[0]  = enc_i(96, 5'd0, F3_ADD_SUB, 5'd7, OP_I_ALU);
            imem[1]  = enc_csr(CSR_MTVEC, 5'd7, 3'b001, 5'd0);
            imem[2]  = enc_u(32'h2000_0000, 5'd5, OP_LUI);
            imem[3]  = enc_i(90, 5'd0, F3_ADD_SUB, 5'd1, OP_I_ALU);
            imem[4]  = enc_i(51, 5'd0, F3_ADD_SUB, 5'd2, OP_I_ALU);
            imem[5]  = enc_csr(CSR_MSCRATCH, 5'd2, 3'b001, 5'd0);
            imem[6]  = enc_i(85, 5'd0, F3_ADD_SUB, 5'd10, OP_I_ALU);
            imem[7]  = bad_instr;
            imem[8]  = enc_csr(CSR_MSCRATCH, 5'd0, 3'b010, 5'd12);
            imem[9]  = enc_i(170, 5'd0, F3_ADD_SUB, 5'd11, OP_I_ALU);
            imem[10] = enc_s(0, 5'd11, 5'd5, F3_SW, OP_S);
            imem[11] = 32'h0000_006f;

            // Handler at 0x60: capture metadata, skip illegal instruction,
            // then return to the architectural successor.
            imem[24] = enc_csr(CSR_MEPC, 5'd0, 3'b010, 5'd28);
            imem[25] = enc_i(4, 5'd28, F3_ADD_SUB, 5'd28, OP_I_ALU);
            imem[26] = enc_csr(CSR_MEPC, 5'd28, 3'b001, 5'd0);
            imem[27] = enc_csr(CSR_MCAUSE, 5'd0, 3'b010, 5'd29);
            imem[28] = enc_s(4, 5'd29, 5'd5, F3_SW, OP_S);
            imem[29] = enc_csr(CSR_MTVAL, 5'd0, 3'b010, 5'd30);
            imem[30] = enc_s(8, 5'd30, 5'd5, F3_SW, OP_S);
            imem[31] = 32'h3020_0073;

            repeat (3) @(posedge clk);
            #1 rst_n = 1'b1;
            repeat (180) @(posedge clk);

            case_pass_count = 0;
            case_fail_count = 0;
            $display("--- %s: instruction=0x%08h ---", name, bad_instr);
            check32(dut.u_datapath.u_register_file.registers[5'd10], 32'd85,
                    "destination register unchanged");
            check32(dut.u_datapath.u_register_file.registers[5'd12], 32'd51,
                    "MSCRATCH unchanged");
            check32(dut.u_datapath.u_register_file.registers[5'd11], 32'd170,
                    "post-MRET register marker");
            check32(dmem[0], 32'd170, "post-MRET memory marker");
            check32(dmem[1], 32'd2, "MCAUSE illegal instruction");
            check32(dmem[2], bad_instr, "MTVAL offending instruction");
            if (case_fail_count == 0)
                $display("CASE PASS: %s", name);
            else
                $display("CASE FAIL: %s (%0d failed checks)", name, case_fail_count);
        end
    endtask

    initial begin
        $dumpfile("sim_cpu_system_legality.vcd");
        $dumpvars(0, tb_cpu_system_legality);
        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b0;

        run_illegal_case("reserved CSR funct3=100",
            enc_csr(CSR_MSCRATCH, 5'd1, 3'b100, 5'd10));
        run_illegal_case("unsupported CSR read 0x7c0",
            enc_csr(12'h7c0, 5'd0, 3'b010, 5'd10));
        run_illegal_case("unsupported CSR write 0x7c0",
            enc_csr(12'h7c0, 5'd1, 3'b001, 5'd10));

        run_illegal_case("write read-only CYCLE",
            enc_csr(CSR_CYCLE, 5'd1, 3'b001, 5'd10));
        run_illegal_case("write read-only INSTRET",
            enc_csr(CSR_INSTRET, 5'd1, 3'b001, 5'd10));
        run_illegal_case("write read-only MHARTID",
            enc_csr(CSR_MHARTID, 5'd1, 3'b001, 5'd10));
        run_illegal_case("write read-only MIP",
            enc_csr(CSR_MIP, 5'd1, 3'b001, 5'd10));

        run_illegal_case("malformed ECALL rd!=x0",
            enc_system0(12'h000, 5'd0, 5'd10));
        run_illegal_case("malformed ECALL rs1!=x0",
            enc_system0(12'h000, 5'd1, 5'd0));
        run_illegal_case("unsupported SYSTEM funct12=0x002",
            enc_system0(12'h002, 5'd0, 5'd0));
        run_illegal_case("malformed MRET rs1/rd!=x0",
            enc_system0(12'h302, 5'd1, 5'd10));

        $display("SYSTEM LEGALITY SUMMARY: %0d PASS, %0d FAIL, %0d checks",
                 pass_count, fail_count, pass_count + fail_count);
        if (fail_count != 0)
            $fatal(1, "CPU SYSTEM legality regression exposed illegal-encoding failures");
        $finish;
    end
endmodule
