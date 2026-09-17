################################################################################
# part/xcvu19p-fsva3824-2-e/part.tcl  --  THE PART PACK for xcvu19p-fsva3824-2-e
#
# Virtex UltraScale+, XCVU19P, FSVA3824 package, speed grade -2, extended
# temperature. The largest device in this toolkit by an order of magnitude:
# four SLRs, 4.1 M LUTs, 48 GTY transceivers, no processing system. It is the
# user FPGA of the Synopsys HAPS-SX 1F prototyping system, and the part string
# here is the one the HAPS-SX build scripts in this lab state verbatim
# (`set PART xcvu19p-fsva3824-2-e`). That is where the PACKAGE and the SPEED
# GRADE came from; nothing else in this file came from anywhere but Vivado.
#
# WHAT WAS MEASURED AND WHAT WAS ASSERTED. Every number in this file was read
# from the Vivado 2024.1 install on 2026-09-17 by one batch session whose raw
# output was kept (see facts_source). The lines that are NOT a measurement, and
# are said so where they occur:
#
#   ASSERTED   vendor xilinx; temp_grade `e` (the property reads `E`; the part
#              string spells it lower case); slices being CLBs; idelay_count
#              being the RXTX_BITSLICE count; slr_crossing_registers being the
#              LAGUNA_RX_REG0 count; which physical primitives are worth
#              listing in io_buffer_primitive; has_ps left UNSET rather than
#              false; min_vivado_version as an observation.
#   MEASURED   everything else - identity, capacity, banks, clocking, the site
#              and BEL census, and every retarget / rejection in section 5.
#   READ FROM THE UNISIM SOURCE  the IDELAYE3 reference-clock range and default,
#              with the file and line quoted.
#   DEFERRED   idelay_ref_freq_hz. No file in the install states it.
#
# The census was CALIBRATED before it was trusted: the same script was run
# against xck26-sfvc784-2LV-c in the same hour and reproduced every number in
# that pack - properties, sites and BELs - exactly. It did NOT reproduce the
# buffer-retarget anomaly the xck26 pack records; section 5 has that story,
# and it is written down rather than resolved.
#
# NOT IN HERE, EVER: a pin, an IO standard, a board name, a board voltage, a
# HAPS connector. The HAPS-SX is a board; the daughter cards on it are boards;
# every fact about either lives in the project, in fpga/board/<board>/board.tcl
# and the target's XDC. This file would be equally true of this device on any
# other board, and that is the test for what belongs here.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

#### 1. IDENTITY ###############################################################

part_set part_name        xcvu19p-fsva3824-2-e
part_set family           virtexuplus         ;# ARCHITECTURE
part_set family_full_name "Virtex UltraScale+"
part_set device           xcvu19p
part_set package          fsva3824
part_set speed_grade      -2
part_set temp_grade       e                   ;# TEMPERATURE_GRADE_LETTER = E, and the
                                              ;# part string ends -e to match. E is
                                              ;# EXTENDED, not commercial: the
                                              ;# operating range is 0-100 degC.
part_set vendor           xilinx              ;# ASSERTED. No property says it.
part_set idcode           0x04ba1093
part_set license_class    Full                ;# LICENSE = Full. A runner with no
                                              ;# licence server cannot build for
                                              ;# this part, and finds out at the end
                                              ;# of synthesis.

part_set min_vivado_version 2024.1
part_note {min_vivado_version is an OBSERVATION - 2024.1 is the version these
           facts were read from. 2021.1, 2025.2 and 2026.1 are also installed
           on this host and none was queried. It is not a vendor support
           statement and must not be quoted as one.}

