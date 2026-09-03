#!/bin/sh
# Compile IMG_FILTER with Icarus Verilog and run one testbench mode.
#   sh scripts/run_sim.sh SMOKE       13-frame CI subset
#   sh scripts/run_sim.sh BLKV_GAP    8 directed frames, blk_v 27/31/37/45
#   sh scripts/run_sim.sh ALL_BLKV    50 frames, every legal blk_v 1..49
#   sh scripts/run_sim.sh FULL        complete release regression (hours)
#   sh scripts/run_sim.sh CASE_A      power/performance case A (+VCD optional)
#   sh scripts/run_sim.sh CASE_B      power case B
# The log lands in verification/logs/<mode>.log with start/end time stamps
# and the simulator exit code; TEST PASSED / TEST FAILED is the verdict.
set -u
MODE=${1:-SMOKE}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 2
mkdir -p verification/logs
LOG=verification/logs/$(echo "$MODE" | tr 'A-Z' 'a-z').log
VVP=${VVP_FILE:-/tmp/img_filter_tb_$$.vvp}

case "$MODE" in
    SMOKE)    ARGS="+SMOKE" ;;
    BLKV_GAP) ARGS="+BLKV_GAP" ;;
    ALL_BLKV) ARGS="+ALL_BLKV" ;;
    FULL)     ARGS="" ;;
    CASE_A)   ARGS="+CASE=A ${VCD:+ +VCD=$VCD}" ;;
    CASE_B)   ARGS="+CASE=B ${VCD:+ +VCD=$VCD}" ;;
    *) echo "unknown mode $MODE"; exit 2 ;;
esac

{
    echo "== run_sim.sh $MODE  start $(date '+%Y-%m-%d %H:%M:%S')"
    echo "== rtl sha256: $(sha256sum rtl/img_filter.v | cut -c1-16)  tb sha256: $(sha256sum verification/img_filter_tb.v | cut -c1-16)"
    echo "== $(iverilog -V 2>/dev/null | head -1)"
} > "$LOG"

if ! iverilog -g2005 -o "$VVP" rtl/img_filter_def.v rtl/img_filter.v \
        verification/img_filter_tb.v >> "$LOG" 2>&1; then
    echo "COMPILE FAILED" >> "$LOG"; exit 1
fi
# shellcheck disable=SC2086
vvp "$VVP" $ARGS >> "$LOG" 2>&1
RC=$?
echo "== exit code $RC  end $(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG"
rm -f "$VVP"
tail -6 "$LOG"
exit $RC
