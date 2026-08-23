// fetch.sv
// IF stage. Holds the PC, reads the instruction memory, and registers the
// (pc, instr) pair into the IF/ID pipeline register.
//
// NOTE: imem is still declared inline here. It has to move into its own
// dual-port module before the UART loader can write it.

module fetch
    import pipeline_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic        stall,          // load-use hazard: hold pc and if_id_reg
    input  logic        branch_taken,   // redirect from EX
    input  logic [31:0] branch_target,
    output if_id_t      if_id_reg
);
    localparam int IMEM_WORDS = 1024;
    localparam int IMEM_IDX_W = $clog2(IMEM_WORDS);   // 10 bits

    logic [31:0] pc;
    logic [31:0] imem [IMEM_WORDS];

    // word index: pc is byte-addressed and pc[1:0] are always 0
    logic [IMEM_IDX_W-1:0] imem_idx;
    assign imem_idx = pc[IMEM_IDX_W+1:2];

    // branch_taken outranks stall. Today they are mutually exclusive (a load-use
    // stall means EX holds a load, and a load is never a branch), but if a
    // multi-cycle memory stall is ever added, a redirect must not be dropped.
    always_ff @(posedge clk) begin
        if (rst) begin
            pc              <= '0;
            if_id_reg.pc    <= '0;
            if_id_reg.instr <= '0;
            if_id_reg.valid <= 1'b0;
        end else if (branch_taken) begin
            // kill the wrongly-fetched instruction and redirect
            pc              <= branch_target;
            if_id_reg.valid <= 1'b0;
        end else if (!stall) begin
            pc              <= pc + 32'd4;
            if_id_reg.pc    <= pc;
            if_id_reg.instr <= imem[imem_idx];
            if_id_reg.valid <= 1'b1;
        end
        // else: stalled -- hold pc and if_id_reg
    end

endmodule: fetch
