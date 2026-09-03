#!/bin/sh
# ab_synth.sh <variant> <repo-dir>
# ORFS synthesis only (yosys + abc, ASAP7 SS libraries), identical settings
# for every variant, so the netlists can be compared stage by stage with
# ab_sta.sh.  Needs an OpenROAD-flow-scripts checkout: ORFS=/path (default
# /root/ORFS).  Results: $ORFS/flow/results/asap7/img_filter_ab<variant>/base/
V=$1
SRC=$2
ORFS=${ORFS:-/root/ORFS}
WORK=${AB_WORK:-/root/ab}
D=$ORFS/flow/designs/asap7/img_filter_ab
[ -n "$V" ] && [ -d "$SRC/rtl" ] || { echo "usage: ab_synth.sh <variant> <repo-dir>"; exit 2; }
mkdir -p "$D" "$WORK/$V"
cp "$SRC/rtl/img_filter.v" "$SRC/rtl/img_filter_def.v" "$WORK/$V/"
cat > "$D/config_$V.mk" <<CFG
export PLATFORM               = asap7
export DESIGN_NAME            = IMG_FILTER
export DESIGN_NICKNAME        = img_filter_ab$V
export VERILOG_FILES          = $WORK/$V/img_filter_def.v $WORK/$V/img_filter.v
export SDC_FILE               = $D/constraint.sdc
export CORE_UTILIZATION       = 22
export CORE_ASPECT_RATIO      = 1
export CORE_MARGIN            = 2
export PLACE_DENSITY          = 0.45
export SKIP_LAST_GASP         = 1
export INFER_CLKGATES         = 1
CFG
# minimal SDC for synthesis (abc delay target); STA constraints live in ab_sta.tcl
cat > "$D/constraint.sdc" <<'SDC'
current_design IMG_FILTER
create_clock -name core_clock -period 1000 [get_ports clk]
set_clock_uncertainty -setup 150 [get_clocks core_clock]
set_false_path -from [get_ports rst_n]
SDC
cd "$ORFS/flow" || exit 2
echo "== ab synth $V start $(date '+%H:%M:%S')  rtl sha $(sha256sum "$WORK/$V/img_filter.v" | cut -c1-16)" > "$WORK/$V/synth.log"
make DESIGN_CONFIG="$D/config_$V.mk" CORNER=WC synth >> "$WORK/$V/synth.log" 2>&1
RC=$?
echo "== ab synth $V exit $RC $(date '+%H:%M:%S')" >> "$WORK/$V/synth.log"
grep -E "Chip area|DFF" "reports/asap7/img_filter_ab$V/base/synth_stat.txt" 2>/dev/null | head -4
exit $RC
