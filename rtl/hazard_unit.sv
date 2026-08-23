// hazard_unit.sv
// Purely combinational. Produces the stall and flush controls for the front end.
//
// Two events are handled:
//
//  1. Load-use hazard. A load in EX produces its data at the END of MEM, so a
//     consumer sitting in ID cannot be forwarded in time. Hold IF/ID (so the
//     consumer re-decodes next cycle) and drop a bubble into ID/EX. One cycle
//     later the load is in MEM/WB and normal MEM->EX forwarding covers it.
//
//  2. Branch/jump taken. The branch resolves in EX, so the two younger
//     instructions already fetched behind it are wrong. fetch kills the one
//     entering IF/ID itself; this unit kills the one in ID by flushing ID/EX.

module hazard_unit
    import pipeline_pkg::*;
(
    // ID stage: which registers the instruction currently in ID will read
    input  logic [4:0] id_rs1_addr,
    input  logic [4:0] id_rs2_addr,
    input  logic       id_uses_rs1,
    input  logic       id_uses_rs2,

    // EX stage
    input  id_ex_t     id_ex_reg,
    input  logic       branch_taken,

    output logic       stall_if,   // hold pc and if_id_reg
    output logic       bubble_id,  // clear id_ex_reg (load-use)
    output logic       flush_id    // clear id_ex_reg (branch taken)
);

    logic load_in_ex;
    logic rs1_conflict, rs2_conflict;
    logic load_use;

    assign load_in_ex = id_ex_reg.valid &&
                        id_ex_reg.mem_read &&
                        (id_ex_reg.rd_addr != 5'd0);

    assign rs1_conflict = id_uses_rs1 && (id_ex_reg.rd_addr == id_rs1_addr);
    assign rs2_conflict = id_uses_rs2 && (id_ex_reg.rd_addr == id_rs2_addr);

    assign load_use = load_in_ex && (rs1_conflict || rs2_conflict);

    assign stall_if  = load_use;
    assign bubble_id = load_use;
    assign flush_id  = branch_taken;

endmodule: hazard_unit
