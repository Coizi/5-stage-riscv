

module fetch (
    input logic clk, rst, stall,
    input logic branch_taken, 
    input logic [31:0] branch_target,
    output if_id_t if_id_reg
);
    logic [31:0] pc;
    logic [31:0] imem [1024];
    always_ff @(posedge clk) begin
        if (rst) begin
            pc <= '0;
            if_id_reg.pc <= '0;
            if_id_reg.instr <= '0;
            if_id_reg.valid <= 1'b0
        end else begin

            if (!stall) begin

                if (branch_taken) begin
                    if_id_reg.valid <= 1'b0;
                    pc <= branch_target;
                end else begin
                    if_id_reg.valid <= 1'b1;
                    pc <= pc + 4;
                end
                if_id_reg.pc <= pc;
                if_id_reg.instr <= imem[pc >> 2];
            end

        end

    end

endmodule: fetch