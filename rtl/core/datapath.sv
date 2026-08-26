// ============================================================
// Module  : datapath
// Purpose : CPU datapath for RV32IM multi-cycle implementation
//           Connects PC, register file, ALU, immediate generator,
//           MDU, and CSR file.
// ============================================================

import riscv_pkg::*;
import alu_ops::*;

module datapath #(
    parameter logic [31:0] PC_RESET = 32'h0000_0000
) (
    input  logic        clk,
    input  logic        rst_n,

    // Control signals from control unit
    input  logic [1:0]  alu_src_a_sel,
    input  logic [4:0]  alu_operation,
    input  logic        alu_src_b,
    input  logic        reg_write,
    input  logic        mem_read,
    input  logic        mem_write,
    input  logic        mem_to_reg,
    input  logic        jump,
    input  logic [1:0]  pc_src,
    input  logic        instr_latch_en,
    input  logic        pc_write_en,
    input  logic        alu_reg_en,
    input  logic        mdu_start,
    output logic        mdu_done,

    // CSR / trap control signals
    input  logic        trap_en,
    input  logic        mret_en,
    input  logic        csr_reg_en,
    input  logic        csr_write_en,
    input  logic [31:0] trap_cause,       // MCAUSE value to pass to csr_file

    // Alignment fault detection (to control_unit, combinational)
    output logic        mem_addr_misaligned,   // HIGH when load/store crosses a word boundary
    output logic        fetch_addr_misaligned, // branch/JAL/JALR target not 4-byte aligned

    // Second-pass flag from control_unit (HIGH in STATE_MEMORY2)
    input  logic        in_second_pass,

    // Instruction retirement pulse (HIGH in the cycle an instruction retires)
    input  logic        instret_en,

    // External interrupt request
    input  logic        irq_m_timer,
    output logic        irq_pending,

    // Instruction memory interface
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_data,

    // Data memory interface
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_write_data,
    output logic [3:0]  dmem_byte_enable,
    output logic        dmem_write_en,
    output logic        dmem_read_en,
    input  logic [31:0] dmem_read_data,

    // Status signals to control unit
    output logic [31:0] instruction,
    output logic        branch_eq,
    output logic        branch_lt,
    output logic        branch_ltu
);

    // --------------------------------------------------------
    // Internal signals
    // --------------------------------------------------------
    logic [31:0] pc;
    logic [31:0] pc_next;
    logic [31:0] pc_plus4;
    logic [31:0] pc_branch;
    logic [31:0] imm;
    logic [31:0] rs1_data;
    logic [31:0] rs2_data;
    logic [31:0] alu_operand_a;
    logic [31:0] alu_operand_b;
    logic [31:0] alu_result;
    logic        alu_zero;
    logic [31:0] alu_result_reg;
    logic [31:0] write_back_data;
    logic [4:0]  rs1;
    logic [4:0]  rs2;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [7:0]  load_byte;
    logic [15:0] load_half_assembled;
    logic [31:0] load_word_assembled;
    logic [31:0] load_data_formatted;
    logic [31:0] dmem_data_buf;// buffers first word for cross-boundary loads

    // CSR interface signals
    logic [31:0] csr_rdata;
    logic [31:0] mtvec_out;
    logic [31:0] mepc_out;
    logic [31:0] csr_wdata;
    logic [1:0]  csr_op;
    logic [31:0] trap_val;
    logic pipe_if_id_en;

    logic pipe_id_ex_en;
    logic pipe_ex_mem_en;
    logic pipe_mem_wb_en;
    logic hold_pc;
    logic hold_if_id;
    logic bubble_id_ex;
    logic flush_if_id;
    logic flush_id_ex;
    logic [1:0] forward_a;
    logic [1:0] forward_b;

    logic [31:0] forwarded_rs1_data;
    logic [31:0] forwarded_rs2_data;
    logic [31:0] mem_wb_forward_data;

    logic [31:0] pipe_alu_operand_a;
    logic [31:0] pipe_alu_operand_b;

    logic [31:0] pipe_alu_result;
    logic        pipe_alu_zero;

    logic [31:0] fetch_pc_q;
    logic [31:0] fetch_pc_plus4_q;
    logic fetch_discard_q;
    logic        fetch_hold_valid;
    logic [31:0] fetch_hold_pc;
    logic [31:0] fetch_hold_pc_plus4;
    logic [31:0] fetch_hold_instruction;

    localparam logic PIPELINE_ACTIVE = 1'b1;
    logic        pipe_branch_taken;
    logic        pipe_redirect_valid;
    logic [31:0] pipe_redirect_target;

    logic        rf_write_enable;
    logic [4:0]  rf_write_addr;
    logic [31:0] rf_write_data;

    logic [31:0] mem_stage_addr;
    logic [31:0] mem_stage_store_data;
    logic [2:0]  mem_stage_funct3;
    logic        mem_stage_read;
    logic        mem_stage_write;
    logic mem_load_wait;
    logic pipe_mem_busy;
    logic        pipe_mdu_start;
    logic        pipe_mdu_busy;
    logic        pipe_mdu_done;
    logic [31:0] pipe_mdu_result;

    logic        pipe_mdu_stall;
    logic [31:0] pipe_ex_result;

    logic [31:0] id_rs1_data;
    logic [31:0] id_rs2_data;

    

    // --------------------------------------------------------
    // Fetch request PC tracking
    // IMEM is synchronous, so imem_data belongs to the address
    // presented during the previous cycle.
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
    if (!rst_n) begin
        fetch_pc_q               <= PC_RESET;
        fetch_pc_plus4_q         <= PC_RESET + 32'd4;

        fetch_hold_valid         <= 1'b0;
        fetch_hold_pc            <= 32'b0;
        fetch_hold_pc_plus4      <= 32'b0;
        fetch_hold_instruction   <= 32'b0;
        fetch_discard_q          <= 1'b0;
    end

    else begin
        fetch_pc_q       <= pc;
        fetch_pc_plus4_q <= pc_plus4;

        // Redirect sonrası bir sonraki senkron IMEM cevabını at
        if (pipe_redirect_valid)
            fetch_discard_q <= 1'b1;
        else if (fetch_discard_q && pipe_if_id_en && !hold_if_id)
            fetch_discard_q <= 1'b0;

        // A synchronous IMEM response may arrive while IF/ID is
        // stalled. Preserve that response instead of losing it.
        if (flush_if_id) begin
            fetch_hold_valid <= 1'b0;
        end
        else if (hold_if_id && !fetch_hold_valid) begin
            fetch_hold_valid       <= 1'b1;
            fetch_hold_pc          <= fetch_pc_q;
            fetch_hold_pc_plus4    <= fetch_pc_plus4_q;
            fetch_hold_instruction <= imem_data;
        end
        else if (!hold_if_id && pipe_if_id_en && fetch_hold_valid) begin
            fetch_hold_valid <= 1'b0;
        end
    end
