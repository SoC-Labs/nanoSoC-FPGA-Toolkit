################################################################################
# part/xck26-sfvc784-2LV-c/part.tcl  --  THE PART PACK for xck26-sfvc784-2LV-c
#
# Zynq UltraScale+, XCK26, SFVC784 package, speed grade -2LV, commercial. A
# small UltraScale+ device with a full PS8, four GTH transceivers and no MGT
# fabric to speak of.
#
# EVERY VALUE HERE IS A SILICON FACT read from the Vivado install on 2026-09-08
# - see facts_source. Nothing is from a datasheet or from memory, and where the
# install does not state something this pack DEFERS the key with the reason.
#
# NOT IN HERE, EVER: a pin, an IO standard, a board name, a board voltage. This
# device is normally sold on a module which is then fitted to a carrier, and
# BOTH of those are boards: every fact about either lives in the PROJECT, in
# fpga/board/<board>/board.tcl. A vendor board file naming this part is the
# board pack's statement about which device is soldered down; it is not this
# file's statement about anything.
#
# THE ONE THING TO READ IF YOU READ NOTHING ELSE: section 6. Every legacy
# 7-series primitive name is ACCEPTED on this device and silently becomes
# something else, and one of them turns a PLL into an MMCM.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

#### 1. IDENTITY ###############################################################

part_set part_name        xck26-sfvc784-2LV-c
part_set family           zynquplus
part_set family_full_name "Zynq UltraScale+"
part_set device           xck26
part_set package          sfvc784
part_set speed_grade      -2LV
part_set temp_grade       c              ;# TEMPERATURE_GRADE_LETTER = C, and the
                                         ;# part string ends -c to match
part_set vendor           xilinx
part_set idcode           0x04a49093
part_set license_class    Webpack        ;# LICENSE = Webpack: this part builds on a
                                         ;# runner with no licence server, which is
                                         ;# why CI can run it and not xcku115

part_set min_vivado_version 2024.1
part_note {min_vivado_version is an OBSERVATION - 2024.1 is the oldest Vivado on
           this host in which these facts were read. Vivado 2021.1 is also
           installed here and was not queried. It is not a vendor support
           statement and must not be quoted as one.}

part_set facts_source \
    {Vivado v2024.1 (64-bit), SW Build 5076996 on 2024-05-22, read on
     2026-09-08 with: get_parts + list_property for the device properties;
     link_design -part <part> in memory with no project for the site, BEL and
     IO-bank census; create_cell -reference <prim> on that linked design for
     the primitive acceptance probe. No licence was needed and no design was
     built.}

part_note {MAX/MIN_OPERATING_TEMPERATURE read 85 and 0 degC, and
           MAX/MIN_OPERATING_VOLTAGE 0.742 and 0.698 V - the low-voltage core
           supply the LV in -2LV names. Recorded here because there is no
           schema key for an operating range and a reader comparing this part
           with a -2 needs to know the two are not interchangeable.}


#### 2. CAPACITY ###############################################################

part_set luts              117120
part_set ffs               234240
part_set slices            14640        ;# CLBs. Vivado reports them through the
                                        ;# same SLICES property as a 7-series part,
                                        ;# and a CLB is not a slice - eight LUTs
                                        ;# here against four there.
part_set brams             144
part_set bram18s           288
part_set dsps              1248         ;# DSP48E2
part_set urams             64           ;# UltraRAM. The 7-series packs read 0 here.
part_set clock_regions     12
part_set clock_region_grid X0Y0-X2Y3
part_set slrs              1
part_set user_iobs         189
part_set gt_count          4            ;# GB_TRANSCEIVERS = GTHE4_TRANSCEIVERS = 4
part_set gt_primitive      GTHE4_CHANNEL

part_note {The BEL census counts 16 GTHE4_CHANNEL BELs on the die while the part
           properties report 4 transceivers for this package. Both are recorded
           - primitive_bels has the 16 - and neither is corrected into the
           other: the die has more than the package bonds out, and a design is
           bounded by the 4.}

# EVERY BANK, PL and PS. Numbers are silicon; voltages are a PCB fact and live
# in the board pack.
part_set io_banks {0 43 44 45 46 64 65 66 224 500 501 502 503 504 505}
part_set io_bank_types {0   BT_NO_USER_IO
                        43  BT_HIGH_DENSITY
                        44  BT_HIGH_DENSITY
                        45  BT_HIGH_DENSITY
                        46  BT_NO_USER_IO
                        64  BT_HIGH_PERFORMANCE
                        65  BT_HIGH_PERFORMANCE
                        66  BT_HIGH_PERFORMANCE
                        224 BT_MGT
                        500 BT_PSS
                        501 BT_PSS
                        502 BT_PSS
                        503 BT_PSS
                        504 BT_PSS
                        505 BT_MGT}

