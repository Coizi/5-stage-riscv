// mem_stage.sv
// MEM stage. Drives the data memory and registers the result into MEM/WB.
//
// The DMEM read is SYNCHRONOUS: the address (ex_mem_reg.alu_result) is applied
// during this cycle and the data appears at the next clock edge -- which means
// the BRAM's own output register IS the mem_rdata field of MEM/WB. That is why
// load sign/zero extension happens in writeback, not here: the data does not
// exist yet in this stage.
//
// Stores are handled here because the store data (already forwarded in EX) and
// the byte enables are both available now.
//
// NOTE: dmem is declared inline. Split it into its own module if you ever want
// a second port on it.

module mem_stage
    import pipeline_pkg::*;
(
    input  logic     clk,
    input  logic     rst,
    input  ex_mem_t  ex_mem_reg,
    output mem_wb_t  mem_wb_reg
);
    localparam int DMEM_WORDS = 1024;
    localparam int DMEM_IDX_W = $clog2(DMEM_WORDS);

    logic [31:0] dmem [DMEM_WORDS];

    logic [DMEM_IDX_W-1:0] dmem_idx;
    logic [1:0]            addr_lsb;

    assign dmem_idx = ex_mem_reg.alu_result[DMEM_IDX_W+1:2];
    assign addr_lsb = ex_mem_reg.alu_result[1:0];

    // -------------------------------------------------------------------------
    // store alignment
    // The byte to be written can sit in any lane of the 32-bit word, so the
    // store data is REPLICATED across all lanes and the byte enables pick the
    // lane that actually lands. Same idea for halfwords.
    //   funct3: 000 = SB, 001 = SH, 010 = SW
    // -------------------------------------------------------------------------
    logic [3:0]  store_be;
    logic [31:0] store_data;

    always_comb begin
        store_be   = 4'b0000;
        store_data = ex_mem_reg.rs2_data;

        if (ex_mem_reg.mem_write) begin
            case (ex_mem_reg.mem_funct3)
                3'b000: begin                                   // SB
                    store_data = {4{ex_mem_reg.rs2_data[7:0]}};
                    store_be   = 4'b0001 << addr_lsb;
                end
                3'b001: begin                                   // SH
                    store_data = {2{ex_mem_reg.rs2_data[15:0]}};
                    store_be   = addr_lsb[1] ? 4'b1100 : 4'b0011;
                end
                default: begin                                  // SW
                    store_data = ex_mem_reg.rs2_data;
                    store_be   = 4'b1111;
                end
            endcase
        end
    end

    // -------------------------------------------------------------------------
    // data memory
    // Byte-enabled write + synchronous read: the standard Xilinx BRAM template.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (store_be[0]) dmem[dmem_idx][7:0]   <= store_data[7:0];
        if (store_be[1]) dmem[dmem_idx][15:8]  <= store_data[15:8];
        if (store_be[2]) dmem[dmem_idx][23:16] <= store_data[23:16];
        if (store_be[3]) dmem[dmem_idx][31:24] <= store_data[31:24];
    end

    // -------------------------------------------------------------------------
    // MEM/WB pipeline register
    // Data fields are deliberately not reset: keeping the DMEM read out of the
    // reset path is what lets it infer a BRAM output register. Only the control
    // bits need reset, and clearing reg_write/valid is enough to make a
    // post-reset bubble harmless.
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        mem_wb_reg.alu_result <= ex_mem_reg.alu_result;
        mem_wb_reg.mem_rdata  <= dmem[dmem_idx];
        mem_wb_reg.mem_funct3 <= ex_mem_reg.mem_funct3;
        mem_wb_reg.addr_lsb   <= addr_lsb;
        mem_wb_reg.rd_addr    <= ex_mem_reg.rd_addr;
        mem_wb_reg.mem_to_reg <= ex_mem_reg.mem_to_reg;

        if (rst) begin
            mem_wb_reg.reg_write <= 1'b0;
            mem_wb_reg.valid     <= 1'b0;
        end else begin
            mem_wb_reg.reg_write <= ex_mem_reg.reg_write;
            mem_wb_reg.valid     <= ex_mem_reg.valid;
        end
    end

endmodule: mem_stage
