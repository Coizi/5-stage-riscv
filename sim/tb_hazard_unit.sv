// tb_hazard_unit.sv
// Constrained-random unit testbench for the hazard unit.
//
// Addresses are constrained tightly so real load-use conflicts occur often, and
// the uses_rs1/uses_rs2 bits are randomised independently of the addresses --
// that combination is what catches a hazard unit that ignores whether the
// instruction in ID actually reads the register it appears to name.

`timescale 1ns/1ps

module tb_hazard_unit;
    import pipeline_pkg::*;

    localparam int N_TXN = 5000;

    logic [4:0] id_rs1_addr, id_rs2_addr;
    logic       id_uses_rs1, id_uses_rs2;
    id_ex_t     id_ex;
    logic       branch_taken;
    logic       stall_if, bubble_id, flush_id;

    hazard_unit dut (
        .id_rs1_addr (id_rs1_addr), .id_rs2_addr (id_rs2_addr),
        .id_uses_rs1 (id_uses_rs1), .id_uses_rs2 (id_uses_rs2),
        .id_ex_reg   (id_ex),       .branch_taken (branch_taken),
        .stall_if    (stall_if),    .bubble_id (bubble_id), .flush_id (flush_id)
    );

    int errors = 0, checks = 0;
    int n_stall = 0, n_flush = 0, n_phantom = 0;

    class hz_txn;
        rand bit [4:0] rs1, rs2, ex_rd;
        rand bit       u1, u2, mem_read, valid, btaken;

        constraint c_addr {
            rs1   dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
            rs2   dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
            ex_rd dist { 5'd0 := 15, [5'd1:5'd3] :/ 85 };
        }
        constraint c_ctrl {
            mem_read dist { 1'b1 := 60, 1'b0 := 40 };
            valid    dist { 1'b1 := 85, 1'b0 := 15 };
            u1       dist { 1'b1 := 65, 1'b0 := 35 };
            u2       dist { 1'b1 := 50, 1'b0 := 50 };
            btaken   dist { 1'b1 := 20, 1'b0 := 80 };
        }
    endclass

    initial begin
        hz_txn t = new();
        bit exp_load_use, exp_conflict;

        $display("");
        $display("======== tb_hazard_unit: %0d constrained-random transactions ========", N_TXN);

        id_ex = '0;

        for (int i = 0; i < N_TXN; i++) begin
            if (!t.randomize()) begin
                $display("  FAIL  randomize() failed"); errors++; break;
            end
            id_rs1_addr    = t.rs1;
            id_rs2_addr    = t.rs2;
            id_uses_rs1    = t.u1;
            id_uses_rs2    = t.u2;
            id_ex.rd_addr  = t.ex_rd;
            id_ex.mem_read = t.mem_read;
            id_ex.valid    = t.valid;
            branch_taken   = t.btaken;
            #1;

            exp_conflict = (t.u1 && (t.ex_rd == t.rs1)) || (t.u2 && (t.ex_rd == t.rs2));
            exp_load_use = t.valid && t.mem_read && (t.ex_rd != 5'd0) && exp_conflict;

            if (exp_load_use) n_stall++;
            if (t.btaken)     n_flush++;
            // a name match on a register the ID instruction does NOT read
            if (t.valid && t.mem_read && (t.ex_rd != 0) && !exp_conflict &&
                (((t.ex_rd == t.rs1) && !t.u1) || ((t.ex_rd == t.rs2) && !t.u2)))
                n_phantom++;

            checks++;
            if (stall_if !== exp_load_use) begin
                $display("  FAIL  stall_if: rd=%0d rs1=%0d rs2=%0d u1=%0b u2=%0b mr=%0b v=%0b -> %0b, expected %0b",
                         t.ex_rd, t.rs1, t.rs2, t.u1, t.u2, t.mem_read, t.valid, stall_if, exp_load_use);
                errors++;
            end
            checks++;
            if (bubble_id !== exp_load_use) begin
                $display("  FAIL  bubble_id -> %0b, expected %0b", bubble_id, exp_load_use);
                errors++;
            end
            checks++;
            if (flush_id !== t.btaken) begin
                $display("  FAIL  flush_id -> %0b, expected %0b", flush_id, t.btaken);
                errors++;
            end
        end

        checks++;
        if (n_stall    < 200) begin $display("  FAIL  only %0d load-use stalls seen", n_stall); errors++; end
        checks++;
        if (n_phantom  < 100) begin $display("  FAIL  only %0d phantom-dependency cases", n_phantom); errors++; end

        $display("  coverage: %0d load-use stalls, %0d flushes, %0d phantom deps correctly ignored",
                 n_stall, n_flush, n_phantom);
        if (errors == 0) $display("  tb_hazard_unit: %0d checks PASSED", checks);
        else             $display("  tb_hazard_unit: %0d of %0d checks FAILED", errors, checks);

        $finish;
    end

endmodule