# HD BANKS HAVE NO INPUT DELAY, and this is the most consequential line in the
# file. Banks 43, 44 and 45 are BT_HIGH_DENSITY, and HD banks carry no
# IDELAY/ISERDES IO logic - that lives in the HP banks (64, 65, 66) and in their
# RXTX_BITSLICE. A design that assigns a source-synchronous interface to an HD
# bank and then asks for an IDELAY does not get one.
#
# The pack states the bank TYPES. It does not state which bank any particular
# ribbon lands in, or what any project should do about it - that is a board
# fact and a design decision, and it belongs in the project's board pack and
# its XDC.
part_note {Banks 43/44/45 are BT_HIGH_DENSITY. HD banks carry no IDELAY: the
           input-delay resource on this device is in the HP banks' RXTX_BITSLICE.
           idelay_available below is true OF THE DEVICE; whether it is reachable
           from the bank a design uses is a question io_bank_types answers and
           this pack does not.}


#### 3. CLOCKING ###############################################################
#
# PHYSICAL PRIMITIVES ONLY. Every legacy name below is accepted here and means
# something else - see section 6 before changing any of these.

part_set global_buffer         BUFGCTRL
part_set global_buffer_count   32
part_set clock_buffer_ce       BUFGCE     ;# 96 BUFGCE SITES on this device. On the
                                          ;# 7-series pack this key is BUFHCE, and
                                          ;# BUFHCE here becomes a BUFGCTRL with no
                                          ;# clock enable at all.
part_set clock_buffer_ce_count 96
part_set clock_buffer_div      BUFGCE_DIV ;# 16. No 7-series equivalent.

part_set has_mmcm       true
part_set mmcm_primitive MMCME4_ADV
part_set mmcm_count     4
part_set pll_primitive  PLLE4_ADV
part_set pll_count      8

part_note {MMCM count 4, PLL count 8 - the MMCM is the SCARCER resource on this
           device, which is what makes the PLLE2_ADV retarget in section 6
           expensive rather than merely wrong: it spends one of four MMCMs while
           the design believes it is spending one of eight PLLs.}


#### 4. IO #####################################################################

part_set io_buffer_primitive {IBUF OBUF OBUFT IOBUF IOBUFE3 IBUFDS IOBUFDS IOBUFDS_DCIEN}
part_set serdes_primitive    {ISERDESE3 OSERDESE3}
part_note {ISERDESE2 and OSERDESE2 are REJECTED here, not retargeted - a design
           carrying them stops at elaboration, which is the good outcome. The E3
           pair is physically implemented inside RXTX_BITSLICE.}

part_set idelay_available         true
part_set idelay_primitive         IDELAYE3
part_set idelay_control_primitive IDELAYCTRL
part_set idelay_count             208
part_note {idelay_count is the RXTX_BITSLICE count: on UltraScale+ the input
           delay is not a site of its own, it is a resource inside the bitslice,
           and 208 is how many bitslices this device has. Counting "IDELAYE3
           sites" would return zero and read as "no IDELAY", which is why the
           number is the bitslice count and this note says so.}

# THE REFERENCE CLOCK. Three keys, three different questions - and this is the
# architecture where getting them confused is worst, because the 7-series
# folklore figure of 200 MHz is BELOW the legal minimum here.
#
#   range    IDELAYE3.v lines 313-314 in the UltraScale+ unisim: 300 to 2667 MHz,
#            ONE continuous band, unlike the three disjoint 7-series bands.
#   default  IDELAYE3.v line 37: REFCLK_FREQUENCY defaults to 300.0 MHz.
#   required deferred - see below.
part_set idelay_ref_freq_range_hz   {300000000 2667000000}
part_set idelay_ref_freq_default_hz 300000000

part_defer -permanent idelay_ref_freq_hz {
    error "no file in the Vivado install states a REQUIRED IDELAYCTRL reference
           frequency for this device. What the install has is the model's own
           range check (300-2667 MHz, in idelay_ref_freq_range_hz) and its
           default parameter (300 MHz). IDELAYCTRL.v checks no frequency at all;
           its only constrained parameter is SIM_DEVICE, which must be
           ULTRASCALE here and 7SERIES on the xc7z020 pack. NOTE that the
           7-series folklore figure of 200 MHz is OUTSIDE the legal range on
           this device: a design ported across and left at 200 MHz is asking for
           a reference clock the primitive rejects."
}


#### 5. PROCESSING SYSTEM ######################################################

part_set has_ps      true
part_set ps_type     PS8            ;# PS7 is REJECTED here and PS8 is rejected on
                                    ;# the 7-series part. The one part of this that
                                    ;# fails loudly.
part_set ps_io_banks {500 501 502 503 504}

part_defer -permanent ps_clk_config {
    error "how the PS8 presents clocks to the PL was not read from the install.
           No device property carries it, and answering it needs a PS8 IP
           elaboration (create_bd_cell zynq_ultra_ps_e and read its
           CONFIG.PSU__FPGA_PL*_ENABLE / PSU__CRL_APB__PL*_REF_CTRL__FREQMHZ),
           which is a Vivado run this pack has not made. A design taking
           SYS_CLK_FREQ_HZ from the PS states that frequency in its own board
           pack, where it is a board fact anyway."
}

