// decode.sv
// ID stage. Decodes the instruction word, pairs it with the register file read
// data, and registers a fully-resolved control/data bundle into ID/EX.
//
// Everything EX needs is settled here: EX never looks at instruction bits.

module decode
    import pipeline_pkg::*;
(
    input  logic        clk,
    input  logic        rst,
    input  logic        stall,      // load-use hazard: inject a bubble into ID/EX
    input  logic        flush,      // branch taken in EX: kill this instruction
    input  if_id_t      if_id_reg,  // from fetch

    // register file read port: addresses out combinationally, data back same cycle
    output logic [4:0]  rs1_addr,
    output logic [4:0]  rs2_addr,
    input  logic [31:0] rs1_data,
    input  logic [31:0] rs2_data,

    // to hazard_unit: does this instruction actually read these registers?
    // Without these the hazard unit false-stalls, because instr[24:20] is
    // immediate data (not a register number) in I/U/J-type encodings.
    output logic        uses_rs1,
    output logic        uses_rs2,

    output id_ex_t      id_ex_reg
);

    // -------------------------------------------------------------------------
    // instruction field extraction
    // -------------------------------------------------------------------------
    logic [31:0] instr;
    logic [6:0]  opcode;
    logic [2:0]  funct3;
    logic [4:0]  rd_addr;
    logic        funct7_b5;   // instr[30]: ADD/SUB and SRL/SRA discriminator

    assign instr     = if_id_reg.instr;
    assign opcode    = instr[6:0];
    assign funct3    = instr[14:12];
    assign rd_addr   = instr[11:7];
    assign rs1_addr  = instr[19:15];
    assign rs2_addr  = instr[24:20];
    assign funct7_b5 = instr[30];

    // -------------------------------------------------------------------------
    // immediate generation
    // B- and J-type immediates have no bit 0 in the encoding; the literal 1'b0
    // is what guarantees branch/jump targets are always even.
    // -------------------------------------------------------------------------
    logic [31:0] imm;

    always_comb begin
        case (opcode)
            OP_I_ALU, OP_LOAD, OP_JALR:
                imm = {{20{instr[31]}}, instr[31:20]};
            OP_STORE:
                imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
            OP_BRANCH:
                imm = {{19{instr[31]}}, instr[31], instr[7],
                       instr[30:25], instr[11:8], 1'b0};
            OP_LUI, OP_AUIPC:
                imm = {instr[31:12], 12'b0};
            OP_JAL:
                imm = {{11{instr[31]}}, instr[31], instr[19:12],
                       instr[20], instr[30:21], 1'b0};
            default:
                imm = 32'b0;
        endcase
    end

    // -------------------------------------------------------------------------
    // source register usage (for the hazard unit)
    // -------------------------------------------------------------------------
    always_comb begin
        case (opcode)
            OP_R, OP_STORE, OP_BRANCH: begin
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b1;
            end
            OP_I_ALU, OP_LOAD, OP_JALR: begin
                uses_rs1 = 1'b1;
                uses_rs2 = 1'b0;
            end
            default: begin              // LUI, AUIPC, JAL, illegal
                uses_rs1 = 1'b0;
                uses_rs2 = 1'b0;
            end
        endcase
    end

    // -------------------------------------------------------------------------
    // ALU operation select
    // Loads/stores/AUIPC/JAL/JALR all fall through to ADD (address or link calc).
    // -------------------------------------------------------------------------
    alu_op_t alu_op;

    always_comb begin
        alu_op = ALU_ADD;
        case (opcode)
            OP_R: begin
                case (funct3)
                    3'b000: alu_op = funct7_b5 ? ALU_SUB : ALU_ADD;
                    3'b001: alu_op = ALU_SLL;
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = funct7_b5 ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                endcase
            end
            OP_I_ALU: begin
                case (funct3)
                    3'b000: alu_op = ALU_ADD;   // ADDI: instr[30] is immediate data,
                                                //       NOT a funct7 bit. Do not test it.
                    3'b001: alu_op = ALU_SLL;   // SLLI: shamt encoding, funct7 is real
                    3'b010: alu_op = ALU_SLT;
                    3'b011: alu_op = ALU_SLTU;
                    3'b100: alu_op = ALU_XOR;
                    3'b101: alu_op = funct7_b5 ? ALU_SRA : ALU_SRL;
                    3'b110: alu_op = ALU_OR;
                    3'b111: alu_op = ALU_AND;
                endcase
            end
            OP_BRANCH: begin
                // funct3[0] is the "invert the answer" bit, handled in EX,
                // so only three distinct compare ops are needed here.
                case (funct3[2:1])
                    2'b00:   alu_op = ALU_SUB;    // BEQ  / BNE
                    2'b10:   alu_op = ALU_SLT;    // BLT  / BGE
                    2'b11:   alu_op = ALU_SLTU;   // BLTU / BGEU
                    default: alu_op = ALU_SUB;
                endcase
            end
            OP_LUI:  alu_op = ALU_COPY_B;
            default: alu_op = ALU_ADD;
        endcase
    end

    // -------------------------------------------------------------------------
    // control signal assembly
    // Every field gets a safe baseline first, so no case branch can infer a latch.
    // -------------------------------------------------------------------------
    id_ex_t id_ex_comb;

    always_comb begin
        id_ex_comb            = '0;          // inert baseline: no writes, no mem access
        id_ex_comb.alu_op     = alu_op;
        id_ex_comb.alu_srca   = SRCA_RS1;
        id_ex_comb.alu_srcb   = SRCB_RS2;
        id_ex_comb.pc         = if_id_reg.pc;
        id_ex_comb.rs1_data   = rs1_data;
        id_ex_comb.rs2_data   = rs2_data;
        id_ex_comb.imm        = imm;
        id_ex_comb.rs1_addr   = rs1_addr;
        id_ex_comb.rs2_addr   = rs2_addr;
        id_ex_comb.rd_addr    = rd_addr;
        id_ex_comb.mem_funct3 = funct3;      // load/store width, and branch condition
        id_ex_comb.valid      = if_id_reg.valid;

        case (opcode)
            OP_R: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.alu_srcb  = SRCB_RS2;
            end
            OP_I_ALU: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.alu_srcb  = SRCB_IMM;
            end
            OP_LOAD: begin
                id_ex_comb.reg_write  = 1'b1;
                id_ex_comb.mem_read   = 1'b1;
                id_ex_comb.mem_to_reg = 1'b1;
                id_ex_comb.alu_srcb   = SRCB_IMM;   // address = rs1 + imm
            end
            OP_STORE: begin
                id_ex_comb.mem_write = 1'b1;
                id_ex_comb.alu_srcb  = SRCB_IMM;    // address = rs1 + imm;
                                                    // store data rides in rs2_data
            end
            OP_BRANCH: begin
                id_ex_comb.branch   = 1'b1;
                id_ex_comb.alu_srcb = SRCB_RS2;     // ALU compares; target adder is separate
            end
            OP_LUI: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.alu_srcb  = SRCB_IMM;    // ALU_COPY_B ignores srcA
            end
            OP_AUIPC: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.alu_srca  = SRCA_PC;
                id_ex_comb.alu_srcb  = SRCB_IMM;
            end
            OP_JAL: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.jump      = 1'b1;
                id_ex_comb.alu_srca  = SRCA_PC;
                id_ex_comb.alu_srcb  = SRCB_FOUR;   // ALU makes the link value PC+4
            end
            OP_JALR: begin
                id_ex_comb.reg_write = 1'b1;
                id_ex_comb.jump      = 1'b1;
                id_ex_comb.jalr      = 1'b1;        // target base is rs1, not PC
                id_ex_comb.alu_srca  = SRCA_PC;
                id_ex_comb.alu_srcb  = SRCB_FOUR;
            end
            default: begin
                id_ex_comb.valid = 1'b0;            // unrecognized opcode: treat as bubble
            end
        endcase

        // x0 is hardwired to zero, so a write to it is architecturally a no-op.
        // Killing reg_write here makes the regfile write guard, the regfile
        // write-through bypass, and the forwarding unit all safe from one place.
        if (rd_addr == 5'd0) begin
            id_ex_comb.reg_write = 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // ID/EX pipeline register
    // A load-use stall holds IF/ID (so this instruction is re-decoded next cycle)
    // and injects a bubble here, so stall and flush do the same thing to this reg.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst || flush || stall) begin
            id_ex_reg <= '0;
        end else begin
            id_ex_reg <= id_ex_comb;
        end
    end

endmodule: decode
