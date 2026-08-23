#!/usr/bin/env bash
# Compile, elaborate and run the testbench under Vivado's xsim.
# Usage:  ./run.sh          (from the sim/ directory)
set -e

VIVADO_BIN="${VIVADO_BIN:-/c/Xilinx/2025.1/Vivado/bin}"

RTL="../rtl/pipeline_regs.sv \
     ../rtl/alu.sv \
     ../rtl/regfile.sv \
     ../rtl/fetch.sv \
     ../rtl/decode.sv \
     ../rtl/execute.sv \
     ../rtl/mem_stage.sv \
     ../rtl/writeback.sv \
     ../rtl/forward_unit.sv \
     ../rtl/hazard_unit.sv \
     ../rtl/top.sv"

echo "=== analyze ==="
"$VIVADO_BIN/xvlog.bat" -sv $RTL tb_top.sv

echo "=== elaborate ==="
"$VIVADO_BIN/xelab.bat" -debug typical -timescale 1ns/1ps work.tb_top -s tb_sim

echo "=== run ==="
"$VIVADO_BIN/xsim.bat" tb_sim -runall
