// tb_alu.sv
// Constrained-random unit testbench for the ALU.
//
// Stimulus is weighted toward the values that break arithmetic: zero, one,
// all-ones, and both signed extremes. Uniform random alone almost never hits
// 0x8000_0000, which is exactly where signed/unsigned and shift bugs live.

`timescale 1ns/1ps

module tb_alu;
    import pipeline_pkg::*;

    localparam int N_TXN = 5000;

    logic [31:0] a, b, result;
    alu_op_t     op;
    logic        zero;

    alu dut (.a(a), .b(b), .op(op), .result(result), .zero(zero));

    int errors = 0;
    int checks = 0;
    int op_hits [11];

    // -------------------------------------------------------------------------
    // stimulus
    // -------------------------------------------------------------------------
    class alu_txn;
        rand bit [31:0] ra;
        rand bit [31:0] rb;
        rand bit [3:0]  rop;

        // only the encodings the ALU actually defines
        constraint c_op { rop inside {[0:10]}; }

        constraint c_edge_a {
            ra dist {
                32'h0000_0000                    := 6,
                32'h0000_0001                    := 6,
                32'hFFFF_FFFF                    := 6,
                32'h8000_0000                    := 6,
                32'h7FFF_FFFF                    := 6,
                [32'h0000_0002 : 32'h7FFF_FFFE]  :/ 35,
                [32'h8000_0001 : 32'hFFFF_FFFE]  :/ 35
            };
        }
        constraint c_edge_b {
            rb dist {
                32'h0000_0000                    := 6,
                32'h0000_0001                    := 6,
                32'hFFFF_FFFF                    := 6,
                32'h8000_0000                    := 6,
                32'h7FFF_FFFF                    := 6,
                [32'h0000_0002 : 32'h7FFF_FFFE]  :/ 35,
                [32'h8000_0001 : 32'hFFFF_FFFE]  :/ 35
            };
        }
    endclass

    // -------------------------------------------------------------------------
    // reference model
    // Written against the ISA definition rather than transcribed from the RTL.
    // -------------------------------------------------------------------------
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
            4'd8:    return (sa < sb)  ? 32'd1 : 32'd0;   // SLT  signed
            4'd9:    return (ia < ib)  ? 32'd1 : 32'd0;   // SLTU unsigned
            4'd10:   return ib;                           // COPY_B
            default: return 32'd0;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    initial begin
        alu_txn t = new();
        logic [31:0] exp;

        $display("");
        $display("======== tb_alu: %0d constrained-random transactions ========", N_TXN);

        for (int i = 0; i < N_TXN; i++) begin
            if (!t.randomize()) begin
                $display("  FAIL  randomize() failed on iteration %0d", i);
                errors++;
                break;
            end

            a  = t.ra;
            b  = t.rb;
            op = alu_op_t'(t.rop);
            op_hits[t.rop]++;
            #1;

            exp = ref_alu(t.ra, t.rb, t.rop);
            checks++;
            if (result !== exp) begin
                $display("  FAIL  op=%0d a=0x%08x b=0x%08x -> 0x%08x, expected 0x%08x",
                         t.rop, t.ra, t.rb, result, exp);
                errors++;
            end

            checks++;
            if (zero !== (exp == 32'd0)) begin
                $display("  FAIL  op=%0d a=0x%08x b=0x%08x -> zero=%0b, expected %0b",
                         t.rop, t.ra, t.rb, zero, (exp == 32'd0));
                errors++;
            end
        end

        // coverage: every defined opcode must have been exercised
        for (int i = 0; i <= 10; i++) begin
            checks++;
            if (op_hits[i] == 0) begin
                $display("  FAIL  opcode %0d never exercised", i);
                errors++;
            end
        end

        $display("  op hit counts: %p", op_hits);
        if (errors == 0) $display("  tb_alu: %0d checks PASSED", checks);
        else             $display("  tb_alu: %0d of %0d checks FAILED", errors, checks);

        $finish;
    end

endmodule
