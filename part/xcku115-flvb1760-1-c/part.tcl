################################################################################
# part/xcku115-flvb1760-1-c/part.tcl  --  THE PART PACK for xcku115-flvb1760-1-c
#
# Kintex UltraScale, XCKU115, FLVB1760 package, speed grade -1, commercial. A
# large stacked-silicon device: two SLRs, 52 transceivers, no processing
# system.
#
# EVERY VALUE HERE IS A SILICON FACT read from the Vivado install on 2026-09-08
# - see facts_source. Where the install does not state something this pack
# DEFERS the key with the reason rather than supplying a plausible number.
#
# NOT IN HERE, EVER: a pin, an IO standard, a board name. Whatever this device
# is fitted to - and whatever is fitted to that - is a PROJECT fact and lives in
# fpga/board/<board>/board.tcl.
#
# THE TWO THINGS THAT MAKE THIS PART DIFFERENT from the other two packs:
#
#   1. IT IS STACKED SILICON. slrs is 2, so slr_topology is required by the
#      cascade in pack_api.tcl, and every path that crosses between SLR0 and
#      SLR1 costs a Laguna register. On a stacked device the floorplan is part
#      of timing closure, not a tuning step afterwards.
#   2. IT NEEDS A FULL LICENCE. LICENSE = Full, against Webpack for xck26. A
#      runner with no licence server can build for xck26 and cannot build for
#      this, and the failure arrives at the end of synthesis.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

#### 1. IDENTITY ###############################################################

part_set part_name        xcku115-flvb1760-1-c
part_set family           kintexu
part_set family_full_name "Kintex UltraScale"
part_set device           xcku115
part_set package          flvb1760
part_set speed_grade      -1
part_set temp_grade       c
part_set vendor           xilinx
part_set idcode           0x0390d093
part_set license_class    Full

part_set min_vivado_version 2024.1
part_note {min_vivado_version is an OBSERVATION - 2024.1 is the oldest Vivado on
           this host in which these facts were read. 2021.1 is also installed
           here and was not queried. Not a vendor support statement.}

part_set facts_source \
    {Vivado v2024.1 (64-bit), SW Build 5076996 on 2024-05-22, read on
     2026-09-08 with: get_parts + list_property for the device properties;
     link_design -part <part> in memory with no project for the site, BEL and
     IO-bank census; create_cell -reference <prim> on that linked design for
     the primitive acceptance probe. No licence was needed and no design was
     built.}


#### 2. CAPACITY ###############################################################

part_set luts              663360
part_set ffs               1326720
part_set slices            82920         ;# CLBs
part_set brams             2160
part_set bram18s           4320
part_set dsps              5520          ;# DSP48E2
part_set urams             0             ;# no UltraRAM on Kintex UltraScale. Zero,
                                         ;# not unset - URAM288 is in
                                         ;# primitives_rejected below and a design
                                         ;# porting from xck26 needs both facts.
part_set clock_regions     60
part_set clock_region_grid X0Y0-X5Y9
part_set user_iobs         702
part_set gt_count          52            ;# GTHE3_TRANSCEIVERS = 52
part_set gt_primitive      GTHE3_CHANNEL

# ---- STACKED SILICON --------------------------------------------------------
part_set slrs                   2
part_set slr_topology           {SLR0 SLR1}
part_set slr_crossing_registers 5760

part_note {slr_topology is the SLR name list as the device enumerates them. The
           install gives the COUNT (get_slrs returns 2) and the names; which SLR
           carries the configuration master was NOT read and is not stated here.
           slr_crossing_registers is the LAGUNA_RX_REG0 BEL count - 5760 per
           register bank, and the census has six RX banks and six TX. It is the
           ceiling on how much a design may cross, and the number nobody looks
           up until a cross-SLR path will not close.}

part_set io_banks {0 44 45 46 47 48 49 50 51 52 53 65 66 67 84 94
                   128 131 132 133 224 225 226 227 228 230 231 232 233}