end
    // --------------------------------------------------------
    // IF/ID pipeline register
    // --------------------------------------------------------
    logic        if_id_valid;
    logic [31:0] if_id_pc;
    logic [31:0] if_id_pc_plus4;
    logic [31:0] if_id_instruction;


   always_ff @(posedge clk) begin
    if (!rst_n) begin
        if_id_valid       <= 1'b0;
        if_id_pc          <= 32'b0;
        if_id_pc_plus4    <= 32'b0;
        if_id_instruction <= 32'b0;
    end

    else if (PIPELINE_ACTIVE) begin
        if (flush_if_id) begin
            if_id_valid       <= 1'b0;
            if_id_pc          <= 32'b0;
            if_id_pc_plus4    <= 32'b0;
            if_id_instruction <= 32'b0;
        end

        else if (pipe_if_id_en && !hold_if_id) begin
            if (fetch_discard_q) begin
                if_id_valid       <= 1'b0;
                if_id_pc          <= 32'b0;
                if_id_pc_plus4    <= 32'b0;
                if_id_instruction <= 32'b0;
            end
            else if (fetch_hold_valid) begin
                if_id_valid       <= 1'b1;
                if_id_pc          <= fetch_hold_pc;
                if_id_pc_plus4    <= fetch_hold_pc_plus4;
                if_id_instruction <= fetch_hold_instruction;
            end
            else begin
                if_id_valid       <= 1'b1;
                if_id_pc          <= fetch_pc_q;
                if_id_pc_plus4    <= fetch_pc_plus4_q;
                if_id_instruction <= imem_data;
            end
        end
    end

    // Original multi-cycle compatibility path
    else if (instr_latch_en) begin
        if_id_valid       <= 1'b1;
        if_id_pc          <= fetch_pc_q;
        if_id_pc_plus4    <= fetch_pc_plus4_q;
        if_id_instruction <= imem_data;
    end
