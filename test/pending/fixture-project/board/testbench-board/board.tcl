# A BOARD PACK FIXTURE. Lives in a scratch project, never in the toolkit:
# CONTRACT.md section 1 says a board pack ships with the project.
board_set board_name      testbench-board
board_set part            xck26-sfvc784-2LV-c
board_set platform        bare
board_set sys_clk_freq_hz 50000000
board_set bin_style       zynqmp
board_set oscillator_hz   25000000
board_set board_rev       revA
board_set io_voltage_by_bank {44 1.8 64 3.3}
board_set deploy_style    jtag

# THE SITE PATH. Never defaulted, never a literal: it arrives through board_env,
# which records the attempt whether it resolves or not.
board_set board_part "vendor:testbench:part0:1.0"
board_defer board_repo_paths {
    set root [board_env TESTBENCH_BOARD_FILES "the vendor board files for testbench-board"]
    if {![file isdirectory $root]} { error "not a directory: $root" }
    return $root
}
board_note {fixture pack, used by the pack API's own mutation tests}