part_set facts_source \
    {Vivado v2024.1 (64-bit), SW Build 5076996 on 2024-05-22, read on
     2026-09-17 by one batch session (vivado -mode batch -source census.tcl)
     with: get_parts + list_property for the device properties; link_design
     -part <part> in memory with no project (23 s) for the clock-region, SLR,
     IO-bank, site and BEL census; create_cell -reference <prim> on that
     linked design, reading REF_NAME of the created cell, for the primitive
     acceptance probe. No licence was needed and no design was built. The
     same script was run against xck26-sfvc784-2LV-c in the same hour and
     reproduced that pack's numbers exactly.}

part_note {The part string was taken from the lab's own HAPS-SX build scripts,
           which state `set PART xcvu19p-fsva3824-2-e` in four places
           (HAPS-work/fpga/haps-sx/scripts/build_vivado.tcl,
           HAPS-work/targets/haps-sx-sdio/scripts/build.tcl, and two under
           nanosoc-multicore-system/pynq/targets/haps-sx-*). The install
           resolves it and reports NAME = xcvu19p-fsva3824-2-e, PACKAGE =
           fsva3824, SPEED = -2, SPEED_LABEL = PRODUCTION (1.31, 2020-12-02),
           PACKAGE_PINOUT_VERSION = PRODUCTION 1.3 11/27/2019.}

part_note {MAX/MIN_OPERATING_TEMPERATURE read 100 and 0 degC - the E grade.
           MAX/MIN_OPERATING_VOLTAGE read 0.876 and 0.825 V, REF 0.850 V.
           COMPATIBLE_PARTS = xcvu19p_CIVfsva3824. There is no schema key for
           any of these, so they are recorded here as read.}


#### 2. CAPACITY ###############################################################

part_set luts              4085760      ;# LUT_ELEMENTS
part_set ffs               8171520      ;# FLIPFLOPS
part_set slices            510720       ;# SLICES = CLBs on UltraScale+. Eight LUTs
                                        ;# each; the 7-series pack's slices are four.
                                        ;# The site census below has SLICEL 391200 +
                                        ;# SLICEM 119520 = 510720, which reconciles.
part_set brams             2160         ;# BLOCK_RAMS
part_set bram18s           4320
part_set dsps              3840         ;# DSP48E2
part_set urams             320          ;# ULTRA_RAMS
part_set clock_regions     180
part_set clock_region_grid X0Y0-X8Y19
part_set user_iobs         2072         ;# AVAILABLE_IOBS
part_set gt_count          48           ;# GB_TRANSCEIVERS = GTYE4_TRANSCEIVERS = 48
part_set gt_primitive      GTYE4_CHANNEL

part_note {The die carries more than the package bonds out, twice over, and
           both numbers are kept: the census has 80 GTYE4_CHANNEL sites and
           BELs against 48 GTYE4_TRANSCEIVERS in the part properties, and
           960+960+160 HPIOB plus 48+48 HDIOB sites (2176) against 2072
           AVAILABLE_IOBS. A design is bounded by the property, and the
           census is what shows the property is a package fact.}

# ---- STACKED SILICON --------------------------------------------------------
#
# FOUR SLRs. Every path that crosses between two of them needs a Laguna
# register, and on this device that is not an edge case: the floorplan is a
# quarter of the timing closure problem. The cascade in pack_schema.tcl makes
# slr_topology required the moment slrs is above 1.
part_set slrs                   4
part_set slr_topology           {SLR0 SLR1 SLR2 SLR3}
part_set slr_crossing_registers 23040

part_note {slr_topology is the SLR list as get_slrs enumerates it, bottom to
           top: SLR0 is at the bottom of the die (LOWER_RIGHT_CORNER (0,0))
           and SLR3 at the top. THE CONFIGURATION MASTER IS SLR1, NOT SLR0:
           IS_MASTER = 1 on SLR1 and CONFIG_ORDER_INDEX runs SLR1, SLR0, SLR2,
           SLR3. The xcku115 pack did not read this and says so; here it was
           read. Every SLR reports NUM_SITES 180530 and NUM_TILES 322196 -
           the four are identical in size.}

part_note {slr_crossing_registers is the LAGUNA_RX_REG0 BEL count, 23040,
           following the xcku115 pack's convention. It RECONCILES with the SLR
           properties: every boundary reports NUM_TOP_SLLS / NUM_BOT_SLLS =
           23040, so 23040 is the super-long-line count per crossing. There
           are 23040 LAGUNA sites device-wide, each with six RX and six TX
           register BELs; whether a middle SLR's Laguna sites serve both of
           its boundaries was NOT read and is not stated.}

# EVERY BANK, as get_iobanks lists them. 55 banks: 38 BT_HIGH_PERFORMANCE,
# 4 BT_HIGH_DENSITY, 12 BT_MGT and bank 0. There are NO BT_HIGH_RANGE banks on
# this device and no PS banks.
part_set io_banks {0
                   19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38
                   59 60 61 62 63 64 65 66
                   69 70 71 72 73 74 75 76 77 78
                   83 88 93 98
                   220 221 222 225 226 227 230 231 232 235 236 237}
part_set io_bank_types {0   BT_NO_USER_IO
                        19  BT_HIGH_PERFORMANCE
                        20  BT_HIGH_PERFORMANCE
                        21  BT_HIGH_PERFORMANCE
                        22  BT_HIGH_PERFORMANCE
                        23  BT_HIGH_PERFORMANCE
                        24  BT_HIGH_PERFORMANCE
                        25  BT_HIGH_PERFORMANCE
                        26  BT_HIGH_PERFORMANCE
                        27  BT_HIGH_PERFORMANCE
                        28  BT_HIGH_PERFORMANCE
                        29  BT_HIGH_PERFORMANCE
                        30  BT_HIGH_PERFORMANCE
                        31  BT_HIGH_PERFORMANCE
                        32  BT_HIGH_PERFORMANCE
                        33  BT_HIGH_PERFORMANCE
                        34  BT_HIGH_PERFORMANCE
                        35  BT_HIGH_PERFORMANCE
                        36  BT_HIGH_PERFORMANCE
                        37  BT_HIGH_PERFORMANCE
                        38  BT_HIGH_PERFORMANCE
                        59  BT_HIGH_PERFORMANCE
                        60  BT_HIGH_PERFORMANCE
                        61  BT_HIGH_PERFORMANCE
                        62  BT_HIGH_PERFORMANCE
                        63  BT_HIGH_PERFORMANCE
                        64  BT_HIGH_PERFORMANCE
                        65  BT_HIGH_PERFORMANCE
                        66  BT_HIGH_PERFORMANCE
                        69  BT_HIGH_PERFORMANCE
                        70  BT_HIGH_PERFORMANCE
                        71  BT_HIGH_PERFORMANCE
                        72  BT_HIGH_PERFORMANCE
                        73  BT_HIGH_PERFORMANCE
                        74  BT_HIGH_PERFORMANCE
                        75  BT_HIGH_PERFORMANCE
                        76  BT_HIGH_PERFORMANCE
                        77  BT_HIGH_PERFORMANCE
                        78  BT_HIGH_PERFORMANCE
                        83  BT_HIGH_DENSITY
                        88  BT_HIGH_DENSITY
                        93  BT_HIGH_DENSITY
                        98  BT_HIGH_DENSITY
                        220 BT_MGT
                        221 BT_MGT
                        222 BT_MGT
                        225 BT_MGT
                        226 BT_MGT
                        227 BT_MGT
                        230 BT_MGT
                        231 BT_MGT
                        232 BT_MGT
                        235 BT_MGT
                        236 BT_MGT
                        237 BT_MGT}

part_note {Banks 83, 88, 93 and 98 are BT_HIGH_DENSITY - one HD bank per SLR,
           24 pin pairs each (HDIOB_M 48 + HDIOB_S 48 sites). HD banks carry
           no IDELAY and no bitslice: their IO logic is HDIOLOGIC, whose BELs
           are IDDR/IPFF/OPFF/TFF only. idelay_available below is true OF THE
           DEVICE; it is not true of those four banks, and which bank a signal
           lands in is a board fact this pack does not state.}

# has_ps is DELIBERATELY UNSET rather than set false, for the reason the
# xcku115 pack gives: nothing here read a property called "has PS", and an
# unset key errors when read, which a false cannot be told apart from a
# default. The site census has no PS8 - and section 5 records that create_cell
# nonetheless ACCEPTS one, which is the reason the census and not the probe is
# what "physical" means in this pack.
part_note {No processing system: the site census has no PS7 and no PS8 site,
           and there are no PS banks. has_ps is left unset. See section 5 for
           why PS8 is nonetheless not in primitives_rejected.}


#### 3. CLOCKING ###############################################################
#
# PHYSICAL PRIMITIVES ONLY, and every legacy name below is accepted here and
# means something else - section 5, before changing any of these.

part_set global_buffer         BUFGCTRL
part_set global_buffer_count   320        ;# 80 per SLR
part_set clock_buffer_ce       BUFGCE     ;# 960 BUFGCE sites, and the probe agrees:
                                          ;# see section 5 for the day it did not.
part_set clock_buffer_ce_count 960
part_set clock_buffer_div      BUFGCE_DIV ;# 160

part_set has_mmcm       true
part_set mmcm_primitive MMCME4_ADV
part_set mmcm_count     40                ;# MMCM = 40, and 40 MMCM sites
part_set pll_primitive  PLLE4_ADV
part_set pll_count      80                ;# 80 PLL sites

part_note {40 MMCMs and 80 PLLs - two per clock-region column pair, and once
           again the MMCM is the SCARCER resource, which is what makes the
           PLLE2_ADV -> MMCME4_ADV retarget in section 5 expensive rather than
           merely wrong. The site types are MMCM and PLL, not MMCME4_ADV and
           PLLE4_ADV: on UltraScale+ the site name and the primitive name are
           different strings, exactly as on xck26.}


#### 4. IO #####################################################################

part_set io_buffer_primitive {IBUF OBUF OBUFT IOBUF IOBUFE3 IBUFDS IOBUFDS IOBUFDS_DCIEN}
part_set serdes_primitive    {ISERDESE3 OSERDESE3}
part_note {ISERDESE2 and OSERDESE2 are REJECTED here, not retargeted - the
           good outcome. The E3 pair is physically implemented in the
           bitslices: 2080 BITSLICE_RX_TX sites plus 320 BITSLICE_TX, under
           320 BITSLICE_CONTROL.}

part_set idelay_available         true
part_set idelay_primitive         IDELAYE3
part_set idelay_control_primitive IDELAYCTRL
part_set idelay_count             2080
part_note {idelay_count is the RXTX_BITSLICE count, as on the other two
           UltraScale packs: the input delay is a resource inside the
           bitslice, not a site, and counting IDELAYE3 sites returns zero.
           ASSERTED interpretation, MEASURED number.}

# THE REFERENCE CLOCK. Three keys, three questions, and this is UltraScale+
# so the 7-series folklore figure of 200 MHz is BELOW the legal minimum.
#
#   range    IDELAYE3.v lines 313-314 in the 2024.1 unisim
#            (data/verilog/src/unisims/IDELAYE3.v): 300 to 2667 MHz, one
#            continuous band, on the branch SIM_DEVICE != "ULTRASCALE".
#   default  IDELAYE3.v line 37: REFCLK_FREQUENCY defaults to 300.0 MHz.
#   required deferred - see below.
part_set idelay_ref_freq_range_hz   {300000000 2667000000}
part_set idelay_ref_freq_default_hz 300000000

part_defer -permanent idelay_ref_freq_hz {
    error "no file in the Vivado install states a REQUIRED IDELAYCTRL reference
           frequency for this device. What the install has is the model's own
           range check (300-2667 MHz, in idelay_ref_freq_range_hz) and its
           default parameter (300 MHz). IDELAYCTRL.v checks no frequency at
           all; its only constrained parameter is SIM_DEVICE, which must be
           ULTRASCALE here. The 7-series folklore figure of 200 MHz is OUTSIDE
           the legal range on this device. Choose a frequency, check it against
           the range, and state it in the design."
}


#### 5. PHYSICAL VERSUS ACCEPTED ###############################################
#
# THE REASON THIS PACK EXISTS.
#
# Seventeen legacy names are ACCEPTED on this part. Each prints one
# [Coretcl 2-1024] warning and becomes something else, and REF_NAME on the
# created cell confirms what. Two of them are not renames:
#
#   PLLE2_ADV  -> MMCME4_ADV   Ask for a PLL, get an MMCM. 80 PLLs, 40 MMCMs.
#   PLLE2_BASE -> MMCME4_ADV   The same, from the other 7-series PLL name.
#
# Measured with create_cell -reference <prim> on the linked design, reading
# REF_NAME of the cell that came back, Vivado v2024.1, 2026-09-17.

part_set primitives_retargeted {
    IDELAYE2    IDELAYE3
    ODELAYE2    ODELAYE3
    MMCME2_ADV  MMCME4_ADV
    MMCME2_BASE MMCME4_ADV
    MMCME3_ADV  MMCME4_ADV
    PLLE2_ADV   MMCME4_ADV
    PLLE2_BASE  MMCME4_ADV
    PLLE3_ADV   PLLE4_ADV
    BUFG        BUFGCE
    BUFGMUX     BUFGCTRL
    BUFH        BUFGCE
    BUFHCE      BUFGCE
    BUFIO       BUFGCE
    RAMB36E1    RAMB36E2
    RAMB18E1    RAMB18E2
    DSP48E1     DSP48E2
    SYSMONE1    SYSMONE4
}

# THE BUFFER FAMILY DID NOT RETARGET THE WAY THE OTHER TWO PACKS SAY IT DOES,
# and this is recorded in full rather than reconciled, because the two
# measurements were made with the same Vivado build and disagree:
#
#   2026-09-08, xck26 and xcku115 packs (and part/README.md section 4):
#       BUFG, BUFH, BUFHCE, BUFIO  ->  BUFGCTRL   (no clock enable)
#       BUFGCE                     ->  BUFGCTRL   (the recorded ANOMALY: a
#                                                  device with 96 BUFGCE sites
#                                                  reported its BUFGCE as
#                                                  retargeted)
#   2026-09-17, this census, on THIS part AND re-run on xck26 the same hour:
#       BUFG, BUFH, BUFHCE, BUFIO  ->  BUFGCE     (which HAS a clock enable)
#       BUFGCE                     ->  physical, no warning, REF_NAME BUFGCE
#       BUFGMUX                    ->  BUFGCTRL   (agrees)
#
# So the anomaly the other packs document DID NOT REPRODUCE, on either device,
# and the BUFHCE story changed with it. The re-run reproduced every OTHER
# number in the xck26 pack exactly, so the script is reading the same install;
# what differed between the two sessions is not recorded in either
# facts_source and the 2026-09-08 raw output was not kept. This pack states
# what it measured. It does not correct the other two packs, which state what
# they measured, and it does not explain the difference, because it cannot.
part_note {ANOMALY NOT REPRODUCED, recorded not resolved: on 2026-09-17
           create_cell -reference BUFGCE on this part returned a cell whose
           REF_NAME is BUFGCE with no retarget warning, and BUFG/BUFH/BUFHCE/
           BUFIO retargeted to BUFGCE rather than to BUFGCTRL. The xck26 and
           xcku115 packs record the opposite from 2026-09-08 with the same
           Vivado build, and a re-run on xck26 on 2026-09-17 agreed with THIS
           pack, not with that one. Neither measurement has been dropped; a
           design that wants a clock enable should name BUFGCE, which is a
           site on every UltraScale(+) part in this toolkit under both
           readings.}

# ACCEPTED WITH NO SITE. PS8 and BUFG_PS are accepted by create_cell on this
# part - no warning, REF_NAME unchanged - and the device has no PS8 site and no
# BUFG_PS site. They are therefore in NEITHER list below: not retargeted (they
# were not), not rejected (they were not). The site census is what "physical"
# means in this pack, and by that test neither exists here. A design that
# instantiates a PS8 on this part will get past create_cell and fail at
# placement, which is later than it should.
part_note {PS8 and BUFG_PS are ACCEPTED by create_cell on this part and have
           no site in the census. Recorded here because the schema has no
           list for "accepted, no site", and putting them in
           primitives_rejected would misreport the measurement.}

part_set primitives_rejected {
    BUFR BUFMR BUFMRCE PS7 XADC VCU
    ISERDESE2 OSERDESE2
    GTHE3_CHANNEL GTYE3_CHANNEL
    HBM_ONE_STACK_INTF
}
part_note {GTME4_CHANNEL was also probed and came back [Coretcl 2-33] "Could
           not find master cell" - the name is not in this install's library
           at all, which is a different refusal from [Coretcl 2-1475] "not
           supported in the current architecture", so it is not listed as
           rejected. GTHE4_CHANNEL IS accepted here although the device's
           transceivers are all GTYE4: 80 GTYE4_CHANNEL sites, zero GTHE4.}

part_set bram_primitive   {RAMB36E2 RAMB18E2}
part_set dsp_primitive    DSP48E2
part_set uram_primitive   URAM288
part_set sysmon_primitive SYSMONE4          ;# 4 sites - one per SLR

# THE EVIDENCE, and this time it is the WHOLE site census: every SITE_TYPE
# get_sites returned, with its count. 45 types, 707204 sites.
part_set primitive_sites {
    SLICEL             391200
    SLICEM             119520
    RAMBFIFO36         2160
    RAMBFIFO18         2160
    RAMB181            2160
    DSP48E2            3840
    URAM288            320
    MMCM               40
    PLL                80
    PLL_SELECT_SITE    320
    BUFGCTRL           320
    BUFGCE             960
    BUFGCE_DIV         160
    BUFGCE_HDIO        16
    BUFG_GT            480
    BUFG_GT_SYNC       300
    BUFCE_LEAF         145920
    BUFCE_ROW          960
    BUFCE_ROW_FSR      4960
    LAGUNA             23040
    GTYE4_CHANNEL      80
    GTYE4_COMMON       20
    PCIE4CE4           8
    SYSMONE4           4
    CONFIG_SITE        4
    CFGIO_SITE         4
    BITSLICE_RX_TX     2080
    BITSLICE_TX        320
    BITSLICE_CONTROL   320
    RIU_OR             160
    XIPHY_FEEDTHROUGH  160
    HARD_SYNC          720
    HPIOB_M            960
    HPIOB_S            960
    HPIOB_SNGL         160
    HPIOBDIFFINBUF     960
    HPIOBDIFFOUTBUF    960
    HPIO_VREF_SITE     80
    HDIOB_M            48
    HDIOB_S            48
    HDIOBDIFFINBUF     48
    HDIOLOGIC_M        48
    HDIOLOGIC_S        48
    HDIO_BIAS          4
    HDIO_VREF          4
    BIAS               80
}
part_note {The site census does NOT add up to the SLR properties, and both
           figures are kept: the 45 types above total 707204 sites, while the
           four SLRs each report NUM_SITES = 180530, which is 722120 - and
           MAX_SITE_INDEX on SLR0 is 722119. get_sites returns 14916 fewer
           objects than the SLRs claim to hold. The same gap exists on xck26
           (23671 returned against NUM_SITES 24328), so it is a property of
           what get_sites enumerates and not of this device. Which sites it
           omits was not established.}

# BELs, for the primitives whose site type does not carry their name, and for
# the configuration block that has no site type of its own at all.
part_set primitive_bels {
    MMCM_MMCM_TOP               40
    PLL_PLL_TOP                 80
    BUFGCTRL_BUFGCTRL           320
    BUFGCE_DIV_BUFGCE_DIV       160
    BUFCE_BUFCE                 976
    BUFCE_BUFCE_ROW             5920
    BUFCE_BUFCE_LEAF            145920
    BUFG_GT_BUFG_GT             480
    BUFG_GT_BUFG_GT_SYNC        300
    GCLK_DELAY                  960
    GCLK_DELAY_FSR              4960
    LCLK_DELAY                  145920
    RXTX_BITSLICE               2080
    TRISTATE_TX_BITSLICE        320
    BITSLICE_CONTROL_BEL        320
    SYSMONE4_SYSMONE4           4
    GTYE4_CHANNEL_GTYE4_CHANNEL 80
    GTYE4_COMMON_GTYE4_COMMON   20
    PCIE4CE4_BEL                8
    BEL_URAM288                 320
    RAMBFIFO36E2_RAMBFIFO36E2   2160
    RAMBFIFO18E2_RAMBFIFO18E2   2160
    RAMB18E2_U_RAMB18E2         2160
    DSP_ALU                     3840
    LAGUNA_RX_REG0              23040
    LAGUNA_TX_REG0              23040
    MASTER_JTAG                 4
    BSCAN1                      4
    DNA_PORT                    4
    ICAP_TOP                    1
    ICAP_BOT                    1
    STARTUP                     1
    USR_ACCESS                  1
    FRAME_ECC                   1
}
part_note {Three reconciliations, all kept because a census that adds up is a
           census that was read: BUFCE_BUFCE 976 = 960 BUFGCE + 16 BUFGCE_HDIO
           sites; BUFCE_BUFCE_ROW 5920 = 960 BUFCE_ROW + 4960 BUFCE_ROW_FSR
           sites; BUFCE_BUFCE_LEAF 145920 = the 145920 BUFCE_LEAF sites one
           to one (this device has no X16 leaf sites, unlike xcku115). And one
           that says something about stacked silicon: MASTER_JTAG, BSCAN and
           DNA_PORT count 4 - one per SLR - while STARTUP, ICAP_TOP, ICAP_BOT
           and USR_ACCESS count 1 for the whole device.}


#### 6. CONFIGURATION ##########################################################
#
# cfgbvs, config_voltage and bitstream_compress are left UNSET: the first two
# are decided by how bank 0 is wired on the board, the third is a build setting.
# Reading any of them errors and names the key. part/README.md section 5.

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
