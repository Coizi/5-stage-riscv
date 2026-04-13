// pipeline_regs.sv
// Structs for the 5-stage RISC-V pipeline inter-stage registers.
// Import this package in every stage file: `import pipeline_pkg::*;`

package pipeline_pkg;

    // -------------------------------------------------------------------------
    // Opcode / funct definitions (RV32I subset)
    // -------------------------------------------------------------------------
    typedef enum logic [6:0] {
        OP_R      = 7'b0110011,   // R-type
        OP_I_ALU  = 7'b0010011,   // I-type ALU (ADDI, ANDI, etc.)
        OP_LOAD   = 7'b0000011,   // Load (LW, LH, LB, LHU, LBU)
        OP_STORE  = 7'b0100011,   // Store (SW, SH, SB)
        OP_BRANCH = 7'b1100011,   // Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
        OP_JAL    = 7'b1101111,   // JAL
        OP_JALR   = 7'b1100111,   // JALR
        OP_LUI    = 7'b0110111,   // LUI
        OP_AUIPC  = 7'b0010111    // AUIPC
    } opcode_t;

    // ALU operation select — computed in decode, consumed in execute
    typedef enum logic [3:0] {
        ALU_ADD  = 4'b0000,
        ALU_SUB  = 4'b0001,
        ALU_AND  = 4'b0010,
        ALU_OR   = 4'b0011,
        ALU_XOR  = 4'b0100,
        ALU_SLL  = 4'b0101,
        ALU_SRL  = 4'b0110,
        ALU_SRA  = 4'b0111,
        ALU_SLT  = 4'b1000,
        ALU_SLTU = 4'b1001,
        ALU_COPY_B = 4'b1010   // LUI: pass imm straight through
    } alu_op_t;

    // Source selects for ALU operands
    typedef enum logic [1:0] {
        SRCA_RS1   = 2'b00,   // rs1 register value
        SRCA_PC    = 2'b01    // PC (AUIPC, JAL)
    } alu_srca_t;

    typedef enum logic [1:0] {
        SRCB_RS2   = 2'b00,   // rs2 register value
        SRCB_IMM   = 2'b01,   // sign-extended immediate
        SRCB_FOUR  = 2'b10    // constant 4 (JAL/JALR link address)
    } alu_srcb_t;

    // -------------------------------------------------------------------------
    // IF/ID pipeline register
    // Carries the raw fetched instruction and the PC of that instruction.
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic [31:0] pc;          // PC of fetched instruction
        logic [31:0] instr;       // raw 32-bit instruction word
        logic        valid;       // 0 if this is a bubble (NOP injected by hazard unit)
    } if_id_t;

    // -------------------------------------------------------------------------
    // ID/EX pipeline register
    // Carries everything decode has resolved: control signals, register data,
    // immediate, and the two source register addresses for the forwarding unit.
    // -------------------------------------------------------------------------
    typedef struct packed {
        // ---- control signals ----
        alu_op_t    alu_op;       // ALU operation
        alu_srca_t  alu_srca;     // ALU src A select
        alu_srcb_t  alu_srcb;     // ALU src B select
        logic       mem_read;     // asserted for load instructions
        logic       mem_write;    // asserted for store instructions
        logic [2:0] mem_funct3;   // funct3 for load/store width + sign
        logic       reg_write;    // write result to rd
        logic       mem_to_reg;   // 1 = writeback from memory, 0 = from ALU
        logic       branch;       // this is a branch instruction
        logic       jump;         // JAL or JALR
        // ---- data ----
        logic [31:0] pc;          // needed for branch/AUIPC target calc
        logic [31:0] rs1_data;    // register file read port 1
        logic [31:0] rs2_data;    // register file read port 2
        logic [31:0] imm;         // sign-extended immediate (I/S/B/U/J format)
        // ---- register addresses (for forwarding unit) ----
        logic [4:0]  rs1_addr;
        logic [4:0]  rs2_addr;
        logic [4:0]  rd_addr;
        logic        valid;
    } id_ex_t;

    // -------------------------------------------------------------------------
    // EX/MEM pipeline register
    // Carries ALU result, branch decision, and store data into the memory stage.
    // -------------------------------------------------------------------------
    typedef struct packed {
        // ---- control signals ----
        logic       mem_read;
        logic       mem_write;
        logic [2:0] mem_funct3;
        logic       reg_write;
        logic       mem_to_reg;
        // ---- data ----
        logic [31:0] alu_result;  // address for load/store; result for ALU ops
        logic [31:0] rs2_data;    // store data (after forwarding resolved in EX)
        logic [31:0] pc_next;     // branch/jump target (if taken)
        logic        branch_taken;// branch outcome from ALU zero flag + funct3
        // ---- destination ----
        logic [4:0]  rd_addr;
        logic        valid;
    } ex_mem_t;

    // -------------------------------------------------------------------------
    // MEM/WB pipeline register
    // Carries what writeback needs: either the memory read data or the ALU result.
    // -------------------------------------------------------------------------
    typedef struct packed {
        // ---- control signals ----
        logic       reg_write;
        logic       mem_to_reg;
        // ---- data ----
        logic [31:0] alu_result;  // pass-through for ALU/jump ops
        logic [31:0] mem_rdata;   // data read from DMEM (load result)
        // ---- destination ----
        logic [4:0]  rd_addr;
        logic        valid;
    } mem_wb_t;

endpackage