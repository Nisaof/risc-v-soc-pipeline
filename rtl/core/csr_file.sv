// ============================================================
// Module  : csr_file
// Purpose : Machine-level CSR register file for RV32IM
//           Implements MSTATUS, MIE, MTVEC, MSCRATCH, MEPC,
//           MCAUSE, MTVAL (write), MIP and MHARTID (read-only).
//           Handles trap entry (exceptions + timer IRQ) and MRET.
// ============================================================

import riscv_pkg::*;

module csr_file (
    input  logic        clk,
    input  logic        rst_n,

    // Trap / return control (from control_unit via datapath)
    input  logic        trap_en,          // HIGH in STATE_TRAP: save PC+cause, disable MIE
    input  logic        mret_en,          // HIGH in STATE_EXECUTE for MRET: restore MIE
    input  logic [31:0] trap_cause,       // MCAUSE value to write on trap entry
    input  logic [31:0] trap_val,         // MTVAL value to write on trap entry
    input  logic [31:0] trap_pc,          // PC to save into MEPC on trap entry

    // External interrupt request
    input  logic        irq_m_timer,      // machine timer interrupt from timer peripheral

    // CSR instruction interface (from datapath, active in STATE_EXECUTE)
    input  logic [11:0] csr_addr,         // CSR address field from instruction[31:20]
    input  logic [31:0] csr_wdata,        // write data: rs1_data or zimm
    input  logic [1:0]  csr_op,           // 00=write, 01=set-bits, 10=clear-bits
    input  logic        csr_write_en,     // enable write (gated for CSRRS/CSRRC with rs1=x0)
    input  logic        instret_en,       // HIGH in the cycle an instruction retires
    // Pipeline CSR commit interface (WB stage)
    input  logic        pipe_csr_write_en,
    input  logic [11:0] pipe_csr_addr,
    input  logic [31:0] pipe_csr_wdata,

    // Outputs
    output logic [31:0] csr_rdata,        // old CSR value (for rd writeback)
    output logic [31:0] mtvec_out,        // trap vector PC
    output logic [31:0] mepc_out,         // exception return PC
    output logic        irq_pending       // = irq_m_timer & MSTATUS.MIE & MIE.MTIE
);

    // --------------------------------------------------------
    // CSR storage
    // --------------------------------------------------------
    logic        mstatus_mie;    // MSTATUS[3]: global machine interrupt enable
    logic        mstatus_mpie;   // MSTATUS[7]: saved MIE (restored on MRET)
    logic [31:0] mie_reg;        // machine interrupt enable (bits 3/7/11 only)
    logic [31:0] mtvec_reg;      // trap-handler base address
    logic [31:0] mscratch_reg;   // scratch register for trap handlers
    logic [31:0] mepc_reg;       // machine exception program counter
    logic [31:0] mcause_reg;     // trap cause
    logic [31:0] mtval_reg;      // trap value (offending address / instruction)
    logic [31:0] mcycle_reg;     // counts every clock cycle
    logic [31:0] minstret_reg;   // counts retired instructions

    // --------------------------------------------------------
    // Combinational read — returns current register value
    // before any write that occurs this cycle
    // --------------------------------------------------------
    always @(*) begin
        case (csr_addr)
            CSR_MSTATUS:  csr_rdata = {19'b0, 2'b11, 3'b0,
                                        mstatus_mpie, 3'b0,
                                        mstatus_mie,  3'b0};
            CSR_MIE:      csr_rdata = mie_reg & 32'h888;
            CSR_MTVEC:    csr_rdata = mtvec_reg;
            CSR_MSCRATCH: csr_rdata = mscratch_reg;
            CSR_MEPC:     csr_rdata = mepc_reg;
            CSR_MCAUSE:   csr_rdata = mcause_reg;
            CSR_MTVAL:    csr_rdata = mtval_reg;
            CSR_MIP:      csr_rdata = (irq_m_timer ? 32'h80 : 32'h0); // bit 7 = MTIP
            CSR_MHARTID:  csr_rdata = 32'b0;
            CSR_CYCLE:    csr_rdata = mcycle_reg;
            CSR_INSTRET:  csr_rdata = minstret_reg;
            default:      csr_rdata = 32'b0;
        endcase
    end

    // --------------------------------------------------------
    // New write value for explicit CSR instructions
    // --------------------------------------------------------
    logic [31:0] csr_new_val;
    always @(*) begin
        case (csr_op)
            2'b00:   csr_new_val = csr_wdata;                     // CSRRW/CSRRWI: overwrite
            2'b01:   csr_new_val = csr_rdata | csr_wdata;         // CSRRS/CSRRSI: set bits
            2'b10:   csr_new_val = csr_rdata & ~csr_wdata;        // CSRRC/CSRRCI: clear bits
            default: csr_new_val = csr_wdata;
        endcase
    end

    // --------------------------------------------------------
    // Synchronous write logic
    // Priority: trap_en > mret_en > csr_write_en
    // --------------------------------------------------------
    // mcycle increments every clock; minstret increments on instruction retirement.
    // Kept in separate always_ff so they are independent of trap/mret/write priority.
    always_ff @(posedge clk) begin
        if (!rst_n) mcycle_reg <= 32'b0;
        else        mcycle_reg <= mcycle_reg + 32'd1;
    end

    always_ff @(posedge clk) begin
        if (!rst_n)          minstret_reg <= 32'b0;
        else if (instret_en) minstret_reg <= minstret_reg + 32'd1;
    end

    always_ff @(posedge clk) begin
    if (!rst_n) begin
        mstatus_mie  <= 1'b0;
        mstatus_mpie <= 1'b0;
        mie_reg      <= 32'b0;
        mtvec_reg    <= 32'b0;
        mscratch_reg <= 32'b0;
        mepc_reg     <= 32'b0;
        mcause_reg   <= 32'b0;
        mtval_reg    <= 32'b0;
    end
    else begin

        // ----------------------------------------------------
        // Older pipeline CSR instruction commits at WB.
        // This is allowed to happen in the same cycle that a
        // younger instruction takes a trap or executes MRET.
        // ----------------------------------------------------
        if (pipe_csr_write_en) begin
            case (pipe_csr_addr)

                CSR_MSTATUS: begin
                    mstatus_mie  <= pipe_csr_wdata[3];
                    mstatus_mpie <= pipe_csr_wdata[7];
                end

                CSR_MIE: begin
                    mie_reg <= pipe_csr_wdata & 32'h888;
                end

                CSR_MTVEC: begin
                    mtvec_reg <= pipe_csr_wdata;
                end

                CSR_MSCRATCH: begin
                    mscratch_reg <= pipe_csr_wdata;
                end

                CSR_MEPC: begin
                    mepc_reg <= {pipe_csr_wdata[31:2], 2'b00};
                end

                CSR_MCAUSE: begin
                    mcause_reg <= pipe_csr_wdata;
                end

                CSR_MTVAL: begin
                    mtval_reg <= pipe_csr_wdata;
                end

                default: begin
                end
            endcase
        end

        // ----------------------------------------------------
        // Legacy multi-cycle CSR write path.
        // Used only when there is no pipeline CSR commit,
        // trap, or MRET in this cycle.
        // ----------------------------------------------------
        else if (!trap_en && !mret_en && csr_write_en) begin
            case (csr_addr)

                CSR_MSTATUS: begin
                    mstatus_mie  <= csr_new_val[3];
                    mstatus_mpie <= csr_new_val[7];
                end

                CSR_MIE: begin
                    mie_reg <= csr_new_val & 32'h888;
                end

                CSR_MTVEC: begin
                    mtvec_reg <= csr_new_val;
                end

                CSR_MSCRATCH: begin
                    mscratch_reg <= csr_new_val;
                end

                CSR_MEPC: begin
                    mepc_reg <= {csr_new_val[31:2], 2'b00};
                end

                CSR_MCAUSE: begin
                    mcause_reg <= csr_new_val;
                end

                CSR_MTVAL: begin
                    mtval_reg <= csr_new_val;
                end

                default: begin
                end
            endcase
        end

        // ----------------------------------------------------
        // Trap entry.
        // Comes after CSR commit so trap state wins for
        // MEPC/MCAUSE/MTVAL and MSTATUS trap fields.
        // ----------------------------------------------------
        if (trap_en) begin
            mepc_reg   <= trap_pc;
            mcause_reg <= trap_cause;
            mtval_reg  <= trap_val;

            // If an older MSTATUS CSR write commits in this
            // same cycle, trap entry must save that new MIE.
            if (pipe_csr_write_en &&
                (pipe_csr_addr == CSR_MSTATUS))
                mstatus_mpie <= pipe_csr_wdata[3];
            else
                mstatus_mpie <= mstatus_mie;

            mstatus_mie <= 1'b0;
        end

        // ----------------------------------------------------
        // MRET
        // ----------------------------------------------------
        else if (mret_en) begin
            // Same ordering rule for an older MSTATUS write.
            if (pipe_csr_write_en &&
                (pipe_csr_addr == CSR_MSTATUS))
                mstatus_mie <= pipe_csr_wdata[7];
            else
                mstatus_mie <= mstatus_mpie;

            mstatus_mpie <= 1'b1;
        end
    end
end

    // --------------------------------------------------------
    // Output signals
    // --------------------------------------------------------
    assign mtvec_out  = {mtvec_reg[31:2], 2'b00};  // direct mode: BASE only
    assign mepc_out   = mepc_reg;
    logic irq_mie_effective;
logic irq_mtie_effective;

always @(*) begin
    irq_mie_effective  = mstatus_mie;
    irq_mtie_effective = mie_reg[7];

    // See an older CSR write in WB in the same cycle.
    if (pipe_csr_write_en) begin
        if (pipe_csr_addr == CSR_MSTATUS)
            irq_mie_effective = pipe_csr_wdata[3];

        if (pipe_csr_addr == CSR_MIE)
            irq_mtie_effective = pipe_csr_wdata[7];
    end
end

assign irq_pending =
    irq_m_timer &&
    irq_mie_effective &&
    irq_mtie_effective;
endmodule
