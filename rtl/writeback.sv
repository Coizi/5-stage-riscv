// writeback.sv
// WB stage. Purely combinational -- it owns no pipeline register because it is
// the end of the pipe; its "register" is the register file itself.
//
// Two jobs:
//   1. format the raw DMEM word into the value a load actually writes
//      (lane select + sign or zero extension)
//   2. pick between that and the ALU result, and drive the regfile write port
//
// The value it produces is also what MEM->EX forwarding uses, so wb_wdata feeds
// both the register file and forward_unit's FWD_WB path. Those must be the same
// signal: if forwarding sent a different value than the one being written, a
// register would take on two different values depending on who read it.

module writeback
    import pipeline_pkg::*;
(
    input  mem_wb_t     mem_wb_reg,

    output logic [4:0]  wb_rd_addr,
    output logic [31:0] wb_wdata,
    output logic        wb_we
);

    // -------------------------------------------------------------------------
    // lane select
    // A byte load can target any of the four lanes; a halfword load either half.
    // -------------------------------------------------------------------------
    logic [7:0]  sel_byte;
    logic [15:0] sel_half;

    always_comb begin
        case (mem_wb_reg.addr_lsb)
            2'b00: sel_byte = mem_wb_reg.mem_rdata[7:0];
            2'b01: sel_byte = mem_wb_reg.mem_rdata[15:8];
            2'b10: sel_byte = mem_wb_reg.mem_rdata[23:16];
            2'b11: sel_byte = mem_wb_reg.mem_rdata[31:24];
        endcase
    end

    assign sel_half = mem_wb_reg.addr_lsb[1] ? mem_wb_reg.mem_rdata[31:16]
                                             : mem_wb_reg.mem_rdata[15:0];

    // -------------------------------------------------------------------------
    // width + extension
    //   funct3[2] is the UNSIGNED bit, funct3[1:0] is the width
    //   000 LB   001 LH   010 LW   100 LBU   101 LHU
    // -------------------------------------------------------------------------
    logic [31:0] load_data;

    always_comb begin
        case (mem_wb_reg.mem_funct3)
            3'b000:  load_data = {{24{sel_byte[7]}},  sel_byte};   // LB
            3'b001:  load_data = {{16{sel_half[15]}}, sel_half};   // LH
            3'b100:  load_data = {24'b0, sel_byte};                // LBU
            3'b101:  load_data = {16'b0, sel_half};                // LHU
            default: load_data = mem_wb_reg.mem_rdata;             // LW
        endcase
    end

    // -------------------------------------------------------------------------
    // regfile write port
    // reg_write was already gated by valid (in execute) and by rd != x0 (in
    // decode), so no further qualification is needed here.
    // -------------------------------------------------------------------------
    assign wb_wdata   = mem_wb_reg.mem_to_reg ? load_data : mem_wb_reg.alu_result;
    assign wb_rd_addr = mem_wb_reg.rd_addr;
    assign wb_we      = mem_wb_reg.reg_write;

endmodule: writeback
