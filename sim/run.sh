#!/usr/bin/env bash
# Compile, elaborate and run every testbench under Vivado's xsim.
#
#   ./run.sh          run all testbenches
#   ./run.sh alu      run one (alu | regfile | decode | execute |
#                              forward_unit | hazard_unit | top)
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

ALL_TB="alu regfile forward_unit hazard_unit decode execute top"
TBS="${1:-$ALL_TB}"

pass=0
fail=0

for tb in $TBS; do
    echo ""
    echo "############################################################"
    echo "#  tb_$tb"
    echo "############################################################"

    "$VIVADO_BIN/xvlog.bat" -sv $RTL "tb_$tb.sv" > /dev/null
    "$VIVADO_BIN/xelab.bat" -timescale 1ns/1ps "work.tb_$tb" -s "${tb}_sim" > /dev/null

    out=$("$VIVADO_BIN/xsim.bat" "${tb}_sim" -runall)
    echo "$out" | grep -E "FAIL|PASSED|pass |coverage|hits|========|====" || true

    if echo "$out" | grep -q "FAIL"; then
        fail=$((fail + 1))
    else
        pass=$((pass + 1))
    fi
done

echo ""
echo "############################################################"
if [ "$fail" -eq 0 ]; then
    echo "#  ALL $pass TESTBENCHES PASSED"
else
    echo "#  $fail of $((pass + fail)) TESTBENCHES FAILED"
fi
echo "############################################################"

exit $fail
