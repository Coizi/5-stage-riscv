// tb_forward_unit.sv
// Constrained-random unit testbench for the forwarding unit.
//
// The whole point of this block is PRIORITY, so addresses are squeezed into a
// tiny range to make the "EX/MEM and MEM/WB both match the same source" case
// common. Uniform random over 32 registers would hit that case roughly 0.1% of
// the time; here it is checked thousands of times.

`timescale 1ns/1ps

module tb_forward_unit;
    import pipeline_pkg::*;

    localparam int N_TXN = 5000;

    id_ex_t   id_ex;
    ex_mem_t  ex_mem;
    mem_wb_t  mem_wb;
    fwd_sel_t fwd_a, fwd_b;

    forward_unit dut (
        .id_ex_reg (id_ex), .ex_mem_reg (ex_mem), .mem_wb_reg (mem_wb),
        .fwd_a (fwd_a),     .fwd_b (fwd_b)
    );

    int errors = 0, checks = 0;
    int n_both_a = 0, n_ex_a = 0, n_wb_a = 0, n_none_a = 0;

    class fwd_txn;
        rand bit [4:0] rs1, rs2, ex_rd, wb_rd;
        rand bit       ex_we, wb_we;
        rand bit       want_conflict;   // steer toward the case that matters

        constraint c_addr {
            rs1   dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
            rs2   dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
            ex_rd dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
            wb_rd dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
        }
        constraint c_we {
            ex_we dist { 1'b1 := 70, 1'b0 := 30 };
            wb_we dist { 1'b1 := 70, 1'b0 := 30 };
        }
        // ~35% of transactions are steered so that BOTH pipeline registers write
        // the register rs1 reads -- otherwise the priority rule is barely tested
        constraint c_conflict {
            want_conflict dist { 1'b1 := 35, 1'b0 := 65 };
            want_conflict -> (ex_rd == wb_rd) && (ex_rd == rs1) && (ex_rd != 5'd0)
                             && ex_we && wb_we;
        }
    endclass

    // reference: EX/MEM holds the younger instruction, so it outranks MEM/WB
    function automatic fwd_sel_t ref_fwd(input logic [4:0] src);
        if (ex_mem.reg_write && (ex_mem.rd_addr != 5'd0) && (ex_mem.rd_addr == src))
            return FWD_EX;
        else if (mem_wb.reg_write && (mem_wb.rd_addr != 5'd0) && (mem_wb.rd_addr == src))
            return FWD_WB;
        else
            return FWD_NONE;
    endfunction

    initial begin
        fwd_txn t = new();
        fwd_sel_t exp_a, exp_b;
        bit ex_match, wb_match;

        $display("");
        $display("======== tb_forward_unit: %0d constrained-random transactions ========", N_TXN);

        id_ex  = '0;
        ex_mem = '0;
        mem_wb = '0;

        for (int i = 0; i < N_TXN; i++) begin
            if (!t.randomize()) begin
                $display("  FAIL  randomize() failed"); errors++; break;
            end
            id_ex.rs1_addr   = t.rs1;
            id_ex.rs2_addr   = t.rs2;
            ex_mem.rd_addr   = t.ex_rd;
            ex_mem.reg_write = t.ex_we;
            mem_wb.rd_addr   = t.wb_rd;
            mem_wb.reg_write = t.wb_we;
            #1;

            exp_a = ref_fwd(t.rs1);
            exp_b = ref_fwd(t.rs2);

            // coverage bookkeeping on the A port
            ex_match = t.ex_we && (t.ex_rd != 0) && (t.ex_rd == t.rs1);
            wb_match = t.wb_we && (t.wb_rd != 0) && (t.wb_rd == t.rs1);
            if (ex_match && wb_match) n_both_a++;
            case (exp_a)
                FWD_EX:   n_ex_a++;
                FWD_WB:   n_wb_a++;
                default:  n_none_a++;
            endcase

            checks++;
            if (fwd_a !== exp_a) begin
                $display("  FAIL  fwd_a: rs1=%0d ex(we=%0b rd=%0d) wb(we=%0b rd=%0d) -> %s, expected %s",
                         t.rs1, t.ex_we, t.ex_rd, t.wb_we, t.wb_rd, fwd_a.name(), exp_a.name());
                errors++;
            end
            checks++;
            if (fwd_b !== exp_b) begin
                $display("  FAIL  fwd_b: rs2=%0d ex(we=%0b rd=%0d) wb(we=%0b rd=%0d) -> %s, expected %s",
                         t.rs2, t.ex_we, t.ex_rd, t.wb_we, t.wb_rd, fwd_b.name(), exp_b.name());
                errors++;
            end
        end

        // the priority conflict must have been exercised heavily
        checks++;
        if (n_both_a < 200) begin
            $display("  FAIL  only %0d EX/WB priority conflicts on port A", n_both_a);
            errors++;
        end

        $display("  coverage port A: %0d FWD_EX, %0d FWD_WB, %0d FWD_NONE, %0d priority conflicts",
                 n_ex_a, n_wb_a, n_none_a, n_both_a);
        if (errors == 0) $display("  tb_forward_unit: %0d checks PASSED", checks);
        else             $display("  tb_forward_unit: %0d of %0d checks FAILED", errors, checks);

        $finish;
    end

endmodule
