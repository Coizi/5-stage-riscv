

// 32x32 register file.
//   - two asynchronous read ports (read in ID)
//   - one synchronous write port (written in WB)
//   - x0 is hardwired to zero: never written, always reads as 0
//   - internal write-through: a write in WB is visible to a read in ID
//     during the SAME cycle, which removes the need for a WB->ID forwarding path

module regs (
    input logic [4:0] rs1, rs2, w_addr,
    input logic [31:0] w_data,
    input logic we,
    input logic clk,
    output logic [31:0] rd1, rd2
);

    //make registers
    logic [31:0] regs [31:0];

    //write-through detect: WB is writing the register ID is reading, this cycle
    logic bypass1, bypass2;
    assign bypass1 = we && (w_addr == rs1);
    assign bypass2 = we && (w_addr == rs2);

    //read regs (x0 first so it can never return stale/X data)
    assign rd1 = (rs1 == 5'd0) ? 32'd0 :
                 bypass1       ? w_data :
                                 regs[rs1];

    assign rd2 = (rs2 == 5'd0) ? 32'd0 :
                 bypass2       ? w_data :
                                 regs[rs2];

    always_ff @(posedge clk) begin
        if (we && (w_addr != 5'd0)) begin
            regs[w_addr] <= w_data;
        end
    end

endmodule: regs
