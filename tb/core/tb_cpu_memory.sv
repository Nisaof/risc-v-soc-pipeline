// ============================================================
// Module  : tb_cpu_memory
// Purpose : CPU-level architectural regression for RV32 load/store
//           sizes, byte offsets, extension, lane enables, and
//           cross-word accesses.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module tb_cpu_memory;

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

    localparam logic [31:0] DMEM_BASE = 32'h2000_0020;
    localparam int DMEM_WORD = 8;

    int pass_count;
    int fail_count;
    int write_count;
    logic [31:0] seen_addr [0:3];
    logic [31:0] seen_data [0:3];
    logic [3:0]  seen_be   [0:3];

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
        imem_data <= imem[imem_addr[9:2]];

    // Synchronous little-endian memory model. For example,
    // dmem[word] = 32'h81FE7F80 represents bytes 80 7F FE 81
    // at increasing byte addresses.
    always_ff @(posedge clk) begin
        if (dmem_read_en)
            dmem_read_data <= dmem[dmem_addr[9:2]];

        if (dmem_write_en) begin
            if (write_count < 4) begin
                seen_addr[write_count] <= dmem_addr;
                seen_data[write_count] <= dmem_write_data;
                seen_be[write_count]   <= dmem_byte_enable;
            end
            write_count <= write_count + 1;

            if (dmem_byte_enable[0]) dmem[dmem_addr[9:2]][7:0]   <= dmem_write_data[7:0];
            if (dmem_byte_enable[1]) dmem[dmem_addr[9:2]][15:8]  <= dmem_write_data[15:8];
            if (dmem_byte_enable[2]) dmem[dmem_addr[9:2]][23:16] <= dmem_write_data[23:16];
            if (dmem_byte_enable[3]) dmem[dmem_addr[9:2]][31:24] <= dmem_write_data[31:24];
        end
    end

    function automatic [31:0] encode_i(
        input integer imm,
        input logic [4:0] rs1,
        input logic [2:0] funct3_i,
        input logic [4:0] rd,
        input logic [6:0] opcode
    );
        encode_i = {imm[11:0], rs1, funct3_i, rd, opcode};
    endfunction

    function automatic [31:0] encode_s(
        input integer imm,
        input logic [4:0] rs2,
        input logic [4:0] rs1,
        input logic [2:0] funct3_i,
        input logic [6:0] opcode
    );
        encode_s = {imm[11:5], rs2, rs1, funct3_i, imm[4:0], opcode};
    endfunction

    function automatic [31:0] encode_u(
        input logic [31:0] imm,
        input logic [4:0] rd,
        input logic [6:0] opcode
    );
        encode_u = {imm[31:12], rd, opcode};
    endfunction

    task automatic clear_imem;
        integer i;
        begin
            for (i = 0; i < 256; i = i + 1)
                imem[i] = 32'h0000_0013;
        end
    endtask

    task automatic apply_reset;
        begin
            rst_n = 1'b0;
            write_count = 0;
            repeat (3) @(posedge clk);
            #1;
            rst_n = 1'b1;
        end
    endtask

    task automatic run_load(
        input string name,
        input logic [2:0] load_funct3,
        input integer offset,
        input logic [31:0] expected
    );
        logic [31:0] actual;
        begin
            clear_imem();
            // Increasing bytes from DMEM_BASE:
            //   80 7F FE 81 | F4 12 F0 7E
            dmem[DMEM_WORD]     = 32'h81FE_7F80;
            dmem[DMEM_WORD + 1] = 32'h7EF0_12F4;
            dmem_read_data      = 32'h81FE_7F80;

            imem[0] = encode_u(32'h2000_0000, 5'd5, OP_LUI);
            imem[1] = encode_i(32, 5'd5, F3_ADD_SUB, 5'd5, OP_I_ALU);
            imem[2] = encode_i(offset, 5'd5, load_funct3, 5'd10, OP_I_LOAD);
            imem[3] = 32'h0000_006f;

            apply_reset();
            repeat (45) @(posedge clk);
            #1;
            actual = dut.u_datapath.u_register_file.registers[10];

            if (actual === expected) begin
                pass_count++;
                $display("PASS: %s offset %0d = 0x%08h", name, offset, actual);
            end else begin
                fail_count++;
                $display("FAIL: %s offset %0d expected 0x%08h, got 0x%08h",
                         name, offset, expected, actual);
            end
        end
    endtask

    task automatic run_store(
        input string name,
        input logic [2:0] store_funct3,
        input integer offset,
        input logic [31:0] expected_word0,
        input logic [31:0] expected_word1,
        input integer expected_writes,
        input logic [3:0] expected_be0,
        input logic [31:0] expected_data0,
        input logic [3:0] expected_be1,
        input logic [31:0] expected_data1
    );
        logic transaction_ok;
        begin
            clear_imem();
            // Increasing bytes from DMEM_BASE before the store:
            //   DD CC BB AA | 44 33 22 11
            dmem[DMEM_WORD]     = 32'hAABB_CCDD;
            dmem[DMEM_WORD + 1] = 32'h1122_3344;

            imem[0] = encode_u(32'h2000_0000, 5'd5, OP_LUI);
            imem[1] = encode_i(32, 5'd5, F3_ADD_SUB, 5'd5, OP_I_ALU);
            // x8 = 0x89ABCDEF
            imem[2] = encode_u(32'h89AB_D000, 5'd8, OP_LUI);
            imem[3] = encode_i(-529, 5'd8, F3_ADD_SUB, 5'd8, OP_I_ALU);
            imem[4] = encode_s(offset, 5'd8, 5'd5, store_funct3, OP_S);
            imem[5] = 32'h0000_006f;

            apply_reset();
            repeat (45) @(posedge clk);
            #1;

            transaction_ok =
                (write_count == expected_writes) &&
                (seen_addr[0] === DMEM_BASE) &&
                (seen_be[0] === expected_be0) &&
                (seen_data[0] === expected_data0);

            if (expected_writes == 2) begin
                transaction_ok = transaction_ok &&
                    (seen_addr[1] === (DMEM_BASE + 32'd4)) &&
                    (seen_be[1] === expected_be1) &&
                    (seen_data[1] === expected_data1);
            end

            if ((dmem[DMEM_WORD] === expected_word0) &&
                (dmem[DMEM_WORD + 1] === expected_word1) &&
                transaction_ok) begin
                pass_count++;
                $display("PASS: %s offset %0d words=%08h/%08h writes=%0d",
                         name, offset, dmem[DMEM_WORD], dmem[DMEM_WORD + 1], write_count);
            end else begin
                fail_count++;
                $display("FAIL: %s offset %0d expected words=%08h/%08h, got=%08h/%08h",
                         name, offset, expected_word0, expected_word1,
                         dmem[DMEM_WORD], dmem[DMEM_WORD + 1]);
                $display("      writes expected=%0d got=%0d; first addr/be/data=%08h/%b/%08h",
                         expected_writes, write_count, seen_addr[0], seen_be[0], seen_data[0]);
                if (expected_writes == 2)
                    $display("      second addr/be/data=%08h/%b/%08h",
                             seen_addr[1], seen_be[1], seen_data[1]);
            end
        end
    endtask

    task automatic run_immediate_store_load;
        logic [31:0] actual;
        begin
            clear_imem();
            dmem[DMEM_WORD]     = 32'hAABB_CCDD;
            dmem[DMEM_WORD + 1] = 32'h1122_3344;
            // Deliberately stale registered read value. The LB must wait for
            // the synchronous response containing the preceding SB update.
            dmem_read_data = 32'hAABB_CCDD;

            imem[0] = encode_u(32'h2000_0000, 5'd5, OP_LUI);
            imem[1] = encode_i(32, 5'd5, F3_ADD_SUB, 5'd5, OP_I_ALU);
            imem[2] = encode_i(-86, 5'd0, F3_ADD_SUB, 5'd8, OP_I_ALU);
            imem[3] = encode_s(0, 5'd8, 5'd5, F3_SB, OP_S);
            imem[4] = encode_i(0, 5'd5, F3_LB, 5'd10, OP_I_LOAD);
            imem[5] = 32'h0000_006f;

            apply_reset();
            repeat (45) @(posedge clk);
            #1;
            actual = dut.u_datapath.u_register_file.registers[10];

            if ((actual === 32'hFFFF_FFAA) &&
                (dmem[DMEM_WORD] === 32'hAABB_CCAA) &&
                (write_count == 1)) begin
                pass_count++;
                $display("PASS: immediate SB->LB ordering result=%08h word=%08h",
                         actual, dmem[DMEM_WORD]);
            end else begin
                fail_count++;
                $display("FAIL: immediate SB->LB ordering expected result=ffffffaa word=aabbccaa writes=1");
                $display("      got result=%08h word=%08h writes=%0d",
                         actual, dmem[DMEM_WORD], write_count);
            end
        end
    endtask

    initial begin
        $dumpfile("sim_cpu_memory.vcd");
        $dumpvars(0, tb_cpu_memory);
        pass_count = 0;
        fail_count = 0;
        rst_n = 1'b0;
        imem_data = 32'h0000_0013;
        dmem_read_data = 32'b0;
        #1;

        // Prime the synchronous instruction-memory interface before the
        // first measured case. Every measured case still starts with reset.
        clear_imem();
        apply_reset();
        repeat (5) @(posedge clk);

        // LOAD: architectural result after lane selection and extension.
        run_load("LB",  F3_LB,  0, 32'hFFFF_FF80);
        run_load("LB",  F3_LB,  1, 32'h0000_007F);
        run_load("LB",  F3_LB,  2, 32'hFFFF_FFFE);
        run_load("LB",  F3_LB,  3, 32'hFFFF_FF81);
        run_load("LBU", F3_LBU, 0, 32'h0000_0080);
        run_load("LBU", F3_LBU, 1, 32'h0000_007F);
        run_load("LBU", F3_LBU, 2, 32'h0000_00FE);
        run_load("LBU", F3_LBU, 3, 32'h0000_0081);
        run_load("LH",  F3_LH,  0, 32'h0000_7F80);
        run_load("LH",  F3_LH,  1, 32'hFFFF_FE7F);
        run_load("LH",  F3_LH,  2, 32'hFFFF_81FE);
        run_load("LH",  F3_LH,  3, 32'hFFFF_F481);
        run_load("LHU", F3_LHU, 0, 32'h0000_7F80);
        run_load("LHU", F3_LHU, 1, 32'h0000_FE7F);
        run_load("LHU", F3_LHU, 2, 32'h0000_81FE);
        run_load("LHU", F3_LHU, 3, 32'h0000_F481);
        run_load("LW",  F3_LW,  0, 32'h81FE_7F80);
        run_load("LW",  F3_LW,  1, 32'hF481_FE7F);
        run_load("LW",  F3_LW,  2, 32'h12F4_81FE);
        run_load("LW",  F3_LW,  3, 32'hF012_F481);

        // STORE: final neighboring words plus exact bus address/data/BE.
        run_store("SB", F3_SB, 0, 32'hAABB_CCEF, 32'h1122_3344, 1, 4'b0001, 32'hEFEF_EFEF, 4'b0, 32'b0);
        run_store("SB", F3_SB, 1, 32'hAABB_EFDD, 32'h1122_3344, 1, 4'b0010, 32'hEFEF_EFEF, 4'b0, 32'b0);
        run_store("SB", F3_SB, 2, 32'hAAEF_CCDD, 32'h1122_3344, 1, 4'b0100, 32'hEFEF_EFEF, 4'b0, 32'b0);
        run_store("SB", F3_SB, 3, 32'hEFBB_CCDD, 32'h1122_3344, 1, 4'b1000, 32'hEFEF_EFEF, 4'b0, 32'b0);

        run_store("SH", F3_SH, 0, 32'hAABB_CDEF, 32'h1122_3344, 1, 4'b0011, 32'hCDEF_CDEF, 4'b0, 32'b0);
        run_store("SH", F3_SH, 1, 32'hAACD_EFDD, 32'h1122_3344, 1, 4'b0110, 32'h00CD_EF00, 4'b0, 32'b0);
        run_store("SH", F3_SH, 2, 32'hCDEF_CCDD, 32'h1122_3344, 1, 4'b1100, 32'hCDEF_0000, 4'b0, 32'b0);
        run_store("SH", F3_SH, 3, 32'hEFBB_CCDD, 32'h1122_33CD, 2, 4'b1000, 32'hEF00_0000, 4'b0001, 32'h0000_00CD);

        run_store("SW", F3_SW, 0, 32'h89AB_CDEF, 32'h1122_3344, 1, 4'b1111, 32'h89AB_CDEF, 4'b0, 32'b0);
        run_store("SW", F3_SW, 1, 32'hABCD_EFDD, 32'h1122_3389, 2, 4'b1110, 32'hABCD_EF00, 4'b0001, 32'h0000_0089);
        run_store("SW", F3_SW, 2, 32'hCDEF_CCDD, 32'h1122_89AB, 2, 4'b1100, 32'hCDEF_0000, 4'b0011, 32'h0000_89AB);
        run_store("SW", F3_SW, 3, 32'hEFBB_CCDD, 32'h1189_ABCD, 2, 4'b1000, 32'hEF00_0000, 4'b0111, 32'h0089_ABCD);

        // Store followed immediately by a synchronous load and redirect.
        run_immediate_store_load();

        $display("============================================================");
        $display("CPU memory regression: TOTAL=%0d PASS=%0d FAIL=%0d",
                 pass_count + fail_count, pass_count, fail_count);
        $display("============================================================");

        if (fail_count != 0)
            $fatal(1, "CPU memory regression failed");
        $finish;
    end

endmodule
