// tb_regfile.sv
// Constrained-random unit testbench for the register file.
//
// Checks against a shadow model, with addresses constrained to a small range so
// that read-during-write collisions (the write-through path) happen constantly
// rather than once in a thousand transactions. x0 is weighted heavily because
// the x0-vs-bypass priority is the subtle bug here.

`timescale 1ns/1ps

module tb_regfile;

    localparam int N_TXN = 4000;

    logic        clk = 1'b0;
    logic        we;
    logic [4:0]  rs1, rs2, w_addr;
    logic [31:0] w_data, rd1, rd2;

    always #5 clk = ~clk;

    regs dut (
        .clk (clk), .rs1 (rs1), .rs2 (rs2),
        .w_addr (w_addr), .w_data (w_data), .we (we),
        .rd1 (rd1), .rd2 (rd2)
    );

    logic [31:0] model [32];
    int errors = 0, checks = 0;
    int n_bypass = 0, n_x0_read = 0, n_x0_write = 0;

    class rf_txn;
        rand bit [4:0]  a_rs1, a_rs2, a_w;
        rand bit [31:0] d;
        rand bit        wen;

        // small address space -> frequent collisions; x0 over-weighted
        constraint c_addr {
            a_rs1 dist { 5'd0 := 20, [5'd1:5'd6] :/ 80 };
            a_rs2 dist { 5'd0 := 20, [5'd1:5'd6] :/ 80 };
            a_w   dist { 5'd0 := 20, [5'd1:5'd6] :/ 80 };
        }
        constraint c_we { wen dist { 1'b1 := 70, 1'b0 := 30 }; }
    endclass

    function automatic logic [31:0] ref_read(input logic [4:0] addr);
        if (addr == 5'd0)                return 32'd0;   // x0 wins over bypass
        else if (we && (w_addr == addr)) return w_data;  // write-through
        else                             return model[addr];
    endfunction

    initial begin
        rf_txn t = new();
        logic [31:0] exp1, exp2;

        $display("");
        $display("======== tb_regfile: %0d constrained-random transactions ========", N_TXN);

        for (int i = 0; i < 32; i++) begin
            model[i]     = 32'd0;
            dut.regs[i]  = 32'd0;
        end

        for (int i = 0; i < N_TXN; i++) begin
            @(negedge clk);
            if (!t.randomize()) begin
                $display("  FAIL  randomize() failed"); errors++; break;
            end
            rs1    = t.a_rs1;
            rs2    = t.a_rs2;
            w_addr = t.a_w;
            w_data = t.d;
            we     = t.wen;
            #1;

            if (we && (w_addr != 0) && ((w_addr == rs1) || (w_addr == rs2))) n_bypass++;
            if ((rs1 == 0) || (rs2 == 0)) n_x0_read++;
            if (we && (w_addr == 0))      n_x0_write++;

            exp1 = ref_read(rs1);
            exp2 = ref_read(rs2);

            checks++;
            if (rd1 !== exp1) begin
                $display("  FAIL  rd1: rs1=%0d we=%0b w_addr=%0d -> 0x%08x, expected 0x%08x",
                         rs1, we, w_addr, rd1, exp1);
                errors++;
            end
            checks++;
            if (rd2 !== exp2) begin
                $display("  FAIL  rd2: rs2=%0d we=%0b w_addr=%0d -> 0x%08x, expected 0x%08x",
                         rs2, we, w_addr, rd2, exp2);
                errors++;
            end

            @(posedge clk);
            if (we && (w_addr != 5'd0)) model[w_addr] = w_data;
        end

        // the interesting scenarios must actually have occurred
        checks++;
        if (n_bypass    < 100) begin $display("  FAIL  only %0d write-through collisions", n_bypass);  errors++; end
        checks++;
        if (n_x0_write  < 100) begin $display("  FAIL  only %0d writes to x0", n_x0_write);            errors++; end
        checks++;
        if (n_x0_read   < 100) begin $display("  FAIL  only %0d reads of x0", n_x0_read);              errors++; end

        $display("  coverage: %0d write-through hits, %0d x0 writes, %0d x0 reads",
                 n_bypass, n_x0_write, n_x0_read);
        if (errors == 0) $display("  tb_regfile: %0d checks PASSED", checks);
        else             $display("  tb_regfile: %0d of %0d checks FAILED", errors, checks);

        $finish;
    end

endmodule
