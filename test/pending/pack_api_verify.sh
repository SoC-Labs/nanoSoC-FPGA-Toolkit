#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -uo pipefail
TK=/home/dam1n19/SoCLabs/nanoSoC-FPGA-Toolkit
SP="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0
ok()   { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
# $1 name  $2 expected-rc  $3.. command
expect() { local n="$1" want="$2"; shift 2; out=$("$@" 2>&1); rc=$?;
  if [ "$rc" = "$want" ]; then ok "$n (rc=$rc)"; else bad "$n (rc=$rc want $want)"; printf '%s\n' "$out" | head -5; fi; }
# a mutation must be REJECTED and the message must mention $3
mut() { local n="$1" sedexpr="$2" needle="$3" role="${4:-part}" src="${5:-$TK/part/xck26-sfvc784-2LV-c/part.tcl}"
  local d="$SP/mut/live"; rm -rf "$d"; mkdir -p "$d"; cp "$src" "$d/$role.tcl"
  eval "$sedexpr"
  out=$(printf 'source %s/part/pack_api.tcl\nif {[catch {%s_load %s} e]} { puts $e; exit 1 }\nexit 0\n' "$TK" "$role" "$d" | tclsh 2>&1); rc=$?
  if [ "$rc" != 1 ]; then bad "$n - ACCEPTED, the check did not fire"; return; fi
  if printf '%s' "$out" | grep -q -- "$needle"; then ok "$n"; else bad "$n - rejected but message lacks '$needle'"; fi; }

echo "== packs load and validate =="
for p in xc7z020clg400-1 xck26-sfvc784-2LV-c xcku115-flvb1760-1-c; do
  expect "load $p" 0 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-get --part $p part_name family
done
echo "== scripts =="
expect "part-get --all"            0 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-get --part xck26-sfvc784-2LV-c --all
expect "part-get missing key"      1 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-get --part xc7z020clg400-1 luts idelay_ref_freq_hz
expect "part-get unknown key"      2 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-get --part xc7z020clg400-1 luts_typo
expect "part-get unknown pack"     2 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-get --part xc7a35t luts
expect "probe part pack (abs path)" 0 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-probe -q $TK/part/xck26-sfvc784-2LV-c
expect "probe part pack (bare name)" 0 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-probe -q xck26-sfvc784-2LV-c
expect "probe relative path from wrong cwd" 2 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-probe -q part/xck26-sfvc784-2LV-c
expect "probe unknown pack"        2 env FPGA_FLOW_DIR=$TK $TK/scripts/fpga-flow-part-probe -q --role part nosuchpart
expect "probe board, var unset"    1 $TK/scripts/fpga-flow-part-probe -q $HERE/fixture-project/board/testbench-board
expect "probe board, var set"      0 env TESTBENCH_BOARD_FILES=$HERE/fixture-project/vendor-board-files $TK/scripts/fpga-flow-part-probe -q $HERE/fixture-project/board/testbench-board
expect "probe cannot tell role"    2 $TK/scripts/fpga-flow-part-probe -q $SP
echo "== mutation proofs: part role =="
D=$SP/mut/live
mut "unknown key"        "sed -i 's/^part_set mmcm_count     4/part_set mmcm_cont      4/' $D/part.tcl"          "unknown key 'mmcm_cont'"
mut "double set"         "sed -i 's/^part_set pll_count      8/part_set pll_count 8\npart_set mmcm_count 9/' $D/part.tcl" "already set to '4'"
mut "missing required"   "sed -i '/^part_set global_buffer         BUFGCTRL/d' $D/part.tcl"                      "MISSING required key 'global_buffer'"
mut "cascade has_ps"     "sed -i '/^part_set ps_type     PS8/d' $D/part.tcl"                                     "'has_ps' is true makes required"
mut "cascade slrs>1"     "sed -i 's/^part_set slrs              1/part_set slrs              2/' $D/part.tcl"    "'slrs' is >1 makes required"
mut "cascade idelay"     "sed -i '/^part_set idelay_primitive         IDELAYE3/d' $D/part.tcl"                   "'idelay_available' is true makes required"
mut "cascade has_mmcm"   "sed -i '/^part_set mmcm_primitive MMCME4_ADV/d' $D/part.tcl"                           "'has_mmcm' is true makes required"
mut "RETARGETED prim"    "sed -i 's/^part_set mmcm_primitive MMCME4_ADV/part_set mmcm_primitive MMCME2_ADV/' $D/part.tcl" "silently turns it into 'MMCME4_ADV'"
mut "REJECTED prim"      "sed -i 's/^part_set ps_type     PS8/part_set ps_type     PS7/' $D/part.tcl"            "primitives_rejected says this architecture REFUSES"
mut "empty str"          "sed -i 's/^part_set family_full_name \"Zynq UltraScale+\"/part_set family_full_name \"\"/' $D/part.tcl" "EMPTY 'family_full_name'"
mut "empty list"         "sed -i 's/^part_set io_banks {0 43 44 45 46 64 65 66 224 500 501 502 503 504 505}/part_set io_banks {}/' $D/part.tcl" "EMPTY LIST 'io_banks'"
mut "bad int type"       "sed -i 's/^part_set luts              117120/part_set luts              117k/' $D/part.tcl" "BAD TYPE 'luts'"
mut "part string wrong"  "sed -i 's/^part_set speed_grade      -2LV/part_set speed_grade      -1/' $D/part.tcl"  "does not contain the speed grade"
mut "temp grade mismatch" "sed -i 's/^part_set temp_grade       c /part_set temp_grade       i /' $D/part.tcl"   "does not end with '-i'"
mut "bram18 arithmetic"  "sed -i 's/^part_set bram18s           288/part_set bram18s           289/' $D/part.tcl" "is not twice brams"
mut "refclk out of range" "sed -i 's/^part_set idelay_ref_freq_default_hz 300000000/part_set idelay_ref_freq_default_hz 200000000/' $D/part.tcl" "outside every band"
mut "set+defer same key" "printf 'part_set ps_clk_config whatever\n' >> $D/part.tcl"                             "already DEFERRED"
echo "== mutation proofs: board role =="
B=$HERE/fixture-project/board/testbench-board/board.tcl
mut "bad enum"           "sed -i 's/^board_set bin_style       zynqmp/board_set bin_style       zynq/' $D/board.tcl"  "It must be one of: zynq7 zynqmp" board "$B"
mut "cascade board_part" "sed -i '/^board_defer board_repo_paths/,/^}/d' $D/board.tcl"                               "'board_part' is set makes required" board "$B"
mut "cascade fpgahub"    "printf 'board_set fpgahub_board grp\n' >> $D/board.tcl"                                    "'fpgahub_board' is set makes required" board "$B"
mut "MHz in a Hz key"    "sed -i 's/^board_set sys_clk_freq_hz 50000000/board_set sys_clk_freq_hz 50/' $D/board.tcl" "far too small to be HERTZ" board "$B"
mut "namespace collision" "printf 'board_set fpgahub_board x\nboard_set fpgahub_target x\n' >> $D/board.tcl"        "DIFFERENT NAMESPACES" board "$B"
mut "board missing req"  "sed -i '/^board_set platform        bare/d' $D/board.tcl"                                  "MISSING required key 'platform'" board "$B"
mut "bank voltage silly" "sed -i 's/{44 1.8 64 3.3}/{44 1800 64 3.3}/' $D/board.tcl"                                 "not millivolts" board "$B"
echo
echo "PASS=$pass FAIL=$fail"
[ "$fail" = 0 ]
