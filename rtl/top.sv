// top.sv
// Ties the five stages together with the hazard and forwarding units.
//
// The register file lives here rather than inside decode, because it spans two
// stages: read in ID, written in WB.

module top
    import pipeline_pkg::*;
(
    input logic clk,
    input logic rst
);

    // ---- inter-stage registers ----
    if_id_t  if_id_reg;
    id_ex_t  id_ex_reg;
    ex_mem_t ex_mem_reg;
    mem_wb_t mem_wb_reg;

    // ---- ID <-> register file ----
    logic [4:0]  rs1_addr, rs2_addr;
    logic [31:0] rs1_data, rs2_data;
    logic        uses_rs1, uses_rs2;

    // ---- WB -> register file (and -> forwarding) ----
    logic [4:0]  wb_rd_addr;
    logic [31:0] wb_wdata;
    logic        wb_we;

    // ---- EX -> IF redirect ----
    logic        branch_taken;
    logic [31:0] branch_target;

    // ---- control ----
    logic        stall_if, bubble_id, flush_id;
    fwd_sel_t    fwd_a, fwd_b;

    // -------------------------------------------------------------------------
    // IF
    // -------------------------------------------------------------------------
    fetch u_fetch (
        .clk           (clk),
        .rst           (rst),
        .stall         (stall_if),
        .branch_taken  (branch_taken),
        .branch_target (branch_target),
        .if_id_reg     (if_id_reg)
    );

    // -------------------------------------------------------------------------
    // ID
    // -------------------------------------------------------------------------
    decode u_decode (
        .clk       (clk),
        .rst       (rst),
        .stall     (bubble_id),
        .flush     (flush_id),
        .if_id_reg (if_id_reg),
        .rs1_addr  (rs1_addr),
        .rs2_addr  (rs2_addr),
        .rs1_data  (rs1_data),
        .rs2_data  (rs2_data),
        .uses_rs1  (uses_rs1),
        .uses_rs2  (uses_rs2),
        .id_ex_reg (id_ex_reg)
    );

    // read in ID, written by WB -- hence instantiated here, not inside a stage
    regs u_regs (
        .clk    (clk),
        .rs1    (rs1_addr),
        .rs2    (rs2_addr),
        .w_addr (wb_rd_addr),
        .w_data (wb_wdata),
        .we     (wb_we),
        .rd1    (rs1_data),
        .rd2    (rs2_data)
    );

    // -------------------------------------------------------------------------
    // EX
    // -------------------------------------------------------------------------
    execute u_execute (
        .clk             (clk),
        .rst             (rst),
        .id_ex_reg       (id_ex_reg),
        .fwd_a           (fwd_a),
        .fwd_b           (fwd_b),
        .ex_mem_fwd_data (ex_mem_reg.alu_result),
        .wb_fwd_data     (wb_wdata),
        .branch_taken    (branch_taken),
        .branch_target   (branch_target),
        .ex_mem_reg      (ex_mem_reg)
    );

    // -------------------------------------------------------------------------
    // MEM
    // -------------------------------------------------------------------------
    mem_stage u_mem_stage (
        .clk        (clk),
        .rst        (rst),
        .ex_mem_reg (ex_mem_reg),
        .mem_wb_reg (mem_wb_reg)
    );

    // -------------------------------------------------------------------------
    // WB
    // -------------------------------------------------------------------------
    writeback u_writeback (
        .mem_wb_reg (mem_wb_reg),
        .wb_rd_addr (wb_rd_addr),
        .wb_wdata   (wb_wdata),
        .wb_we      (wb_we)
    );

    // -------------------------------------------------------------------------
    // control
    // -------------------------------------------------------------------------
    forward_unit u_forward_unit (
        .id_ex_reg  (id_ex_reg),
        .ex_mem_reg (ex_mem_reg),
        .mem_wb_reg (mem_wb_reg),
        .fwd_a      (fwd_a),
        .fwd_b      (fwd_b)
    );

    hazard_unit u_hazard_unit (
        .id_rs1_addr  (rs1_addr),
        .id_rs2_addr  (rs2_addr),
        .id_uses_rs1  (uses_rs1),
        .id_uses_rs2  (uses_rs2),
        .id_ex_reg    (id_ex_reg),
        .branch_taken (branch_taken),
        .stall_if     (stall_if),
        .bubble_id    (bubble_id),
        .flush_id     (flush_id)
    );

endmodule: top