end

    // --------------------------------------------------------
    // ID/EX pipeline register
    // --------------------------------------------------------
    logic        id_ex_valid;
    logic [31:0] id_ex_instruction;
    logic [31:0] id_ex_pc;
    logic [31:0] id_ex_pc_plus4;
    logic [31:0] id_ex_rs1_data;
    logic [31:0] id_ex_rs2_data;
    logic [31:0] id_ex_imm;
    logic [4:0]  id_ex_rs1;
    logic [4:0]  id_ex_rs2;
    logic [4:0]  id_ex_rd;
    logic [2:0]  id_ex_funct3;
    logic [4:0] id_ex_alu_operation;
    logic [1:0] id_ex_alu_src_a_sel;
    logic       id_ex_alu_src_b;
    logic       id_ex_reg_write;
    logic       id_ex_mem_read;
    logic       id_ex_mem_write;
    logic       id_ex_mem_to_reg;
    logic       id_ex_jump;
    logic [4:0]  dec_alu_operation;
    logic [1:0]  dec_alu_src_a_sel;
    logic        dec_alu_src_b;
    logic        dec_reg_write;
    logic        dec_mem_read;
    logic        dec_mem_write;
    logic        dec_mem_to_reg;
    logic        dec_jump;
    logic        dec_uses_rs1;
    logic        dec_uses_rs2;
    logic        dec_mdu_en;
    logic        dec_illegal_instruction;
    logic        load_use_hazard;
    logic       id_ex_mdu_en;

    assign load_use_hazard =
    id_ex_valid &&
    id_ex_mem_read &&
    (id_ex_rd != 5'd0) &&
    (
        (dec_uses_rs1 && (id_ex_rd == rs1)) ||
        (dec_uses_rs2 && (id_ex_rd == rs2))
    );
always_ff @(posedge clk) begin
    if (!rst_n) begin
        id_ex_valid         <= 1'b0;
        id_ex_instruction   <= 32'b0;
        id_ex_pc            <= 32'b0;
        id_ex_pc_plus4      <= 32'b0;
        id_ex_rs1_data      <= 32'b0;
        id_ex_rs2_data      <= 32'b0;
        id_ex_imm           <= 32'b0;
        id_ex_rs1           <= 5'b0;
        id_ex_rs2           <= 5'b0;
        id_ex_rd            <= 5'b0;
        id_ex_funct3        <= 3'b0;

        id_ex_alu_operation <= 5'b0;
        id_ex_alu_src_a_sel <= 2'b0;
        id_ex_alu_src_b     <= 1'b0;
        id_ex_reg_write     <= 1'b0;
        id_ex_mem_read      <= 1'b0;
        id_ex_mem_write     <= 1'b0;
        id_ex_mem_to_reg    <= 1'b0;
        id_ex_jump          <= 1'b0;
        id_ex_mdu_en        <= 1'b0;
    end

    else if (PIPELINE_ACTIVE) begin
        // Branch/jump redirect or load-use bubble:
        // invalidate the instruction entering EX.
        if (flush_id_ex || bubble_id_ex) begin
            id_ex_valid         <= 1'b0;
            id_ex_instruction   <= 32'b0;
            id_ex_pc            <= 32'b0;
            id_ex_pc_plus4      <= 32'b0;
            id_ex_rs1_data      <= 32'b0;
            id_ex_rs2_data      <= 32'b0;
            id_ex_imm           <= 32'b0;
            id_ex_rs1           <= 5'b0;
            id_ex_rs2           <= 5'b0;
            id_ex_rd            <= 5'b0;
            id_ex_funct3        <= 3'b0;
            id_ex_mdu_en        <= 1'b0;

            id_ex_alu_operation <= 5'b0;
            id_ex_alu_src_a_sel <= 2'b0;
            id_ex_alu_src_b     <= 1'b0;
            id_ex_reg_write     <= 1'b0;
            id_ex_mem_read      <= 1'b0;
            id_ex_mem_write     <= 1'b0;
            id_ex_mem_to_reg    <= 1'b0;
            id_ex_jump          <= 1'b0;
        end

        else if (pipe_id_ex_en) begin
            id_ex_valid         <= if_id_valid;
            id_ex_instruction   <= if_id_instruction;
            id_ex_pc            <= if_id_pc;
            id_ex_pc_plus4      <= if_id_pc_plus4;
            id_ex_rs1_data <= id_rs1_data;
            id_ex_rs2_data <= id_rs2_data;
            id_ex_imm           <= imm;
            id_ex_rs1           <= rs1;
            id_ex_rs2           <= rs2;
            id_ex_rd            <= rd;
            id_ex_funct3        <= funct3;

            id_ex_alu_operation <= dec_alu_operation;
            id_ex_alu_src_a_sel <= dec_alu_src_a_sel;
            id_ex_alu_src_b     <= dec_alu_src_b;
            id_ex_reg_write     <= dec_reg_write;
            id_ex_mem_read      <= dec_mem_read;
            id_ex_mem_write     <= dec_mem_write;
            id_ex_mem_to_reg    <= dec_mem_to_reg;
            id_ex_jump          <= dec_jump;
            id_ex_mdu_en        <= dec_mdu_en;
        end
    end

    // Existing multi-cycle compatibility path
    else if (instr_latch_en) begin
        id_ex_valid         <= if_id_valid;
        id_ex_instruction   <= if_id_instruction;
        id_ex_pc            <= if_id_pc;
        id_ex_pc_plus4      <= if_id_pc_plus4;
        id_ex_rs1_data <= id_rs1_data;
        id_ex_rs2_data <= id_rs2_data;
        id_ex_imm           <= imm;
        id_ex_rs1           <= rs1;
        id_ex_rs2           <= rs2;
        id_ex_rd            <= rd;
        id_ex_funct3        <= funct3;

        id_ex_alu_operation <= dec_alu_operation;
        id_ex_alu_src_a_sel <= dec_alu_src_a_sel;
        id_ex_alu_src_b     <= dec_alu_src_b;
        id_ex_reg_write     <= dec_reg_write;
        id_ex_mem_read      <= dec_mem_read;
        id_ex_mem_write     <= dec_mem_write;
        id_ex_mem_to_reg    <= dec_mem_to_reg;
        id_ex_jump          <= dec_jump;
        id_ex_mdu_en        <= dec_mdu_en;
    end
end

    // --------------------------------------------------------
    // EX/MEM pipeline register
    // --------------------------------------------------------
    logic        ex_mem_valid;
    logic [31:0] ex_mem_instruction;
    logic [31:0] ex_mem_pc_plus4;
    logic [31:0] ex_mem_alu_result;
    logic [31:0] ex_mem_rs2_data;
    logic [4:0]  ex_mem_rd;
    logic [2:0]  ex_mem_funct3;

    logic        ex_mem_reg_write;
    logic        ex_mem_mem_read;
    logic        ex_mem_mem_write;
    logic        ex_mem_mem_to_reg;
    logic        ex_mem_jump;



    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ex_mem_valid       <= 1'b0;
            ex_mem_instruction <= 32'b0;
            ex_mem_pc_plus4    <= 32'b0;
            ex_mem_alu_result  <= 32'b0;
            ex_mem_rs2_data    <= 32'b0;
            ex_mem_rd          <= 5'b0;
            ex_mem_funct3      <= 3'b0;

            ex_mem_reg_write   <= 1'b0;
            ex_mem_mem_read    <= 1'b0;
            ex_mem_mem_write   <= 1'b0;
            ex_mem_mem_to_reg  <= 1'b0;
            ex_mem_jump        <= 1'b0;
        end
        else if (PIPELINE_ACTIVE) begin
    if (pipe_ex_mem_en) begin
        ex_mem_valid       <= id_ex_valid;
        ex_mem_instruction <= id_ex_instruction;
        ex_mem_pc_plus4    <= id_ex_pc_plus4;
        ex_mem_alu_result <= pipe_ex_result;
        ex_mem_rs2_data    <= forwarded_rs2_data;
        ex_mem_rd          <= id_ex_rd;
        ex_mem_funct3      <= id_ex_funct3;

        ex_mem_reg_write   <= id_ex_reg_write;
        ex_mem_mem_read    <= id_ex_mem_read;
        ex_mem_mem_write   <= id_ex_mem_write;
        ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
        ex_mem_jump        <= id_ex_jump;
    end
end
    else if (alu_reg_en) begin
        ex_mem_valid       <= id_ex_valid;
        ex_mem_instruction <= id_ex_instruction;
        ex_mem_pc_plus4    <= id_ex_pc_plus4;
        ex_mem_alu_result <= pipe_ex_result;
        ex_mem_rs2_data    <= forwarded_rs2_data;
        ex_mem_rd          <= id_ex_rd;
        ex_mem_funct3      <= id_ex_funct3;

        ex_mem_reg_write   <= id_ex_reg_write;
        ex_mem_mem_read    <= id_ex_mem_read;
        ex_mem_mem_write   <= id_ex_mem_write;
        ex_mem_mem_to_reg  <= id_ex_mem_to_reg;
        ex_mem_jump        <= id_ex_jump;
    end
    end
        // --------------------------------------------------------
        // MEM/WB pipeline register
        // --------------------------------------------------------
        logic        mem_wb_valid;
        logic [31:0] mem_wb_instruction;
        logic [31:0] mem_wb_pc_plus4;
        logic [31:0] mem_wb_alu_result;
        logic [31:0] mem_wb_mem_data;
        logic [4:0]  mem_wb_rd;
        logic [2:0]  mem_wb_funct3;

        logic        mem_wb_reg_write;
        logic        mem_wb_mem_to_reg;
        logic        mem_wb_jump;

        assign instruction = if_id_instruction;
        always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_wb_valid       <= 1'b0;
            mem_wb_instruction <= 32'b0;
            mem_wb_pc_plus4    <= 32'b0;
            mem_wb_alu_result  <= 32'b0;
            mem_wb_mem_data    <= 32'b0;
            mem_wb_rd          <= 5'b0;
            mem_wb_funct3      <= 3'b0;

            mem_wb_reg_write   <= 1'b0;
            mem_wb_mem_to_reg  <= 1'b0;
            mem_wb_jump        <= 1'b0;
        end
        else if (PIPELINE_ACTIVE) begin
        if (pipe_mem_wb_en) begin
            mem_wb_valid       <= ex_mem_valid;
            mem_wb_instruction <= ex_mem_instruction;
            mem_wb_pc_plus4    <= ex_mem_pc_plus4;
            mem_wb_alu_result  <= ex_mem_alu_result;
            mem_wb_mem_data    <= dmem_read_data;
            mem_wb_rd          <= ex_mem_rd;
            mem_wb_funct3      <= ex_mem_funct3;

            mem_wb_reg_write   <= ex_mem_reg_write;
            mem_wb_mem_to_reg  <= ex_mem_mem_to_reg;
            mem_wb_jump        <= ex_mem_jump;
        end
    end
        else begin
            // Compatibility path while the original multi-cycle
            // control unit still owns architectural state updates.
            mem_wb_valid       <= ex_mem_valid;
            mem_wb_instruction <= ex_mem_instruction;
            mem_wb_pc_plus4    <= ex_mem_pc_plus4;
            mem_wb_alu_result  <= ex_mem_alu_result;
            mem_wb_mem_data    <= dmem_read_data;
            mem_wb_rd          <= ex_mem_rd;
            mem_wb_funct3      <= ex_mem_funct3;

            mem_wb_reg_write   <= ex_mem_reg_write;
            mem_wb_mem_to_reg  <= ex_mem_mem_to_reg;
            mem_wb_jump        <= ex_mem_jump;
        end
    end

    
   
    // --------------------------------------------------------
    // Instruction field extraction
    // --------------------------------------------------------
    assign rs1    = if_id_instruction[19:15];
    assign rs2    = if_id_instruction[24:20];
    assign rd     = if_id_instruction[11:7];
    assign funct3 = if_id_instruction[14:12];

    // --------------------------------------------------------
    // ALU result / MDU result register
    // Also captures old CSR value when csr_reg_en is asserted
    // in STATE_EXECUTE, so the write-back MUX can forward it
    // to rd in STATE_WRITEBACK via the normal alu_result_reg path.
    // --------------------------------------------------------
    logic [31:0] mdu_result;
    logic        mdu_busy_unused;

    always_ff @(posedge clk) begin
        if (!rst_n)
            alu_result_reg <= 32'b0;
        else if (csr_reg_en)
            alu_result_reg <= csr_rdata;
        else if (alu_reg_en)
            alu_result_reg <= alu_result;
        else if (mdu_done)
            alu_result_reg <= mdu_result;
    end

    // --------------------------------------------------------
    // First-word buffer for cross-boundary loads
    // Latches the DMEM output (word N) at the edge leaving STATE_MEMORY2,
    // so WRITEBACK has both word N (here) and word N+1 (dmem_read_data).
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n)
            dmem_data_buf <= 32'b0;
        else if (in_second_pass)
            dmem_data_buf <= dmem_read_data;
    end

    // --------------------------------------------------------
    // Program Counter
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
    if (!rst_n) begin
        pc <= PC_RESET;
    end
    else if (PIPELINE_ACTIVE) begin
        if (pipe_redirect_valid)
            pc <= pipe_redirect_target;
        else if (!hold_pc)
            pc <= pc_plus4;
    end
    else if (pc_write_en) begin
        pc <= pc_next;
    end
