// execute.sv
// EX stage. Owns four jobs:
//   1. resolve forwarding on rs1/rs2 (EX->EX and MEM->EX)
//   2. select ALU operands and run the ALU
//   3. resolve the branch/jump decision and compute the redirect target
//   4. register everything MEM needs into EX/MEM
//
// The forwarded rs1/rs2 values are resolved exactly once, here, and the
// forwarded rs2 is what gets stored as store data -- MEM never re-forwards.

module execute
    import pipeline_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  id_ex_t      id_ex_reg,

    // forwarding: selects come from forward_unit, data comes from the later stages
    input  fwd_sel_t    fwd_a,
    input  fwd_sel_t    fwd_b,
    input  logic [31:0] ex_mem_fwd_data,   // ALU result held in EX/MEM
    input  logic [31:0] wb_fwd_data,       // value WB is about to write

    // redirect back to fetch
    output logic        branch_taken,
    output logic [31:0] branch_target,

    output ex_mem_t     ex_mem_reg
);

    // -------------------------------------------------------------------------
    // forwarding muxes
    // Resolved before operand select, so every downstream consumer (ALU operands,
    // store data, JALR target base) automatically sees the forwarded value.
    // -------------------------------------------------------------------------
    logic [31:0] rs1_fwd, rs2_fwd;

    always_comb begin
        case (fwd_a)
            FWD_EX:  rs1_fwd = ex_mem_fwd_data;
            FWD_WB:  rs1_fwd = wb_fwd_data;
            default: rs1_fwd = id_ex_reg.rs1_data;
        endcase
    end

    always_comb begin
        case (fwd_b)
            FWD_EX:  rs2_fwd = ex_mem_fwd_data;
            FWD_WB:  rs2_fwd = wb_fwd_data;
            default: rs2_fwd = id_ex_reg.rs2_data;
        endcase
    end

    // -------------------------------------------------------------------------
    // ALU operand select
    // -------------------------------------------------------------------------
    logic [31:0] alu_a, alu_b;

    always_comb begin
        case (id_ex_reg.alu_srca)
            SRCA_PC: alu_a = id_ex_reg.pc;
            default: alu_a = rs1_fwd;
        endcase
    end

    always_comb begin
        case (id_ex_reg.alu_srcb)
            SRCB_IMM:  alu_b = id_ex_reg.imm;
            SRCB_FOUR: alu_b = 32'd4;
            default:   alu_b = rs2_fwd;
        endcase
    end

    logic [31:0] alu_result;
    logic        alu_zero;

    alu u_alu (
        .a      (alu_a),
        .b      (alu_b),
        .op     (id_ex_reg.alu_op),
        .result (alu_result),
        .zero   (alu_zero)
    );

    // -------------------------------------------------------------------------
    // branch condition
    // decode collapsed the six branches into three compare ops; funct3[0] is the
    // "invert the answer" bit:
    //   BEQ  000 / BNE  001  -> ALU_SUB,  test zero
    //   BLT  100 / BGE  101  -> ALU_SLT,  test result bit 0
    //   BLTU 110 / BGEU 111  -> ALU_SLTU, test result bit 0
    // -------------------------------------------------------------------------
    logic cond_raw, cond;

    always_comb begin
        if (id_ex_reg.mem_funct3[2:1] == 2'b00) begin
            cond_raw = alu_zero;         // equality test
        end else begin
            cond_raw = alu_result[0];    // SLT / SLTU result
        end
    end

    assign cond = cond_raw ^ id_ex_reg.mem_funct3[0];

    // a bubble must never redirect fetch, hence the valid gate
    assign branch_taken = id_ex_reg.valid &&
                          ((id_ex_reg.branch && cond) || id_ex_reg.jump);

    // -------------------------------------------------------------------------
    // branch / jump target adder
    // Separate from the ALU because the ALU is busy: comparing operands for a
    // branch, or computing the PC+4 link value for a jump.
    // The base MUST be the forwarded rs1 for JALR.
    // Forcing bit 0 low is unconditional: B- and J-type immediates have no bit 0
    // and PC is always 4-aligned, so it only does real work for JALR.
    // -------------------------------------------------------------------------
    logic [31:0] target_base, target_sum;

    assign target_base   = id_ex_reg.jalr ? rs1_fwd : id_ex_reg.pc;
    assign target_sum    = target_base + id_ex_reg.imm;
    assign branch_target = {target_sum[31:1], 1'b0};

    // -------------------------------------------------------------------------
    // EX/MEM pipeline register
    // -------------------------------------------------------------------------
    ex_mem_t ex_mem_comb;

    always_comb begin
        ex_mem_comb              = '0;
        ex_mem_comb.mem_read     = id_ex_reg.mem_read  && id_ex_reg.valid;
        ex_mem_comb.mem_write    = id_ex_reg.mem_write && id_ex_reg.valid;
        ex_mem_comb.reg_write    = id_ex_reg.reg_write && id_ex_reg.valid;
        ex_mem_comb.mem_funct3   = id_ex_reg.mem_funct3;
        ex_mem_comb.mem_to_reg   = id_ex_reg.mem_to_reg;
        ex_mem_comb.alu_result   = alu_result;
        ex_mem_comb.rs2_data     = rs2_fwd;          // forwarded store data
        ex_mem_comb.pc_next      = branch_target;
        ex_mem_comb.branch_taken = branch_taken;
        ex_mem_comb.rd_addr      = id_ex_reg.rd_addr;
        ex_mem_comb.valid        = id_ex_reg.valid;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ex_mem_reg <= '0;
        end else begin
            ex_mem_reg <= ex_mem_comb;
        end
    end

endmodule: execute
