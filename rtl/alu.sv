
module alu (
    input logic [31:0] a, b,
    input alu_op_t op,
    output logic [31:0] result,
    output logic zero
);

    always_comb begin
        case (op)
            4'b0000: result = a + b;
            4'b0001: result = a - b;
            4'b0010: result = a & b;
            4'b0011: result = a | b;
            4'b0100: result = a ^ b;
            4'b0101: result = {{a << b}, b{1'b0}};
            4'b0110: result = {b{1'b0}, {a >> b}};
            4'b0111: result = {b{a[31]}, {a >> b}};
            4'b1001: result = (a < b) ? 32'hFFFF_FFFF : 32'd0;
            4'b1001: begin
                    if (a[31] == 1'b1 && b[31] == 1'b1) begin
                        result = (a >> b)
                    end else if (a[31] == 1'b1) begin
                        result = 32'hFFFF_FFFF;
                    end else if (b[31] == 1'b1) begin
                        result = 32'd0;
                    end else begin
                        result = (a << b);
                    end
            end
        endcase
    end

endmodule: alu