part_note {The install reports 5 PS banks and one PS8 site. The PS8 core
           complement - 4x Cortex-A53 plus 2x Cortex-R5 - is correct and is NOT
           something any property in this install states, so it is written here
           in a note and not in a key.}


#### 6. PHYSICAL VERSUS ACCEPTED ###############################################
#
# THE REASON THIS PACK EXISTS, AND THIS IS THE DEVICE THAT PROVES IT.
#
# Sixteen legacy primitive names are ACCEPTED on this part. Every one of them
# prints a single [Coretcl 2-1024] warning and then silently becomes something
# else. Two of them are not renames at all:
#
#   PLLE2_ADV -> MMCME4_ADV   Ask for a PLL, get an MMCM. There are 8 PLLs and 4
#                             MMCMs on this device, so the design spends the
#                             scarcer resource and never touches the one it
#                             thought it was using.
#   BUFHCE    -> BUFGCTRL     Ask for a clock buffer WITH a clock enable, get one
#                             WITHOUT. The gating is gone. Nothing downstream
#                             reports a missing enable, because as far as the
#                             netlist is concerned there was never one.
#
# Measured with create_cell -reference <prim> on a linked design, Vivado v2024.1.

part_set primitives_retargeted {
    IDELAYE2    IDELAYE3
    ODELAYE2    ODELAYE3
    MMCME2_ADV  MMCME4_ADV
    MMCME2_BASE MMCME4_ADV
    MMCME3_ADV  MMCME4_ADV
    PLLE2_ADV   MMCME4_ADV
    PLLE3_ADV   PLLE4_ADV
    BUFG        BUFGCTRL
    BUFGMUX     BUFGCTRL
    BUFH        BUFGCTRL
    BUFHCE      BUFGCTRL
    BUFIO       BUFGCTRL
    RAMB36E1    RAMB36E2
    RAMB18E1    RAMB18E2
    DSP48E1     DSP48E2
    SYSMONE1    SYSMONE4
}

# BUFGCE IS NOT IN THAT LIST AND THE PROBE SAID IT SHOULD BE. Recorded here in
# full rather than smoothed over, because the two measurements disagree and the
# resolution matters:
#
#   create_cell -reference BUFGCE  ->  warning, retargeted to BUFGCTRL
#   get_sites -filter {SITE_TYPE == BUFGCE}  ->  96 sites
#
# A device with 96 BUFGCE sites has a physical BUFGCE. The retarget message
# describes Coretcl's netlist cell-type list for a linked design with no
# netlist, not the site census - and the site census is what "physical" means in
# this pack. So clock_buffer_ce is BUFGCE, the retarget observation is written
# down here, and neither measurement has been quietly dropped.
part_note {ANOMALY, recorded not resolved: create_cell -reference BUFGCE on a
           linked xck26 design reports a retarget to BUFGCTRL, yet the device
           has 96 BUFGCE sites (primitive_sites). The pack states the SITE as
           the physical primitive and does not list BUFGCE as retargeted -
           listing it would make the validator reject the correct value for
           clock_buffer_ce. The same anomaly appears on xcku115.}

part_set primitives_rejected {
    BUFR BUFMR PS7 ISERDESE2 OSERDESE2 XADC
}

part_set bram_primitive   {RAMB36E2 RAMB18E2}
part_set dsp_primitive    DSP48E2
part_set uram_primitive   URAM288
part_set sysmon_primitive SYSMONE4

# THE EVIDENCE for every "physical" above.
#
# Note what is NOT here: there is no MMCME4_ADV site type and no PLLE4_ADV site
# type. On UltraScale+ the site is called MMCM and PLL, and the PRIMITIVE the
# netlist names is MMCME4_ADV / PLLE4_ADV. A site type and a primitive name are
# not the same string, which is precisely why the pack states the primitive and
# records the census separately instead of deriving one from the other.
part_set primitive_sites {
    SLICEL     7440
    SLICEM     7200
    RAMBFIFO36 144
    DSP48E2    1248
    URAM288    64
    PS8        1
    BUFGCTRL   32
    BUFGCE     96
    BUFGCE_DIV 16
}
part_set primitive_bels {
    MMCM_MMCM_TOP             4
    PLL_PLL_TOP               8
    BUFGCTRL_BUFGCTRL         32
    BUFGCE_DIV_BUFGCE_DIV     16
    BUFCE_BUFCE               112
    BUFCE_BUFCE_ROW           388
    BUFCE_BUFCE_LEAF          5504
    BUFCE_BUFG_PS             96
    BUFG_GT_BUFG_GT           96
    BUFG_GT_BUFG_GT_SYNC      60
    RXTX_BITSLICE             208
    BITSLICE_CONTROL_BEL      32
    SYSMONE4_SYSMONE4         1
    GTHE4_CHANNEL_GTHE4_CHANNEL 16
    BEL_URAM288               64
}


#### 7. CONFIGURATION ##########################################################
#
# cfgbvs, config_voltage and bitstream_compress are left UNSET. The first two
# follow how bank 0 is wired on the carrier board, which a part pack cannot
# know; the third changes the file and not the silicon. Reading any of them
# errors and names the key. part/README.md section 5 has the argument.

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
