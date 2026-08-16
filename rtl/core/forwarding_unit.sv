// ============================================================
// Module  : forwarding_unit
// Purpose : EX-stage operand forwarding for 5-stage pipeline.
// Priority: EX/MEM > MEM/WB > register-file value.
// ============================================================

module forwarding_unit (
    input  logic [4:0] id_ex_rs1,
    input  logic [4:0] id_ex_rs2,

    input  logic       ex_mem_valid,
    input  logic       ex_mem_reg_write,
    input  logic [4:0] ex_mem_rd,

    input  logic       mem_wb_valid,
    input  logic       mem_wb_reg_write,
    input  logic [4:0] mem_wb_rd,

    output logic [1:0] forward_a,
    output logic [1:0] forward_b
);

    always @(*) begin
        // 00 = normal ID/EX operand
        // 01 = forward from MEM/WB
        // 10 = forward from EX/MEM
        forward_a = 2'b00;
        forward_b = 2'b00;

        // rs1 forwarding
        if (ex_mem_valid &&
            ex_mem_reg_write &&
            (ex_mem_rd != 5'd0) &&
            (ex_mem_rd == id_ex_rs1)) begin

            forward_a = 2'b10;
        end
        else if (mem_wb_valid &&
                 mem_wb_reg_write &&
                 (mem_wb_rd != 5'd0) &&
                 (mem_wb_rd == id_ex_rs1)) begin

            forward_a = 2'b01;
        end

        // rs2 forwarding
        if (ex_mem_valid &&
            ex_mem_reg_write &&
            (ex_mem_rd != 5'd0) &&
            (ex_mem_rd == id_ex_rs2)) begin

            forward_b = 2'b10;
        end
        else if (mem_wb_valid &&
                 mem_wb_reg_write &&
                 (mem_wb_rd != 5'd0) &&
                 (mem_wb_rd == id_ex_rs2)) begin

            forward_b = 2'b01;
        end
    end

endmodule
