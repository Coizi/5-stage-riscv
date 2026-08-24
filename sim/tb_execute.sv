// tb_execute.sv
// Constrained-random unit testbench for the EX stage.
//
// Drives a randomised ID/EX bundle together with randomised forwarding selects
// and bypass data, and checks the four things EX owns: forwarded operand
// selection, ALU result, branch decision, and redirect target.
//
// The forwarding selects are randomised INDEPENDENTLY of the register
// addresses. That is deliberate: this block does not decide whether to forward,
// it only obeys, so the unit test should cover every select value against every
// operand-source combination.

`timescale 1ns/1ps

module tb_execute;
    import pipeline_pkg::*;

    localparam int N_TXN = 6000;

    logic        clk = 1'b0;
    logic        rst;
    id_ex_t      id_ex;
    fwd_sel_t    fwd_a, fwd_b;
    logic [31:0] ex_fwd, wb_fwd;
    logic        branch_taken;
    logic [31:0] branch_target;
    ex_mem_t     ex_mem;

    always #5 clk = ~clk;

    execute dut (
        .clk (clk), .rst (rst), .id_ex_reg (id_ex),
        .fwd_a (fwd_a), .fwd_b (fwd_b),
        .ex_mem_fwd_data (ex_fwd), .wb_fwd_data (wb_fwd),
        .branch_taken (branch_taken), .branch_target (branch_target),
        .ex_mem_reg (ex_mem)
    );

    int errors = 0, checks = 0;
    int n_taken = 0, n_not_taken = 0, n_jalr = 0, n_fwd_used = 0;

    class ex_txn;
        rand bit [3:0]  alu_op;
        rand bit [1:0]  srca, srcb, sel_a, sel_b;
        rand bit [31:0] rs1_data, rs2_data, imm, pc, exd, wbd;
        rand bit [4:0]  rs1_addr, rs2_addr, rd_addr;
        rand bit [2:0]  funct3;
        rand bit        branch, jump, jalr, valid, mem_read, mem_write, reg_write, mem_to_reg;
        rand int        kind;   // 0 = plain ALU, 1 = branch, 2 = JAL, 3 = JALR

        constraint c_enum {
            alu_op inside {[0:10]};
            srca   inside {0, 1};          // SRCA_RS1 / SRCA_PC
            srcb   inside {0, 1, 2};       // RS2 / IMM / FOUR
            sel_a  inside {0, 1, 2};       // FWD_NONE / FWD_EX / FWD_WB
            sel_b  inside {0, 1, 2};
        }
        // A single distributed "kind" maps deterministically onto the control
        // bits. Putting separate dist weights on branch/jump and relying on
        // implication constraints to keep them consistent lets the solver
        // collapse onto one corner -- this form does not.
        constraint c_kind { kind dist { 0 := 30, 1 := 40, 2 := 15, 3 := 15 }; }
        constraint c_ctrl {
            branch == (kind == 1);
            jump   == (kind inside {2, 3});
            jalr   == (kind == 3);
            !(mem_read && mem_write);
            valid  dist { 1'b1 := 85, 1'b0 := 15 };
            branch -> funct3 inside {3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111};
        }
        // operands that make signed/unsigned comparisons disagree
        constraint c_data {
            rs1_data dist { 32'h0 := 8, 32'h1 := 8, 32'hFFFF_FFFF := 8,
                            32'h8000_0000 := 8, [32'h2 : 32'hFFFF_FFFE] :/ 68 };
            rs2_data dist { 32'h0 := 8, 32'h1 := 8, 32'hFFFF_FFFF := 8,
                            32'h8000_0000 := 8, [32'h2 : 32'hFFFF_FFFE] :/ 68 };
            exd      dist { 32'h0 := 8, 32'h1 := 8, 32'hFFFF_FFFF := 8,
                            [32'h2 : 32'hFFFF_FFFE] :/ 76 };
        }
        constraint c_pc { pc[1:0] == 2'b00; }
    endclass

    function automatic logic [31:0] ref_alu(
        input logic [31:0] ia, ib, input logic [3:0] iop);
        logic signed [31:0] sa = ia;
        logic signed [31:0] sb = ib;
        logic        [4:0]  sh = ib[4:0];
        case (iop)
            4'd0:    return ia + ib;
            4'd1:    return ia - ib;
            4'd2:    return ia & ib;
            4'd3:    return ia | ib;
            4'd4:    return ia ^ ib;
            4'd5:    return ia <<  sh;
            4'd6:    return ia >>  sh;
            4'd7:    return sa >>> sh;
            4'd8:    return (sa < sb) ? 32'd1 : 32'd0;
            4'd9:    return (ia < ib) ? 32'd1 : 32'd0;
            4'd10:   return ib;
            default: return 32'd0;
        endcase
    endfunction

    task automatic check_val(input string name, input logic [31:0] got, exp, input int iter);
        checks++;
        if (got !== exp) begin
            $display("  FAIL  iter %0d  %-14s got 0x%08x, expected 0x%08x", iter, name, got, exp);
            errors++;
        end
    endtask

    initial begin
        ex_txn t = new();
        logic [31:0] r1f, r2f, aa, ab, res, base, sum, tgt;
        bit cond_raw, cond, exp_bt;

        $display("");
        $display("======== tb_execute: %0d constrained-random transactions ========", N_TXN);

        rst   = 1'b1;
        id_ex = '0;
        fwd_a = FWD_NONE;
        fwd_b = FWD_NONE;
        repeat (3) @(posedge clk);
        rst = 1'b0;

        for (int i = 0; i < N_TXN; i++) begin
            @(negedge clk);
            if (!t.randomize()) begin
                $display("  FAIL  randomize() failed"); errors++; break;
            end

            id_ex.alu_op     = alu_op_t'(t.alu_op);
            id_ex.alu_srca   = alu_srca_t'(t.srca);
            id_ex.alu_srcb   = alu_srcb_t'(t.srcb);
            id_ex.rs1_data   = t.rs1_data;
            id_ex.rs2_data   = t.rs2_data;
            id_ex.imm        = t.imm;
            id_ex.pc         = t.pc;
            id_ex.rs1_addr   = t.rs1_addr;
            id_ex.rs2_addr   = t.rs2_addr;
            id_ex.rd_addr    = t.rd_addr;
            id_ex.mem_funct3 = t.funct3;
            id_ex.branch     = t.branch;
            id_ex.jump       = t.jump;
            id_ex.jalr       = t.jalr;
            id_ex.valid      = t.valid;
            id_ex.mem_read   = t.mem_read;
            id_ex.mem_write  = t.mem_write;
            id_ex.reg_write  = t.reg_write;
            id_ex.mem_to_reg = t.mem_to_reg;
            fwd_a  = fwd_sel_t'(t.sel_a);
            fwd_b  = fwd_sel_t'(t.sel_b);
            ex_fwd = t.exd;
            wb_fwd = t.wbd;
            #1;

            // ---- reference model ----
            r1f = (t.sel_a == 1) ? t.exd : (t.sel_a == 2) ? t.wbd : t.rs1_data;
            r2f = (t.sel_b == 1) ? t.exd : (t.sel_b == 2) ? t.wbd : t.rs2_data;
            aa  = (t.srca == 1) ? t.pc : r1f;
            ab  = (t.srcb == 1) ? t.imm : (t.srcb == 2) ? 32'd4 : r2f;
            res = ref_alu(aa, ab, t.alu_op);

            cond_raw = (t.funct3[2:1] == 2'b00) ? (res == 32'd0) : res[0];
            cond     = cond_raw ^ t.funct3[0];
            exp_bt   = t.valid && ((t.branch && cond) || t.jump);

            base = t.jalr ? r1f : t.pc;
            sum  = base + t.imm;
            tgt  = {sum[31:1], 1'b0};

            if (t.sel_a != 0 || t.sel_b != 0) n_fwd_used++;
            if (exp_bt) n_taken++; else n_not_taken++;
            if (t.jalr) n_jalr++;

            check_val("branch_target", branch_target, tgt, i);
            checks++;
            if (branch_taken !== exp_bt) begin
                $display("  FAIL  iter %0d  branch_taken got %0b, expected %0b (br=%0b jmp=%0b f3=%03b res=0x%08x)",
                         i, branch_taken, exp_bt, t.branch, t.jump, t.funct3, res);
                errors++;
            end

            @(posedge clk);
            #1;
            check_val("alu_result", ex_mem.alu_result, res, i);
            check_val("rs2 fwd store", ex_mem.rs2_data, r2f, i);
            checks++;
            if (ex_mem.reg_write !== (t.reg_write && t.valid)) begin
                $display("  FAIL  iter %0d  ex_mem.reg_write got %0b, expected %0b",
                         i, ex_mem.reg_write, (t.reg_write && t.valid));
                errors++;
            end
        end

        checks++;
        if (n_taken < 500) begin $display("  FAIL  only %0d taken redirects", n_taken); errors++; end
        checks++;
        if (n_jalr  < 200) begin $display("  FAIL  only %0d JALR cases", n_jalr); errors++; end

        $display("  coverage: %0d redirects taken, %0d not taken, %0d JALR, %0d with forwarding active",
                 n_taken, n_not_taken, n_jalr, n_fwd_used);
        if (errors == 0) $display("  tb_execute: %0d checks PASSED", checks);
        else             $display("  tb_execute: %0d of %0d checks FAILED", errors, checks);

        $finish;
    end

endmodule
