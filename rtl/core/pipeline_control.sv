// ============================================================
// Module  : pipeline_control
// Purpose : Central control for 5-stage pipeline movement.
//           Generates stage enables, holds, bubbles and flushes.
// ============================================================

module pipeline_control (
    input  logic clk,
    input  logic rst_n,

    // Stage validity
    input  logic if_id_valid,
    input  logic id_ex_valid,
    input  logic ex_mem_valid,
    input  logic mem_wb_valid,

    // Hazard / long-latency conditions
    input  logic load_use_hazard,
    input  logic mem_busy,
    input  logic mdu_busy,

    // Control-flow redirect
    input  logic redirect_valid,

    // Pipeline register enables
    output logic pipe_if_id_en,
    output logic pipe_id_ex_en,
    output logic pipe_ex_mem_en,
    output logic pipe_mem_wb_en,

    // Hold / bubble / flush controls
    output logic hold_pc,
    output logic hold_if_id,
    output logic bubble_id_ex,
    output logic flush_if_id,
    output logic flush_id_ex
);

    always @(*) begin
        // Default: pipeline advances normally
        pipe_if_id_en  = 1'b1;
        pipe_id_ex_en  = 1'b1;
        pipe_ex_mem_en = 1'b1;
        pipe_mem_wb_en = 1'b1;

        hold_pc        = 1'b0;
        hold_if_id     = 1'b0;
        bubble_id_ex   = 1'b0;
        flush_if_id    = 1'b0;
        flush_id_ex    = 1'b0;

        // Control-flow redirect has highest priority.
        if (redirect_valid) begin
            flush_if_id  = 1'b1;
            flush_id_ex  = 1'b1;
        end

        // Long-latency MEM/MDU operation stalls younger stages.
        else if (mem_busy || mdu_busy) begin
            hold_pc        = 1'b1;
            hold_if_id     = 1'b1;

            pipe_if_id_en  = 1'b0;
            pipe_id_ex_en  = 1'b0;
            pipe_ex_mem_en = 1'b0;
            pipe_mem_wb_en = 1'b0;
        end

        // Load-use hazard:
        // hold PC + IF/ID, inject bubble into ID/EX.
        else if (load_use_hazard) begin
            hold_pc       = 1'b1;
            hold_if_id    = 1'b1;
            pipe_if_id_en = 1'b0;
            bubble_id_ex  = 1'b1;
        end
    end

endmodule
