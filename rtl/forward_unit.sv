// forward_unit.sv
// Purely combinational. Decides, for each EX-stage source operand, whether to
// use the register file value or a value still in flight further down the pipe.
//
// Priority matters: EX/MEM holds the YOUNGER instruction, so when both EX/MEM
// and MEM/WB write the same register, EX/MEM wins.
//
//   add x1, ...        <- older,   in MEM/WB when the consumer is in EX
//   add x1, ...        <- younger, in EX/MEM when the consumer is in EX
//   add x2, x1, x3     <- consumer, must see the younger x1

module forward_unit
    import pipeline_pkg::*;
(
    input  id_ex_t   id_ex_reg,
    input  ex_mem_t  ex_mem_reg,
    input  mem_wb_t  mem_wb_reg,

    output fwd_sel_t fwd_a,
    output fwd_sel_t fwd_b
);

    // reg_write is already gated by valid in execute/mem, and decode already
    // clears reg_write when rd == x0, so the rd_addr != 0 tests below are
    // belt-and-braces. They cost nothing and make this module safe in isolation.
    logic ex_hit_a, wb_hit_a;
    logic ex_hit_b, wb_hit_b;

    assign ex_hit_a = ex_mem_reg.reg_write &&
                      (ex_mem_reg.rd_addr != 5'd0) &&
                      (ex_mem_reg.rd_addr == id_ex_reg.rs1_addr);

    assign wb_hit_a = mem_wb_reg.reg_write &&
                      (mem_wb_reg.rd_addr != 5'd0) &&
                      (mem_wb_reg.rd_addr == id_ex_reg.rs1_addr);

    assign ex_hit_b = ex_mem_reg.reg_write &&
                      (ex_mem_reg.rd_addr != 5'd0) &&
                      (ex_mem_reg.rd_addr == id_ex_reg.rs2_addr);

    assign wb_hit_b = mem_wb_reg.reg_write &&
                      (mem_wb_reg.rd_addr != 5'd0) &&
                      (mem_wb_reg.rd_addr == id_ex_reg.rs2_addr);

    always_comb begin
        if      (ex_hit_a) fwd_a = FWD_EX;   // younger value wins
        else if (wb_hit_a) fwd_a = FWD_WB;
        else               fwd_a = FWD_NONE;
    end

    always_comb begin
        if      (ex_hit_b) fwd_b = FWD_EX;
        else if (wb_hit_b) fwd_b = FWD_WB;
        else               fwd_b = FWD_NONE;
    end

endmodule: forward_unit
