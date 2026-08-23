// tb_top.sv
// Self-checking testbench for the 5-stage RV32I core.
//
// Hand-assembles a program into IMEM via hierarchical reference, runs it, and
// compares the final register file against expected values. The program is
// built to exercise the hazard paths specifically, not just the ALU:
//
//   * EX->EX forwarding      (back-to-back dependent ALU ops)
//   * MEM->EX forwarding     (dependent two instructions apart)
//   * regfile write-through  (dependent three instructions apart)
//   * load-use stall         (lw immediately followed by a consumer)
//   * branch taken / not taken flushes
//   * JAL and JALR redirects, including a JALR whose base is forwarded
//   * x0 write suppression

`timescale 1ns/1ps

module tb_top;
    import pipeline_pkg::*;

    // -------------------------------------------------------------------------
    // clock / reset / DUT
    // -------------------------------------------------------------------------
    logic clk = 1'b0;
    logic rst = 1'b1;

    always #5 clk = ~clk;          // 100 MHz

    top dut (.clk(clk), .rst(rst));

    int errors = 0;
    int cycles = 0;

    // -------------------------------------------------------------------------
    // instruction encoders
    // -------------------------------------------------------------------------
    localparam logic [6:0] OPC_R     = 7'b0110011;
    localparam logic [6:0] OPC_I_ALU = 7'b0010011;
    localparam logic [6:0] OPC_LOAD  = 7'b0000011;
    localparam logic [6:0] OPC_STORE = 7'b0100011;
    localparam logic [6:0] OPC_BR    = 7'b1100011;
    localparam logic [6:0] OPC_LUI   = 7'b0110111;
    localparam logic [6:0] OPC_AUIPC = 7'b0010111;
    localparam logic [6:0] OPC_JAL   = 7'b1101111;
    localparam logic [6:0] OPC_JALR  = 7'b1100111;

    function automatic logic [31:0] enc_r(
        input logic [6:0] funct7, input logic [4:0] rs2, rs1,
        input logic [2:0] funct3, input logic [4:0] rd);
        return {funct7, rs2, rs1, funct3, rd, OPC_R};
    endfunction

    function automatic logic [31:0] enc_i(
        input logic [11:0] imm, input logic [4:0] rs1,
        input logic [2:0] funct3, input logic [4:0] rd,
        input logic [6:0] opcode);
        return {imm, rs1, funct3, rd, opcode};
    endfunction

    function automatic logic [31:0] enc_s(
        input logic [11:0] imm, input logic [4:0] rs2, rs1,
        input logic [2:0] funct3);
        return {imm[11:5], rs2, rs1, funct3, imm[4:0], OPC_STORE};
    endfunction

    function automatic logic [31:0] enc_b(
        input logic [12:0] imm, input logic [4:0] rs2, rs1,
        input logic [2:0] funct3);
        return {imm[12], imm[10:5], rs2, rs1, funct3, imm[4:1], imm[11], OPC_BR};
    endfunction

    function automatic logic [31:0] enc_u(
        input logic [19:0] imm20, input logic [4:0] rd, input logic [6:0] opcode);
        return {imm20, rd, opcode};
    endfunction

    function automatic logic [31:0] enc_j(
        input logic [20:0] imm, input logic [4:0] rd);
        return {imm[20], imm[10:1], imm[11], imm[19:12], rd, OPC_JAL};
    endfunction

    // -------------------------------------------------------------------------
    // program
    // -------------------------------------------------------------------------
    task automatic load_program();
        // zero-fill so unused memory never reads X
        for (int i = 0; i < 1024; i++) begin
            dut.u_fetch.imem[i]     = 32'h0000_0013;   // NOP (addi x0,x0,0)
            dut.u_mem_stage.dmem[i] = 32'h0;
        end
        for (int i = 0; i < 32; i++) dut.u_regs.regs[i] = 32'h0;

        // ---- basic ALU + forwarding distances --------------------------------
        // 0x00  addi x1, x0, 10                      x1 = 10
        dut.u_fetch.imem[0]  = enc_i(12'd10, 5'd0, 3'b000, 5'd1, OPC_I_ALU);
        // 0x04  addi x2, x1, 5      EX->EX           x2 = 15
        dut.u_fetch.imem[1]  = enc_i(12'd5, 5'd1, 3'b000, 5'd2, OPC_I_ALU);
        // 0x08  add  x3, x1, x2     x2 EX->EX, x1 MEM->EX   x3 = 25
        dut.u_fetch.imem[2]  = enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3);
        // 0x0C  sub  x4, x2, x1                      x4 = 5
        dut.u_fetch.imem[3]  = enc_r(7'b0100000, 5'd1, 5'd2, 3'b000, 5'd4);
        // 0x10  slli x5, x1, 2                       x5 = 40
        dut.u_fetch.imem[4]  = enc_i({7'b0000000, 5'd2}, 5'd1, 3'b001, 5'd5, OPC_I_ALU);
        // 0x14  srli x6, x5, 1      EX->EX           x6 = 20
        dut.u_fetch.imem[5]  = enc_i({7'b0000000, 5'd1}, 5'd5, 3'b101, 5'd6, OPC_I_ALU);
        // 0x18  srai x7, x4, 1      (funct7 bit5 set) x7 = 2
        dut.u_fetch.imem[6]  = enc_i({7'b0100000, 5'd1}, 5'd4, 3'b101, 5'd7, OPC_I_ALU);
        // 0x1C  and  x8, x1, x2                      x8 = 10
        dut.u_fetch.imem[7]  = enc_r(7'b0000000, 5'd2, 5'd1, 3'b111, 5'd8);
        // 0x20  or   x9, x1, x4                      x9 = 15
        dut.u_fetch.imem[8]  = enc_r(7'b0000000, 5'd4, 5'd1, 3'b110, 5'd9);
        // 0x24  xor  x10, x1, x2                     x10 = 5
        dut.u_fetch.imem[9]  = enc_r(7'b0000000, 5'd2, 5'd1, 3'b100, 5'd10);
        // 0x28  slt  x11, x1, x2                     x11 = 1
        dut.u_fetch.imem[10] = enc_r(7'b0000000, 5'd2, 5'd1, 3'b010, 5'd11);
        // 0x2C  sltu x12, x2, x1                     x12 = 0
        dut.u_fetch.imem[11] = enc_r(7'b0000000, 5'd1, 5'd2, 3'b011, 5'd12);

        // ---- upper immediates -------------------------------------------------
        // 0x30  lui   x13, 0x12345                   x13 = 0x12345000
        dut.u_fetch.imem[12] = enc_u(20'h12345, 5'd13, OPC_LUI);
        // 0x34  auipc x14, 0                         x14 = 0x34
        dut.u_fetch.imem[13] = enc_u(20'h0, 5'd14, OPC_AUIPC);

        // ---- memory + load-use stall ------------------------------------------
        // 0x38  sw   x2, 0(x0)                       mem[0] = 15
        dut.u_fetch.imem[14] = enc_s(12'd0, 5'd2, 5'd0, 3'b010);
        // 0x3C  lw   x15, 0(x0)                      x15 = 15
        dut.u_fetch.imem[15] = enc_i(12'd0, 5'd0, 3'b010, 5'd15, OPC_LOAD);
        // 0x40  addi x16, x15, 1    LOAD-USE STALL   x16 = 16
        dut.u_fetch.imem[16] = enc_i(12'd1, 5'd15, 3'b000, 5'd16, OPC_I_ALU);

        // ---- sub-word access ---------------------------------------------------
        // 0x44  sb   x1, 4(x0)                       mem[4] byte0 = 10
        dut.u_fetch.imem[17] = enc_s(12'd4, 5'd1, 5'd0, 3'b000);
        // 0x48  lbu  x17, 4(x0)                      x17 = 10
        dut.u_fetch.imem[18] = enc_i(12'd4, 5'd0, 3'b100, 5'd17, OPC_LOAD);
        // 0x4C  lb   x18, 4(x0)                      x18 = 10
        dut.u_fetch.imem[19] = enc_i(12'd4, 5'd0, 3'b000, 5'd18, OPC_LOAD);

        // ---- branches ----------------------------------------------------------
        // 0x50  beq  x1, x1, +8     TAKEN, skips 0x54
        dut.u_fetch.imem[20] = enc_b(13'd8, 5'd1, 5'd1, 3'b000);
        // 0x54  addi x19, x0, 99    MUST BE FLUSHED  x19 stays 0
        dut.u_fetch.imem[21] = enc_i(12'd99, 5'd0, 3'b000, 5'd19, OPC_I_ALU);
        // 0x58  addi x20, x0, 7                      x20 = 7
        dut.u_fetch.imem[22] = enc_i(12'd7, 5'd0, 3'b000, 5'd20, OPC_I_ALU);
        // 0x5C  bne  x1, x1, +8     NOT taken
        dut.u_fetch.imem[23] = enc_b(13'd8, 5'd1, 5'd1, 3'b001);
        // 0x60  addi x21, x0, 8                      x21 = 8
        dut.u_fetch.imem[24] = enc_i(12'd8, 5'd0, 3'b000, 5'd21, OPC_I_ALU);

        // ---- jumps -------------------------------------------------------------
        // 0x64  jal  x22, +8                         x22 = 0x68, go to 0x6C
        dut.u_fetch.imem[25] = enc_j(21'd8, 5'd22);
        // 0x68  addi x23, x0, 99    MUST BE FLUSHED  x23 stays 0
        dut.u_fetch.imem[26] = enc_i(12'd99, 5'd0, 3'b000, 5'd23, OPC_I_ALU);
        // 0x6C  addi x24, x0, 3                      x24 = 3
        dut.u_fetch.imem[27] = enc_i(12'd3, 5'd0, 3'b000, 5'd24, OPC_I_ALU);
        // 0x70  addi x25, x0, 0x7C                   x25 = 0x7C
        dut.u_fetch.imem[28] = enc_i(12'h07C, 5'd0, 3'b000, 5'd25, OPC_I_ALU);
        // 0x74  jalr x26, 0(x25)    base is FORWARDED from the previous instr
        //                                            x26 = 0x78, go to 0x7C
        dut.u_fetch.imem[29] = enc_i(12'd0, 5'd25, 3'b000, 5'd26, OPC_JALR);
        // 0x78  addi x27, x0, 99    MUST BE FLUSHED  x27 stays 0
        dut.u_fetch.imem[30] = enc_i(12'd99, 5'd0, 3'b000, 5'd27, OPC_I_ALU);
        // 0x7C  addi x28, x0, 5                      x28 = 5
        dut.u_fetch.imem[31] = enc_i(12'd5, 5'd0, 3'b000, 5'd28, OPC_I_ALU);

        // ---- x0 handling --------------------------------------------------------
        // 0x80  addi x0, x0, 99     write to x0 must be suppressed
        dut.u_fetch.imem[32] = enc_i(12'd99, 5'd0, 3'b000, 5'd0, OPC_I_ALU);
        // 0x84  add  x29, x0, x0                     x29 = 0
        dut.u_fetch.imem[33] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd29);

        // 0x88  beq x0, x0, 0       halt (branch to self)
        dut.u_fetch.imem[34] = enc_b(13'd0, 5'd0, 5'd0, 3'b000);
    endtask

    // -------------------------------------------------------------------------
    // checking
    // -------------------------------------------------------------------------
    task automatic check_reg(input string label, input int idx, input logic [31:0] exp);
        logic [31:0] got;
        got = dut.u_regs.regs[idx];
        if (got !== exp) begin
            $display("  FAIL  x%0d %-28s got 0x%08x  expected 0x%08x", idx, label, got, exp);
            errors++;
        end else begin
            $display("  pass  x%0d %-28s 0x%08x", idx, label, got);
        end
    endtask

    // X-propagation watchdog: a write into the regfile must never be unknown
    always @(posedge clk) begin
        if (!rst && dut.wb_we && (^dut.wb_wdata === 1'bx)) begin
            $display("  FAIL  cycle %0d: regfile write of X to x%0d", cycles, dut.wb_rd_addr);
            errors++;
        end
    end

    // -------------------------------------------------------------------------
    // main
    // -------------------------------------------------------------------------
    initial begin
        load_program();

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // run long enough for 35 instructions + stalls + flushes + drain
        repeat (300) begin
            @(posedge clk);
            cycles++;
        end

        $display("");
        $display("==== register file after %0d cycles ====", cycles);

        check_reg("addi x0,10",            1,  32'd10);
        check_reg("addi EX->EX",           2,  32'd15);
        check_reg("add  two fwd sources",  3,  32'd25);
        check_reg("sub",                   4,  32'd5);
        check_reg("slli",                  5,  32'd40);
        check_reg("srli EX->EX",           6,  32'd20);
        check_reg("srai (funct7 bit)",     7,  32'd2);
        check_reg("and",                   8,  32'd10);
        check_reg("or",                    9,  32'd15);
        check_reg("xor",                   10, 32'd5);
        check_reg("slt",                   11, 32'd1);
        check_reg("sltu",                  12, 32'd0);
        check_reg("lui",                   13, 32'h1234_5000);
        check_reg("auipc",                 14, 32'h0000_0034);
        check_reg("lw after sw",           15, 32'd15);
        check_reg("LOAD-USE STALL",        16, 32'd16);
        check_reg("lbu after sb",          17, 32'd10);
        check_reg("lb  after sb",          18, 32'd10);
        check_reg("beq taken -> flushed",  19, 32'd0);
        check_reg("after taken branch",    20, 32'd7);
        check_reg("bne not taken",         21, 32'd8);
        check_reg("jal link addr",         22, 32'h0000_0068);
        check_reg("jal -> flushed",        23, 32'd0);
        check_reg("jal target",            24, 32'd3);
        check_reg("jalr base",             25, 32'h0000_007C);
        check_reg("jalr link addr",        26, 32'h0000_0078);
        check_reg("jalr -> flushed",       27, 32'd0);
        check_reg("jalr target",           28, 32'd5);
        check_reg("add x29,x0,x0",         29, 32'd0);
        check_reg("x0 write suppressed",   0,  32'd0);

        $display("");
        if (errors == 0) $display("==== ALL CHECKS PASSED ====");
        else             $display("==== %0d FAILURE(S) ====", errors);
        $display("");

        $finish;
    end

endmodule