part_set io_bank_types {0   BT_NO_USER_IO
                        44  BT_HIGH_PERFORMANCE
                        45  BT_HIGH_PERFORMANCE
                        46  BT_HIGH_PERFORMANCE
                        47  BT_HIGH_PERFORMANCE
                        48  BT_HIGH_PERFORMANCE
                        49  BT_HIGH_PERFORMANCE
                        50  BT_HIGH_PERFORMANCE
                        51  BT_HIGH_PERFORMANCE
                        52  BT_HIGH_PERFORMANCE
                        53  BT_HIGH_PERFORMANCE
                        65  BT_HIGH_RANGE
                        66  BT_HIGH_PERFORMANCE
                        67  BT_HIGH_PERFORMANCE
                        84  BT_HIGH_RANGE
                        94  BT_HIGH_RANGE
                        128 BT_MGT
                        131 BT_MGT
                        132 BT_MGT
                        133 BT_MGT
                        224 BT_MGT
                        225 BT_MGT
                        226 BT_MGT
                        227 BT_MGT
                        228 BT_MGT
                        230 BT_MGT
                        231 BT_MGT
                        232 BT_MGT
                        233 BT_MGT}
part_note {Three of the 29 banks are BT_HIGH_RANGE (65, 84, 94) and the rest of
           the user banks are BT_HIGH_PERFORMANCE. HR and HP banks do not
           support the same IO standards or the same supply voltages, and the
           bank a signal lands in is a board fact - which is why this pack
           states the TYPE per bank and states nothing about which signal goes
           where.}

# has_ps is DELIBERATELY UNSET rather than set false: PS7 and PS8 are both in
# primitives_rejected, urams is 0 because zero is a measurable count, and "does
# this device have a processing system" is answered by the absence of a PS site
# in primitive_sites. Setting has_ps false would be correct and would also make
# the cascade for ps_type/ps_clk_config silently inapplicable, which is fine -
# it is left unset only because nothing here read a property called "has PS".
part_note {No processing system: the site census has no PS7 and no PS8, and both
           primitives are rejected. has_ps is left unset rather than set false -
           an unset key errors when read, which is a better answer than a false
           that a reader cannot distinguish from a default.}


#### 3. CLOCKING ###############################################################

part_set global_buffer         BUFGCTRL
part_set global_buffer_count   192
part_set clock_buffer_ce       BUFGCE      ;# 576 BUFGCE sites
part_set clock_buffer_ce_count 576
part_set clock_buffer_div      BUFGCE_DIV  ;# 96

part_set has_mmcm       true
part_set mmcm_primitive MMCME3_ADV
part_set mmcm_count     24
part_set pll_primitive  PLLE3_ADV
part_set pll_count      48

part_note {MMCME3_ADV and PLLE3_ADV - the UltraScale generation, NOT the
           UltraScale+ MMCME4_ADV/PLLE4_ADV, which are rejected here, and NOT
           the 7-series MMCME2_ADV/PLLE2_ADV, which are accepted here and
           silently retargeted. Three generations, and the only one that fails
           loudly is the one from the future.}


#### 4. IO #####################################################################

part_set io_buffer_primitive {IBUF OBUF OBUFT IOBUF IOBUFE3 IBUFDS IOBUFDS IOBUFDS_DCIEN}
part_set serdes_primitive    {ISERDESE3 OSERDESE3}