end

    assign pc_plus4  = pc + 32'd4;
    assign pc_branch = pc + imm;

    always @(*) begin
        if (trap_en)
            pc_next = mtvec_out;
        else if (mret_en)
            pc_next = mepc_out;
        else begin
            case (pc_src)
                2'b00:   pc_next = pc_plus4;
                2'b01:   pc_next = pc_branch;
                2'b10:   pc_next = (rs1_data + imm) & ~32'b1;
                default: pc_next = pc_branch;
            endcase
        end
    end

    assign imem_addr = pc;

    // --------------------------------------------------------
    // Submodule instantiations
    // --------------------------------------------------------
    pipeline_decode u_pipeline_decode (
    .instruction         (if_id_instruction),

    .alu_operation       (dec_alu_operation),
    .alu_src_a_sel       (dec_alu_src_a_sel),
    .alu_src_b           (dec_alu_src_b),

    .reg_write           (dec_reg_write),
    .mem_read            (dec_mem_read),
    .mem_write           (dec_mem_write),
    .mem_to_reg          (dec_mem_to_reg),
    .jump                (dec_jump),

    .uses_rs1            (dec_uses_rs1),
    .uses_rs2            (dec_uses_rs2),

    .mdu_en               (dec_mdu_en),
    .illegal_instruction (dec_illegal_instruction)
);

    pipeline_control u_pipeline_control (
    .clk             (clk),
    .rst_n           (rst_n),

    .if_id_valid     (if_id_valid),
    .id_ex_valid     (id_ex_valid),
    .ex_mem_valid    (ex_mem_valid),
    .mem_wb_valid    (mem_wb_valid),

    .load_use_hazard (load_use_hazard),

    // Temporary connections.
    // Real MEM/MDU busy and redirect logic will be connected later.
    .mem_busy (pipe_mem_busy),
    .mdu_busy (pipe_mdu_stall),
    .redirect_valid  (pipe_redirect_valid),

    .pipe_if_id_en   (pipe_if_id_en),
    .pipe_id_ex_en   (pipe_id_ex_en),
    .pipe_ex_mem_en  (pipe_ex_mem_en),
    .pipe_mem_wb_en  (pipe_mem_wb_en),

    .hold_pc         (hold_pc),
    .hold_if_id      (hold_if_id),
    .bubble_id_ex    (bubble_id_ex),
    .flush_if_id     (flush_if_id),
    .flush_id_ex     (flush_id_ex)
);
    forwarding_unit u_forwarding_unit (
    .id_ex_rs1        (id_ex_rs1),
    .id_ex_rs2        (id_ex_rs2),

    .ex_mem_valid     (ex_mem_valid),
    .ex_mem_reg_write (ex_mem_reg_write),
    .ex_mem_rd        (ex_mem_rd),

    .mem_wb_valid     (mem_wb_valid),
    .mem_wb_reg_write (mem_wb_reg_write),
    .mem_wb_rd        (mem_wb_rd),

    .forward_a        (forward_a),
    .forward_b        (forward_b)
);

    // --------------------------------------------------------
