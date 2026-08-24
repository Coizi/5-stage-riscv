// tb_top.sv
// Self-checking testbench for the 5-stage RV32I core.
//
// Three programs are hand-assembled into IMEM via hierarchical reference and
// run back to back with a reset between them:
//
//   TEST 1  hazards    -- EX->EX / MEM->EX forwarding, regfile write-through,
//                         load-use stall, branch + JAL + JALR flushes, x0 writes
//   TEST 2  branches   -- all six compare types, with operands chosen so that
//                         signed and unsigned disagree (this is what catches a
//                         swapped SLT/SLTU or a wrong funct3[0] invert bit)
//   TEST 3  sub-word   -- SB/SH/SW into every byte and halfword lane, LB/LBU/
//                         LH/LHU back out, plus a load feeding a store's data

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

    int errors  = 0;
    int checks  = 0;
    bit watch_x = 1'b0;

    localparam logic [31:0] NOP = 32'h0000_0013;   // addi x0, x0, 0

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
    // infrastructure
    // -------------------------------------------------------------------------
    task automatic clear_state();
        watch_x = 1'b0;
        rst     = 1'b1;
        repeat (6) @(posedge clk);
        for (int i = 0; i < 1024; i++) begin
            dut.u_fetch.imem[i]     = NOP;
            dut.u_mem_stage.dmem[i] = 32'h0;
        end
        for (int i = 0; i < 32; i++) dut.u_regs.regs[i] = 32'h0;
    endtask

    task automatic run(input int n);
        @(negedge clk);
        rst     = 1'b0;
        watch_x = 1'b1;
        repeat (n) @(posedge clk);
        watch_x = 1'b0;
    endtask

    task automatic check_reg(input string label, input int idx, input logic [31:0] exp);
        logic [31:0] got;
        got = dut.u_regs.regs[idx];
        checks++;
        if (got !== exp) begin
            $display("  FAIL  x%-2d %-26s got 0x%08x  expected 0x%08x", idx, label, got, exp);
            errors++;
        end else begin
            $display("  pass  x%-2d %-26s 0x%08x", idx, label, got);
        end
    endtask

    // X-propagation watchdog: a register file write must never be unknown
    always @(posedge clk) begin
        if (watch_x && dut.wb_we && (^dut.wb_wdata === 1'bx)) begin
            $display("  FAIL  regfile write of X to x%0d", dut.wb_rd_addr);
            errors++;
        end
    end

    // -------------------------------------------------------------------------
    // pipeline penalty measurement
    // Rather than asserting the flush cost from the design intent, count it:
    // how many cycles does EX sit empty after a redirect, and how many
    // consecutive cycles is the front end held for a load-use hazard.
    // -------------------------------------------------------------------------
    bit measure_en     = 1'b0;
    int branch_penalty = -1;
    int stall_length   = -1;
    bit counting_flush = 1'b0;
    bit counting_stall = 1'b0;
    int bub_cnt        = 0;
    int st_cnt         = 0;

    always @(posedge clk) begin
        if (measure_en) begin
            if (dut.branch_taken && !counting_flush) begin
                counting_flush <= 1'b1;
                bub_cnt        <= 0;
            end else if (counting_flush) begin
                if (dut.id_ex_reg.valid) begin
                    counting_flush <= 1'b0;
                    if (branch_penalty < 0) branch_penalty <= bub_cnt;
                end else begin
                    bub_cnt <= bub_cnt + 1;
                end
            end

            if (dut.stall_if && !counting_stall) begin
                counting_stall <= 1'b1;
                st_cnt         <= 1;
            end else if (counting_stall) begin
                if (dut.stall_if) begin
                    st_cnt <= st_cnt + 1;
                end else begin
                    counting_stall <= 1'b0;
                    if (stall_length < 0) stall_length <= st_cnt;
                end
            end
        end
    end

    // =========================================================================
    // TEST 1 -- hazards, forwarding, control flow
    // =========================================================================
    task automatic test1_hazards();
        $display("");
        $display("======== TEST 1: forwarding / stalls / control flow ========");

        clear_state();

        // 0x00  addi x1, x0, 10                      x1 = 10
        dut.u_fetch.imem[0]  = enc_i(12'd10, 5'd0, 3'b000, 5'd1, OPC_I_ALU);
        // 0x04  addi x2, x1, 5      EX->EX           x2 = 15
        dut.u_fetch.imem[1]  = enc_i(12'd5, 5'd1, 3'b000, 5'd2, OPC_I_ALU);
        // 0x08  add  x3, x1, x2     x2 EX->EX, x1 MEM->EX      x3 = 25
        dut.u_fetch.imem[2]  = enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3);
        // 0x0C  sub  x4, x2, x1                      x4 = 5
        dut.u_fetch.imem[3]  = enc_r(7'b0100000, 5'd1, 5'd2, 3'b000, 5'd4);
        // 0x10  slli x5, x1, 2                       x5 = 40
        dut.u_fetch.imem[4]  = enc_i({7'b0000000, 5'd2}, 5'd1, 3'b001, 5'd5, OPC_I_ALU);
        // 0x14  srli x6, x5, 1      EX->EX           x6 = 20
        dut.u_fetch.imem[5]  = enc_i({7'b0000000, 5'd1}, 5'd5, 3'b101, 5'd6, OPC_I_ALU);
        // 0x18  srai x7, x4, 1                       x7 = 2
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
        // 0x30  lui   x13, 0x12345                   x13 = 0x12345000
        dut.u_fetch.imem[12] = enc_u(20'h12345, 5'd13, OPC_LUI);
        // 0x34  auipc x14, 0                         x14 = 0x34
        dut.u_fetch.imem[13] = enc_u(20'h0, 5'd14, OPC_AUIPC);
        // 0x38  sw   x2, 0(x0)                       mem[0] = 15
        dut.u_fetch.imem[14] = enc_s(12'd0, 5'd2, 5'd0, 3'b010);
        // 0x3C  lw   x15, 0(x0)                      x15 = 15
        dut.u_fetch.imem[15] = enc_i(12'd0, 5'd0, 3'b010, 5'd15, OPC_LOAD);
        // 0x40  addi x16, x15, 1    LOAD-USE STALL   x16 = 16
        dut.u_fetch.imem[16] = enc_i(12'd1, 5'd15, 3'b000, 5'd16, OPC_I_ALU);
        // 0x44  sb   x1, 4(x0)                       mem[4] byte0 = 10
        dut.u_fetch.imem[17] = enc_s(12'd4, 5'd1, 5'd0, 3'b000);
        // 0x48  lbu  x17, 4(x0)                      x17 = 10
        dut.u_fetch.imem[18] = enc_i(12'd4, 5'd0, 3'b100, 5'd17, OPC_LOAD);
        // 0x4C  lb   x18, 4(x0)                      x18 = 10
        dut.u_fetch.imem[19] = enc_i(12'd4, 5'd0, 3'b000, 5'd18, OPC_LOAD);
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
        // 0x64  jal  x22, +8                         x22 = 0x68, go to 0x6C
        dut.u_fetch.imem[25] = enc_j(21'd8, 5'd22);
        // 0x68  addi x23, x0, 99    MUST BE FLUSHED  x23 stays 0
        dut.u_fetch.imem[26] = enc_i(12'd99, 5'd0, 3'b000, 5'd23, OPC_I_ALU);
        // 0x6C  addi x24, x0, 3                      x24 = 3
        dut.u_fetch.imem[27] = enc_i(12'd3, 5'd0, 3'b000, 5'd24, OPC_I_ALU);
        // 0x70  addi x25, x0, 0x7C                   x25 = 0x7C
        dut.u_fetch.imem[28] = enc_i(12'h07C, 5'd0, 3'b000, 5'd25, OPC_I_ALU);
        // 0x74  jalr x26, 0(x25)    base FORWARDED from previous instruction
        dut.u_fetch.imem[29] = enc_i(12'd0, 5'd25, 3'b000, 5'd26, OPC_JALR);
        // 0x78  addi x27, x0, 99    MUST BE FLUSHED  x27 stays 0
        dut.u_fetch.imem[30] = enc_i(12'd99, 5'd0, 3'b000, 5'd27, OPC_I_ALU);
        // 0x7C  addi x28, x0, 5                      x28 = 5
        dut.u_fetch.imem[31] = enc_i(12'd5, 5'd0, 3'b000, 5'd28, OPC_I_ALU);
        // 0x80  addi x0, x0, 99     write to x0 must be suppressed
        dut.u_fetch.imem[32] = enc_i(12'd99, 5'd0, 3'b000, 5'd0, OPC_I_ALU);
        // 0x84  add  x29, x0, x0                     x29 = 0
        dut.u_fetch.imem[33] = enc_r(7'b0000000, 5'd0, 5'd0, 3'b000, 5'd29);
        // 0x88  beq x0, x0, 0       halt
        dut.u_fetch.imem[34] = enc_b(13'd0, 5'd0, 5'd0, 3'b000);

        run(200);

        check_reg("addi x0,10",            1,  32'd10);
        check_reg("addi EX->EX",           2,  32'd15);
        check_reg("add two fwd sources",   3,  32'd25);
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
        check_reg("lb after sb",           18, 32'd10);
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
        check_reg("x0 never written",      0,  32'd0);
    endtask

    // =========================================================================
    // TEST 2 -- all six branch comparisons
    //
    // Operands are -1 and 1. Signed and unsigned DISAGREE on every comparison
    // between them, so a swapped SLT/SLTU shows up immediately:
    //     signed:    -1 <  1          unsigned:  0xFFFFFFFF >  1
    // Marker convention: register stays 0 if the branch was TAKEN (the setter
    // was skipped), and becomes 1 if it was NOT taken.
    // =========================================================================
    task automatic test2_branches();
        $display("");
        $display("======== TEST 2: branch comparisons (signed vs unsigned) ========");

        clear_state();

        // 0x00  addi x1, x0, -1      x1 = 0xFFFFFFFF   (also tests sign extension)
        dut.u_fetch.imem[0]  = enc_i(-12'sd1, 5'd0, 3'b000, 5'd1, OPC_I_ALU);
        // 0x04  addi x2, x0, 1       x2 = 1
        dut.u_fetch.imem[1]  = enc_i(12'd1, 5'd0, 3'b000, 5'd2, OPC_I_ALU);
        // 0x08  addi x3, x0, -1      x3 = 0xFFFFFFFF   (equal to x1)
        dut.u_fetch.imem[2]  = enc_i(-12'sd1, 5'd0, 3'b000, 5'd3, OPC_I_ALU);

        // blt  x1, x2   -1 <  1 signed      -> TAKEN
        dut.u_fetch.imem[3]  = enc_b(13'd8, 5'd2, 5'd1, 3'b100);
        dut.u_fetch.imem[4]  = enc_i(12'd1, 5'd0, 3'b000, 5'd10, OPC_I_ALU);
        // bltu x1, x2   0xFFFFFFFF < 1 unsigned -> NOT taken
        dut.u_fetch.imem[5]  = enc_b(13'd8, 5'd2, 5'd1, 3'b110);
        dut.u_fetch.imem[6]  = enc_i(12'd1, 5'd0, 3'b000, 5'd11, OPC_I_ALU);
        // bge  x2, x1   1 >= -1 signed      -> TAKEN
        dut.u_fetch.imem[7]  = enc_b(13'd8, 5'd1, 5'd2, 3'b101);
        dut.u_fetch.imem[8]  = enc_i(12'd1, 5'd0, 3'b000, 5'd12, OPC_I_ALU);
        // bgeu x2, x1   1 >= 0xFFFFFFFF unsigned -> NOT taken
        dut.u_fetch.imem[9]  = enc_b(13'd8, 5'd1, 5'd2, 3'b111);
        dut.u_fetch.imem[10] = enc_i(12'd1, 5'd0, 3'b000, 5'd13, OPC_I_ALU);
        // beq  x1, x3   equal               -> TAKEN
        dut.u_fetch.imem[11] = enc_b(13'd8, 5'd3, 5'd1, 3'b000);
        dut.u_fetch.imem[12] = enc_i(12'd1, 5'd0, 3'b000, 5'd14, OPC_I_ALU);
        // bne  x1, x3   equal               -> NOT taken
        dut.u_fetch.imem[13] = enc_b(13'd8, 5'd3, 5'd1, 3'b001);
        dut.u_fetch.imem[14] = enc_i(12'd1, 5'd0, 3'b000, 5'd15, OPC_I_ALU);
        // blt  x2, x1   1 < -1 signed       -> NOT taken
        dut.u_fetch.imem[15] = enc_b(13'd8, 5'd1, 5'd2, 3'b100);
        dut.u_fetch.imem[16] = enc_i(12'd1, 5'd0, 3'b000, 5'd16, OPC_I_ALU);
        // bgeu x1, x2   0xFFFFFFFF >= 1 unsigned -> TAKEN
        dut.u_fetch.imem[17] = enc_b(13'd8, 5'd2, 5'd1, 3'b111);
        dut.u_fetch.imem[18] = enc_i(12'd1, 5'd0, 3'b000, 5'd17, OPC_I_ALU);
        // halt
        dut.u_fetch.imem[19] = enc_b(13'd0, 5'd0, 5'd0, 3'b000);

        run(150);

        check_reg("addi -1 sign extend",   1,  32'hFFFF_FFFF);
        check_reg("addi +1",               2,  32'd1);
        check_reg("blt  -1<1  TAKEN",      10, 32'd0);
        check_reg("bltu 0xFF..<1 not tkn", 11, 32'd1);
        check_reg("bge  1>=-1 TAKEN",      12, 32'd0);
        check_reg("bgeu 1>=0xFF.. not tkn",13, 32'd1);
        check_reg("beq  equal TAKEN",      14, 32'd0);
        check_reg("bne  equal not taken",  15, 32'd1);
        check_reg("blt  1<-1 not taken",   16, 32'd1);
        check_reg("bgeu 0xFF..>=1 TAKEN",  17, 32'd0);
    endtask

    // =========================================================================
    // TEST 3 -- sub-word loads and stores in every lane
    // =========================================================================
    task automatic test3_subword();
        $display("");
        $display("======== TEST 3: sub-word memory access ========");

        clear_state();

        // 0x00  addi x1, x0, 0x7F        x1 = 127  (positive byte)
        dut.u_fetch.imem[0]  = enc_i(12'h07F, 5'd0, 3'b000, 5'd1, OPC_I_ALU);
        // 0x04  addi x2, x0, -1          x2 = 0xFFFFFFFF (negative byte)
        dut.u_fetch.imem[1]  = enc_i(-12'sd1, 5'd0, 3'b000, 5'd2, OPC_I_ALU);

        // build mem[0] = 0xFFFF7F7F one byte lane at a time
        dut.u_fetch.imem[2]  = enc_s(12'd0, 5'd1, 5'd0, 3'b000);   // sb x1, 0(x0)
        dut.u_fetch.imem[3]  = enc_s(12'd1, 5'd1, 5'd0, 3'b000);   // sb x1, 1(x0)
        dut.u_fetch.imem[4]  = enc_s(12'd2, 5'd2, 5'd0, 3'b000);   // sb x2, 2(x0)
        dut.u_fetch.imem[5]  = enc_s(12'd3, 5'd2, 5'd0, 3'b000);   // sb x2, 3(x0)

        dut.u_fetch.imem[6]  = enc_i(12'd0, 5'd0, 3'b010, 5'd10, OPC_LOAD); // lw  x10,0
        dut.u_fetch.imem[7]  = enc_i(12'd0, 5'd0, 3'b000, 5'd11, OPC_LOAD); // lb  x11,0
        dut.u_fetch.imem[8]  = enc_i(12'd2, 5'd0, 3'b000, 5'd12, OPC_LOAD); // lb  x12,2
        dut.u_fetch.imem[9]  = enc_i(12'd2, 5'd0, 3'b100, 5'd13, OPC_LOAD); // lbu x13,2
        dut.u_fetch.imem[10] = enc_i(12'd3, 5'd0, 3'b000, 5'd14, OPC_LOAD); // lb  x14,3
        dut.u_fetch.imem[11] = enc_i(12'd1, 5'd0, 3'b100, 5'd15, OPC_LOAD); // lbu x15,1
        dut.u_fetch.imem[12] = enc_i(12'd0, 5'd0, 3'b001, 5'd16, OPC_LOAD); // lh  x16,0
        dut.u_fetch.imem[13] = enc_i(12'd2, 5'd0, 3'b001, 5'd17, OPC_LOAD); // lh  x17,2
        dut.u_fetch.imem[14] = enc_i(12'd2, 5'd0, 3'b101, 5'd18, OPC_LOAD); // lhu x18,2
        dut.u_fetch.imem[15] = enc_i(12'd0, 5'd0, 3'b101, 5'd19, OPC_LOAD); // lhu x19,0

        // halfword stores into both halves of mem[1]
        dut.u_fetch.imem[16] = enc_i(12'h555, 5'd0, 3'b000, 5'd3, OPC_I_ALU);  // addi x3,0x555
        dut.u_fetch.imem[17] = enc_s(12'd4, 5'd3, 5'd0, 3'b001);               // sh x3, 4(x0)
        dut.u_fetch.imem[18] = enc_s(12'd6, 5'd3, 5'd0, 3'b001);               // sh x3, 6(x0)
        dut.u_fetch.imem[19] = enc_i(12'd4, 5'd0, 3'b010, 5'd20, OPC_LOAD);    // lw  x20,4
        dut.u_fetch.imem[20] = enc_i(12'd6, 5'd0, 3'b101, 5'd21, OPC_LOAD);    // lhu x21,6

        // full word round trip
        dut.u_fetch.imem[21] = enc_s(12'd8, 5'd2, 5'd0, 3'b010);               // sw  x2, 8(x0)
        dut.u_fetch.imem[22] = enc_i(12'd8, 5'd0, 3'b010, 5'd22, OPC_LOAD);    // lw  x22,8

        // load feeding a store's DATA -- load-use hazard on rs2, not rs1
        dut.u_fetch.imem[23] = enc_i(12'd8, 5'd0, 3'b010, 5'd23, OPC_LOAD);    // lw  x23,8
        dut.u_fetch.imem[24] = enc_s(12'd12, 5'd23, 5'd0, 3'b010);             // sw  x23,12
        dut.u_fetch.imem[25] = enc_i(12'd12, 5'd0, 3'b010, 5'd24, OPC_LOAD);   // lw  x24,12

        dut.u_fetch.imem[26] = enc_b(13'd0, 5'd0, 5'd0, 3'b000);               // halt

        run(200);

        check_reg("lw  assembled word",    10, 32'hFFFF_7F7F);
        check_reg("lb  lane0 +ve",         11, 32'd127);
        check_reg("lb  lane2 -ve",         12, 32'hFFFF_FFFF);
        check_reg("lbu lane2",             13, 32'd255);
        check_reg("lb  lane3 -ve",         14, 32'hFFFF_FFFF);
        check_reg("lbu lane1",             15, 32'd127);
        check_reg("lh  low half +ve",      16, 32'h0000_7F7F);
        check_reg("lh  high half -ve",     17, 32'hFFFF_FFFF);
        check_reg("lhu high half",         18, 32'h0000_FFFF);
        check_reg("lhu low half",          19, 32'h0000_7F7F);
        check_reg("sh  both halves",       20, 32'h0555_0555);
        check_reg("lhu after sh high",     21, 32'h0000_0555);
        check_reg("sw/lw round trip",      22, 32'hFFFF_FFFF);
        check_reg("lw feeding sw data",    24, 32'hFFFF_FFFF);
    endtask

    // =========================================================================
    // TEST 4 -- measure the flush and stall penalties instead of assuming them
    //
    // The program contains exactly one taken branch and exactly one load-use
    // hazard, and everything past it is NOP, so the PC simply walks forward and
    // no further redirect occurs to confuse the counters.
    // =========================================================================
    task automatic test4_penalties();
        $display("");
        $display("======== TEST 4: measured pipeline penalties ========");

        clear_state();
        measure_en     = 1'b0;
        branch_penalty = -1;
        stall_length   = -1;
        counting_flush = 1'b0;
        counting_stall = 1'b0;

        // 0x00  addi x1, x0, 1
        dut.u_fetch.imem[0] = enc_i(12'd1, 5'd0, 3'b000, 5'd1, OPC_I_ALU);
        // 0x04  addi x2, x0, 2
        dut.u_fetch.imem[1] = enc_i(12'd2, 5'd0, 3'b000, 5'd2, OPC_I_ALU);
        // 0x08  beq  x0, x0, +8    the only redirect in the program
        dut.u_fetch.imem[2] = enc_b(13'd8, 5'd0, 5'd0, 3'b000);
        // 0x0C  addi x3, x0, 99    flushed
        dut.u_fetch.imem[3] = enc_i(12'd99, 5'd0, 3'b000, 5'd3, OPC_I_ALU);
        // 0x10  addi x4, x0, 4
        dut.u_fetch.imem[4] = enc_i(12'd4, 5'd0, 3'b000, 5'd4, OPC_I_ALU);
        // 0x14  sw   x4, 0(x0)
        dut.u_fetch.imem[5] = enc_s(12'd0, 5'd4, 5'd0, 3'b010);
        // 0x18  lw   x5, 0(x0)
        dut.u_fetch.imem[6] = enc_i(12'd0, 5'd0, 3'b010, 5'd5, OPC_LOAD);
        // 0x1C  addi x6, x5, 1     the only load-use hazard in the program
        dut.u_fetch.imem[7] = enc_i(12'd1, 5'd5, 3'b000, 5'd6, OPC_I_ALU);

        measure_en = 1'b1;
        run(80);
        measure_en = 1'b0;

        check_reg("before branch",       1, 32'd1);
        check_reg("before branch",       2, 32'd2);
        check_reg("flushed by branch",   3, 32'd0);
        check_reg("after branch",        4, 32'd4);
        check_reg("load result",         5, 32'd4);
        check_reg("after load-use",      6, 32'd5);

        checks++;
        if (branch_penalty != 2) begin
            $display("  FAIL  branch flush penalty measured %0d cycles, expected 2", branch_penalty);
            errors++;
        end else begin
            $display("  pass  branch flush penalty     = %0d cycles", branch_penalty);
        end

        checks++;
        if (stall_length != 1) begin
            $display("  FAIL  load-use stall measured %0d cycles, expected 1", stall_length);
            errors++;
        end else begin
            $display("  pass  load-use stall duration  = %0d cycle", stall_length);
        end
    endtask

    // =========================================================================
    initial begin
        test1_hazards();
        test2_branches();
        test3_subword();
        test4_penalties();

        $display("");
        if (errors == 0) $display("==== ALL %0d CHECKS PASSED ====", checks);
        else             $display("==== %0d of %0d CHECKS FAILED ====", errors, checks);
        $display("");

        $finish;
    end

endmodule