part_set idelay_available         true
part_set idelay_primitive         IDELAYE3
part_set idelay_control_primitive IDELAYCTRL
part_set idelay_count             1248
part_note {idelay_count is the RXTX_BITSLICE count: on UltraScale the input
           delay is a resource inside the bitslice rather than a site of its
           own, so counting IDELAYE3 sites returns zero and reads as "no
           IDELAY".}

# THE REFERENCE CLOCK. UltraScale, NOT UltraScale+: the legal band is
# 200-2400 MHz (IDELAYE3.v lines 319-320 in the UltraScale unisim), where
# UltraScale+ is 300-2667. The two overlap but neither contains the other, so a
# reference clock legal on one device can be illegal on the other - which is why
# this is stated per part rather than per family.
part_set idelay_ref_freq_range_hz {200000000 2400000000}

part_defer -permanent idelay_ref_freq_hz {
    error "no file in the Vivado install states a REQUIRED IDELAYCTRL reference
           frequency for this device. The install has the model's own range
           check (200-2400 MHz, in idelay_ref_freq_range_hz) and nothing else;
           IDELAYCTRL.v checks no frequency at all and only constrains
           SIM_DEVICE, which is ULTRASCALE here. Choose a frequency, check it
           against the range, and state it in the design."
}
part_defer -permanent idelay_ref_freq_default_hz {
    error "the census that produced this pack quotes IDELAYE3.v lines 319-320
           for the UltraScale legal RANGE but did not record the model's default
           REFCLK_FREQUENCY parameter for this architecture - it recorded the
           UltraScale+ default (300 MHz, IDELAYE3.v:37) and the 7-series default
           (200 MHz, IDELAYE2.v:36). Reading line 37 of the UltraScale IDELAYE3.v
           in the install would answer it. It is left deferred rather than
           assumed equal to either of the other two: the whole point of this key
           is what an UNPARAMETERISED instance silently uses, and a guess at it
           is worse than an error."
}


#### 5. PHYSICAL VERSUS ACCEPTED ###############################################
#
# Thirteen legacy names are accepted here and silently become something else.
# The expensive one is the same as on xck26 and lands somewhere different:
#
#   PLLE2_ADV -> MMCME3_ADV   Ask for a PLL, get an MMCM. This device has 48
#                             PLLs and 24 MMCMs, so once again the retarget
#                             spends the scarcer resource - and on the xck26
#                             pack the same primitive lands on MMCME4_ADV. A
#                             design moved between the two parts is silently
#                             retargeted to a DIFFERENT wrong cell each time.
#   BUFHCE    -> BUFGCTRL     The clock enable is gone.
#
# Measured with create_cell -reference <prim> on a linked design, Vivado v2024.1.

part_set primitives_retargeted {
    IDELAYE2    IDELAYE3
    ODELAYE2    ODELAYE3
    MMCME2_ADV  MMCME3_ADV
    MMCME2_BASE MMCME3_ADV
    PLLE2_ADV   MMCME3_ADV
    BUFG        BUFGCTRL
    BUFGMUX     BUFGCTRL
    BUFH        BUFGCTRL
    BUFHCE      BUFGCTRL
    BUFIO       BUFGCTRL
    RAMB36E1    RAMB36E2
    RAMB18E1    RAMB18E2
    DSP48E1     DSP48E2
}
part_note {ANOMALY, recorded not resolved, and identical to the one on xck26:
           create_cell -reference BUFGCE reports a retarget to BUFGCTRL while
           the device has 576 BUFGCE sites. The pack states the SITE as the
           physical primitive - listing BUFGCE as retargeted would make the
           validator reject the correct value of clock_buffer_ce - and records
           the create_cell observation here so neither measurement is lost.}

part_set primitives_rejected {
    MMCME4_ADV PLLE4_ADV BUFR BUFMR PS7 PS8
    URAM288 URAM288_BASE ISERDESE2 OSERDESE2
    SYSMONE4 XADC VCU
}

part_set bram_primitive   {RAMB36E2 RAMB18E2}
part_set dsp_primitive    DSP48E2
part_set sysmon_primitive SYSMONE1
# uram_primitive is unset: urams is 0 and URAM288 is rejected.

part_set primitive_sites {
    SLICEL         46200
    SLICEM         36720
    RAMBFIFO36     2160
    DSP48E2        5520
    MMCME3_ADV     24
    PLLE3_ADV      48
    BUFGCTRL       192
    BUFGCE         576
    BUFGCE_DIV     96
    BUFCE_LEAF_X16 1900
    HPIOB          1040
}
part_set primitive_bels {
    MMCME3_ADV_MMCM_TOP   24
    PLLE3_ADV_PLL_TOP     48
    BUFGCTRL_BUFGCTRL     192
    BUFGCE_DIV_BUFGCE_DIV 96
    BUFCE_BUFCE           576
    BUFCE_BUFCE_ROW       2628
    BUFCE_BUFCE_LEAF      30400
    BUFG_GT_BUFG_GT       384
    BUFG_GT_BUFG_GT_SYNC  176
    RXTX_BITSLICE         1248
    SYSMONE1_SYSMONE1     2
    LAGUNA_RX_REG0        5760
}
part_note {The two leaf-buffer numbers reconcile and are both kept: 1900
           BUFCE_LEAF_X16 SITES times 16 leaves each is the 30400
           BUFCE_BUFCE_LEAF BELs. A census that adds up is a census that was
           read; recording only one of the two would have hidden that.}
part_note {Unlike the xck26 pack, this device's MMCM and PLL SITE types carry
           the primitive name - MMCME3_ADV and PLLE3_ADV appear in both the site
           census and the primitive keys. On UltraScale+ they do not. Do not
           write anything that derives one from the other.}


#### 6. CONFIGURATION ##########################################################
#
# cfgbvs, config_voltage and bitstream_compress are left UNSET: the first two
# are decided by how bank 0 is wired on the board, the third is a build setting.
# Reading any of them errors and names the key. part/README.md section 5.

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