// Forwarding data selection
// --------------------------------------------------------

// Value produced by the instruction in MEM/WB.
assign mem_wb_forward_data =
    mem_wb_mem_to_reg ? mem_wb_mem_data :
    mem_wb_jump       ? mem_wb_pc_plus4 :
                        mem_wb_alu_result;

always @(*) begin
    case (forward_a)
        2'b10:   forwarded_rs1_data = ex_mem_alu_result;
        2'b01:   forwarded_rs1_data = mem_wb_forward_data;
        default: forwarded_rs1_data = id_ex_rs1_data;
    endcase

    case (forward_b)
        2'b10:   forwarded_rs2_data = ex_mem_alu_result;
        2'b01:   forwarded_rs2_data = mem_wb_forward_data;
        default: forwarded_rs2_data = id_ex_rs2_data;
    endcase
end
    imm_gen u_imm_gen (
    .instruction (if_id_instruction),
    .imm_out     (imm)
);
    // --------------------------------------------------------
    // Register-file write-back selection
    // --------------------------------------------------------
    assign rf_write_enable =
        PIPELINE_ACTIVE ? (mem_wb_valid && mem_wb_reg_write)
                        : reg_write;

    assign rf_write_addr =
        PIPELINE_ACTIVE ? mem_wb_rd
                        : rd;

    assign rf_write_data =
        PIPELINE_ACTIVE ? mem_wb_forward_data
                        : write_back_data;

    register_file u_register_file (
        .clk          (clk),
        .read_addr_1  (rs1),
        .read_data_1  (rs1_data),
        .read_addr_2  (rs2),
        .read_data_2  (rs2_data),
        .write_enable (rf_write_enable),
        .write_addr   (rf_write_addr),
        .write_data   (rf_write_data)
    );

    

    // --------------------------------------------------------
    // WB -> ID bypass
    // Handles register-file write/read occurring in same cycle.
    // --------------------------------------------------------
    always @(*) begin
        id_rs1_data = rs1_data;
        id_rs2_data = rs2_data;

        if (mem_wb_valid && mem_wb_reg_write && (mem_wb_rd != 5'd0)) begin
            if (mem_wb_rd == rs1)
                id_rs1_data = mem_wb_forward_data;

            if (mem_wb_rd == rs2)
                id_rs2_data = mem_wb_forward_data;
        end
    end

    always @(*) begin
    case (alu_src_a_sel)
        2'b01:   alu_operand_a = pc;
        2'b10:   alu_operand_a = 32'b0;
        default: alu_operand_a = rs1_data;
    endcase
end

assign alu_operand_b = alu_src_b ? imm : rs2_data;



    alu u_alu (
        .operation (alu_operation),
        .operand_a (alu_operand_a),
        .operand_b (alu_operand_b),
        .result    (alu_result),
        .zero      (alu_zero)
    );

    mdu u_mdu (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (mdu_start),
        .operation (alu_operation),
        .operand_a (alu_operand_a),
        .operand_b (alu_operand_b),
        .result    (mdu_result),
        .busy      (mdu_busy_unused),
        .done      (mdu_done)
    );

    // CSR write data: rs1_data for register variants (funct3[2]=0),
    // zero-extended zimm for immediate variants (funct3[2]=1).
    assign csr_wdata = funct3[2] ? {27'b0, if_id_instruction[19:15]} : rs1_data;

    // CSR operation encoding from funct3[1:0]:
    //   01 (CSRRW/CSRRWI) → 00 (overwrite)
    //   10 (CSRRS/CSRRSI) → 01 (set bits)
    //   11 (CSRRC/CSRRCI) → 10 (clear bits)
    always @(*) begin
        case (funct3[1:0])
            2'b10:   csr_op = 2'b01;
            2'b11:   csr_op = 2'b10;
            default: csr_op = 2'b00;
        endcase
    end

        // --------------------------------------------------------
    // Pipeline EX operand selection
    // --------------------------------------------------------
    always @(*) begin
        case (id_ex_alu_src_a_sel)
            2'b01:   pipe_alu_operand_a = id_ex_pc;
            2'b10:   pipe_alu_operand_a = 32'b0;
            default: pipe_alu_operand_a = forwarded_rs1_data;
        endcase
    end

    assign pipe_alu_operand_b =
        id_ex_alu_src_b ? id_ex_imm : forwarded_rs2_data;

    // --------------------------------------------------------
    // Pipeline EX ALU
    // --------------------------------------------------------
    alu u_pipe_alu (
        .operation (id_ex_alu_operation),
        .operand_a (pipe_alu_operand_a),
        .operand_b (pipe_alu_operand_b),
        .result    (pipe_alu_result),
        .zero      (pipe_alu_zero)
    );
    // --------------------------------------------------------
// Pipeline MDU
// --------------------------------------------------------
assign pipe_mdu_start =
    id_ex_valid &&
    id_ex_mdu_en &&
    !pipe_mdu_busy &&
    !pipe_mdu_done;

    mdu u_pipe_mdu (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (pipe_mdu_start),
        .operation (id_ex_alu_operation),
        .operand_a (forwarded_rs1_data),
        .operand_b (forwarded_rs2_data),
        .result    (pipe_mdu_result),
        .busy      (pipe_mdu_busy),
        .done      (pipe_mdu_done)
    );

    assign pipe_mdu_stall =
    id_ex_valid &&
    id_ex_mdu_en &&
    !pipe_mdu_done;

    assign pipe_ex_result =
        id_ex_mdu_en ? pipe_mdu_result
                    : pipe_alu_result;


        // --------------------------------------------------------
// Pipeline EX control-flow resolution
// Branches, JAL and JALR are resolved in EX.
// --------------------------------------------------------
always @(*) begin
    pipe_branch_taken   = 1'b0;
    pipe_redirect_valid = 1'b0;
    pipe_redirect_target = 32'b0;

    if (id_ex_valid) begin
        case (id_ex_instruction[6:0])

            OP_B: begin
                case (id_ex_funct3)
                    F3_BEQ:
                        pipe_branch_taken =
                            (forwarded_rs1_data == forwarded_rs2_data);

                    F3_BNE:
                        pipe_branch_taken =
                            (forwarded_rs1_data != forwarded_rs2_data);

                    F3_BLT:
                        pipe_branch_taken =
                            ($signed(forwarded_rs1_data) <
                             $signed(forwarded_rs2_data));

                    F3_BGE:
                        pipe_branch_taken =
                            ($signed(forwarded_rs1_data) >=
                             $signed(forwarded_rs2_data));

                    F3_BLTU:
                        pipe_branch_taken =
                            (forwarded_rs1_data < forwarded_rs2_data);

                    F3_BGEU:
                        pipe_branch_taken =
                            (forwarded_rs1_data >= forwarded_rs2_data);

                    default:
                        pipe_branch_taken = 1'b0;
                endcase

                if (pipe_branch_taken) begin
                    pipe_redirect_valid  = 1'b1;
                    pipe_redirect_target = id_ex_pc + id_ex_imm;
                end
            end

            OP_JAL: begin
                pipe_redirect_valid  = 1'b1;
                pipe_redirect_target = id_ex_pc + id_ex_imm;
            end

            OP_JALR: begin
                pipe_redirect_valid  = 1'b1;
                pipe_redirect_target =
                    (forwarded_rs1_data + id_ex_imm) & ~32'b1;
            end

            default: begin
                pipe_redirect_valid  = 1'b0;
                pipe_redirect_target = 32'b0;
            end
        endcase
    end
end
    // --------------------------------------------------------
    // Cross-word-boundary detection (combinational from ALU result)
    // Asserts when a load/store spans two words and needs STATE_MEMORY2.
    // Within-word misalignment (e.g. lh at offset 1) is handled in-place with no extra cycle.
    // --------------------------------------------------------
    always @(*) begin
        case (funct3)
            F3_LW, F3_SW:          mem_addr_misaligned = |alu_result[1:0];        // any non-word-aligned crosses
            F3_LH, F3_LHU, F3_SH:  mem_addr_misaligned = &alu_result[1:0];        // only offset==3 crosses
            default:                mem_addr_misaligned = 1'b0;                    // byte: never crosses
        endcase
    end

    // --------------------------------------------------------
    // Fetch address misalignment check (JALR, JAL, taken branches)
    // fetch_target is the computed destination address.
    // --------------------------------------------------------
    logic [31:0] fetch_target;

    always @(*) begin
        if (if_id_instruction[6:0] == OP_JALR) begin
            fetch_target          = (rs1_data + imm) & ~32'b1;
            fetch_addr_misaligned = fetch_target[1];
        end else begin                          // OP_B, OP_JAL
            fetch_target          = pc_branch;
            fetch_addr_misaligned = pc_branch[1];
        end
    end

    // --------------------------------------------------------
    // Trap value for MTVAL (combinational)
    // --------------------------------------------------------
    always @(*) begin
        case (trap_cause)
            EXC_FETCH_MISALIGN:              trap_val = fetch_target;    // misaligned jump/branch target
            EXC_LOAD_MISALIGN,
            EXC_STORE_MISALIGN:              trap_val = alu_result_reg;  // faulting effective address
            EXC_ILLEGAL_INSTR:               trap_val = if_id_instruction;       // offending instruction word
            default:                         trap_val = 32'b0;
        endcase
    end

    csr_file u_csr_file (
        .clk              (clk),
        .rst_n            (rst_n),
        .trap_en          (trap_en),
        .mret_en          (mret_en),
        .trap_cause       (trap_cause),
        .trap_val         (trap_val),
        .trap_pc          (pc),
        .irq_m_timer      (irq_m_timer),
        .csr_addr         (if_id_instruction[31:20]),
        .csr_wdata        (csr_wdata),
        .csr_op           (csr_op),
        .csr_write_en     (csr_write_en),
        .instret_en       (instret_en),
        .csr_rdata        (csr_rdata),
        .mtvec_out        (mtvec_out),
        .mepc_out         (mepc_out),
        .irq_pending      (irq_pending)
    );

    // --------------------------------------------------------
    // Load data formatting — supports all aligned and misaligned cases
    // --------------------------------------------------------

    // lb/lbu: single byte at byte offset alu_result_reg[1:0] within the word
    always @(*) begin
        case (alu_result_reg[1:0])
            2'b00:   load_byte = dmem_read_data[7:0];
            2'b01:   load_byte = dmem_read_data[15:8];
            2'b10:   load_byte = dmem_read_data[23:16];
            default: load_byte = dmem_read_data[31:24];
        endcase
    end

    // lh/lhu: 16-bit value from all four byte offsets
    //   off=0: [15:0]  (aligned)
    //   off=1: [23:8]  (within-word misaligned — single read)
    //   off=2: [31:16] (aligned)
    //   off=3: {word_N+1[7:0], word_N[31:24]} (cross-boundary — two reads)
    always @(*) begin
        case (alu_result_reg[1:0])
            2'b00:   load_half_assembled = dmem_read_data[15:0];
            2'b01:   load_half_assembled = dmem_read_data[23:8];
            2'b10:   load_half_assembled = dmem_read_data[31:16];
            default: load_half_assembled = {dmem_read_data[7:0], dmem_data_buf[31:24]};
        endcase
    end

    // lw: 32-bit value; any non-zero offset is cross-boundary and uses dmem_data_buf + dmem_read_data
    always @(*) begin
        case (alu_result_reg[1:0])
            2'b01:   load_word_assembled = {dmem_read_data[7:0],  dmem_data_buf[31:8]};
            2'b10:   load_word_assembled = {dmem_read_data[15:0], dmem_data_buf[31:16]};
            2'b11:   load_word_assembled = {dmem_read_data[23:0], dmem_data_buf[31:24]};
            default: load_word_assembled = dmem_read_data;   // aligned
        endcase
    end

    always @(*) begin
        case (funct3)
            F3_LB:   load_data_formatted = {{24{load_byte[7]}}, load_byte};
            F3_LBU:  load_data_formatted = {24'b0, load_byte};
            F3_LH:   load_data_formatted = {{16{load_half_assembled[15]}}, load_half_assembled};
            F3_LHU:  load_data_formatted = {16'b0, load_half_assembled};
            default: load_data_formatted = load_word_assembled;
        endcase
    end

    assign write_back_data = mem_to_reg ? load_data_formatted
                                        : (jump ? pc_plus4 : alu_result_reg);

    // --------------------------------------------------------
    // Synchronous DMEM load wait tracking
    // --------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mem_load_wait <= 1'b0;
        end
        else if (PIPELINE_ACTIVE) begin
            if (mem_load_wait)
                mem_load_wait <= 1'b0;
            else if (ex_mem_valid && ex_mem_mem_read)
                mem_load_wait <= 1'b1;
        end
        else begin
            mem_load_wait <= 1'b0;
        end
    end

    assign pipe_mem_busy =
        PIPELINE_ACTIVE &&
        ex_mem_valid &&
        ex_mem_mem_read &&
        !mem_load_wait;
    // --------------------------------------------------------
    // MEM-stage source selection
    // --------------------------------------------------------
    assign mem_stage_addr =
        PIPELINE_ACTIVE ? ex_mem_alu_result
                        : alu_result_reg;

    assign mem_stage_store_data =
        PIPELINE_ACTIVE ? ex_mem_rs2_data
                        : rs2_data;

    assign mem_stage_funct3 =
        PIPELINE_ACTIVE ? ex_mem_funct3
                        : funct3;

    assign mem_stage_read =
        PIPELINE_ACTIVE ? (ex_mem_valid && ex_mem_mem_read)
                        : mem_read;

    assign mem_stage_write =
        PIPELINE_ACTIVE ? (ex_mem_valid && ex_mem_mem_write)
                        : mem_write;
    // --------------------------------------------------------
    // Data memory connections — fully misalignment-aware
    //
    // First pass  (in_second_pass=0): access word N = {alu_result_reg[31:2], 2'b00}
    // Second pass (in_second_pass=1): access word N+1 = word_N_addr + 4
    //
    // Byte enables use a barrel-shift pattern:
    //   F3_SB / lb*: 4'b0001 shifted left by off (single byte, never crosses)
    //   F3_SH / lh*: 4'b0011 shifted left by off (first pass), overflowed byte in second pass
    //   F3_SW / lw:  4'b1111 shifted left by off (first pass), remaining bytes in second pass
    //
    // For loads the memory ignores byte_enable and returns the full word;
    // we always set 4'b1111 for loads to avoid confusion.
    // --------------------------------------------------------

    logic [1:0] off;
    assign off = mem_stage_addr[1:0];

    logic [31:0] dmem_word_base;
    assign dmem_word_base = {mem_stage_addr[31:2], 2'b00};

    always @(*) begin
        dmem_addr = in_second_pass ? (dmem_word_base + 32'd4) : dmem_word_base;
    end

    assign dmem_write_en = mem_stage_write;
    assign dmem_read_en  = mem_stage_read;
    assign branch_eq     = (rs1_data == rs2_data);
    assign branch_lt     = ($signed(rs1_data) < $signed(rs2_data));
    assign branch_ltu    = (rs1_data < rs2_data);

    // Store write data — barrel-shifted to the correct byte lanes
    always @(*) begin
        if (in_second_pass) begin
            // Second pass: high bytes of rs2 shifted into the low lanes of word N+1
            case (mem_stage_funct3)
                F3_SH:   dmem_write_data = {24'b0, mem_stage_store_data[15:8]};               // off==3 only
                F3_SW: case (off)
                    2'b01: dmem_write_data = {24'b0, mem_stage_store_data[31:24]};
                    2'b10: dmem_write_data = {16'b0, mem_stage_store_data[31:16]};
                    default: dmem_write_data = {8'b0,  mem_stage_store_data[31:8]};            // off==3
                endcase
                default: dmem_write_data = mem_stage_store_data;
            endcase
        end else begin
            // First pass: rs2 data shifted left by off bytes
            case (mem_stage_funct3)
                F3_SB: dmem_write_data = {4{mem_stage_store_data[7:0]}};
                F3_SH: case (off)
                    2'b00: dmem_write_data = {2{mem_stage_store_data[15:0]}};
                    2'b01: dmem_write_data = {8'b0,  mem_stage_store_data[15:0], 8'b0};
                    2'b10: dmem_write_data = {mem_stage_store_data[15:0], 16'b0};
                    default: dmem_write_data = {mem_stage_store_data[7:0], 24'b0};             // off==3
                endcase
                default: case (off)  // F3_SW
                    2'b00: dmem_write_data = mem_stage_store_data;
                    2'b01: dmem_write_data = {mem_stage_store_data[23:0], 8'b0};
                    2'b10: dmem_write_data = {mem_stage_store_data[15:0], 16'b0};
                    default: dmem_write_data = {mem_stage_store_data[7:0], 24'b0};             // off==3
                endcase
            endcase
        end
    end

    // Byte enables
    always @(*) begin
        if (in_second_pass) begin
            // Second pass: remaining bytes in word N+1
            case (mem_stage_funct3)
                F3_SH:   dmem_byte_enable = 4'b0001;                              // sh off==3: 1 byte
                F3_SW: case (off)
                    2'b01: dmem_byte_enable = 4'b0001;
                    2'b10: dmem_byte_enable = 4'b0011;
                    default: dmem_byte_enable = 4'b0111;                           // off==3: 3 bytes
                endcase
                default: dmem_byte_enable = 4'b1111;                              // loads: full word
            endcase
        end else begin
            // First pass: bytes starting at offset off within word N
            case (mem_stage_funct3)
                F3_SB:   dmem_byte_enable = 4'b0001 << off;
                F3_SH:   dmem_byte_enable = (4'b0011 << off) & 4'b1111;
                F3_SW:   dmem_byte_enable = (4'b1111 << off) & 4'b1111;
                default: dmem_byte_enable = 4'b1111;                              // loads: full word
            endcase
        end
    end

endmodule
