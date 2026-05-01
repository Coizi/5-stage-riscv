

module regs (
    input logic [4:0] rs1, rs2, w_addr,
    input logic [31:0] w_data,
    input logic we,
    input logic clk,
    output logic [31:0] rd1, rd2
);

    //make registers
    logic [31:0] regs [31:0];

    //read regs
    assign rd1 = regs[rs1];
    assign rd2 = regs[rs2];

    always_ff @(posedge clk) begin
        if (we && (w_addr != 5'd0)) begin
            regs[w_addr] <= w_data;
        end
    end

endmodule: regs