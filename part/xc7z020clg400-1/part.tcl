################################################################################
# part/xc7z020clg400-1/part.tcl  --  THE PART PACK for xc7z020clg400-1
#
# Zynq-7000, XC7Z020, CLG400 package, speed grade -1. A small Zynq-7000 device
# with a PS7, no transceivers and no UltraRAM.
#
# EVERY VALUE HERE IS A SILICON FACT, and every one of them was READ FROM THE
# VIVADO INSTALL on 2026-09-08 - see facts_source below. Nothing is from a
# datasheet, a wiki or memory. Where the install does not state something, this
# pack DEFERS the key with the reason rather than supplying a plausible number:
# a plausible number is indistinguishable from a measured one three months
# later, and this pack exists to be the thing that cannot be quietly wrong.
#
# NOT IN HERE, EVER: a pin number, an IO standard, a board name, a voltage the
# board supplies, an XDC path. Those are facts about a BOARD or about a design
# meeting a board; they live in the project, in fpga/board/<board>/board.tcl and
# fpga/targets/<target>/. The test is: would this still be true of a completely
# different board carrying this device? If no, it does not belong here.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

#### 1. IDENTITY ###############################################################

part_set part_name        xc7z020clg400-1
part_set family           zynq
part_set family_full_name "Zynq-7000"
part_set device           xc7z020
part_set package          clg400
part_set speed_grade      -1
part_set vendor           xilinx

# TEMPERATURE GRADE IS DELIBERATELY UNSET.
#
# TEMPERATURE_GRADE_LETTER on this part is BLANK - the property exists and its
# value is the empty string. That is not "commercial"; it is "this part string
# carries no grade letter", which is why the part string ends -1 and not -1c.
# Setting the key to "" would be a claim, and the validator rejects a blank
# string for exactly that reason. An unset key errors when read, which is the
# correct answer to "what grade is this part": ask a different question.
part_note {TEMPERATURE_GRADE_LETTER is blank in the install for this part. The
           key is left unset rather than set to "" or guessed as commercial:
           MIN/MAX_OPERATING_TEMPERATURE both read 0, which is not a range.}

part_set idcode 0x03727093
part_note {idcode is what a JTAG cable actually reads back, so it is the one
           fact in this pack that can prove the device on the bench is the one
           this bitstream was built for. fpgahub's programmer reports it.}

# THIS IS AN OBSERVATION, NOT A VENDOR SUPPORT STATEMENT. It is the oldest
# Vivado on this host in which the facts below were actually read. Vivado 2021.1
# is also installed here and was NOT queried - a query costs about 35 seconds
# per part and this pack does not spend one to produce a number it would then
# have to hedge. If you need to claim support further back, run the query and
# lower this, and say in a note which version you read.
part_set min_vivado_version 2024.1

part_set facts_source \
    {Vivado v2024.1 (64-bit), SW Build 5076996 on 2024-05-22, read on
     2026-09-08 with: get_parts + list_property for the device properties;
     link_design -part <part> in memory with no project for the site, BEL and
     IO-bank census; create_cell -reference <prim> on that linked design for
     the primitive acceptance probe. No licence was needed and no design was
     built.}

# The install's property list for this part carries NO LICENSE row, while both
# UltraScale parts carry one (Webpack, Full). An absent property is not the same
# as "no licence needed", so the key is deferred with what was actually seen
# rather than set to a value nobody read.
part_defer -permanent license_class {
    error "the install's list_property output for xc7z020clg400-1 carries no
           LICENSE property at all, though it does for xck26 (Webpack) and
           xcku115 (Full). Whether that means unrestricted or unreported was
           not established, and this pack will not decide it by inference."
}


#### 2. CAPACITY ###############################################################
#
# What a design is measured against. EXPECT_LUT_MAX and the rest of the
# utilisation gates in CONTRACT.md section 3.3 are budgets against these.

part_set luts              53200        ;# LUT_ELEMENTS
part_set ffs               106400       ;# FLIPFLOPS
part_set slices            13300        ;# SLICES
part_set brams             140          ;# BLOCK_RAMS, 36Kb
part_set bram18s           280          ;# RAMB18_* site census
part_set dsps              220          ;# DSP
part_set urams             0            ;# no UltraRAM on 7-series. Zero, not unset:
                                        ;# "this device has none" is an answer a
                                        ;# design needs, and an unset key cannot
                                        ;# give it.
part_set clock_regions     6
part_set clock_region_grid X0Y0-X1Y2
part_set slrs              1            ;# monolithic - no Laguna, no SLR floorplan
part_set user_iobs         125          ;# AVAILABLE_IOBS
part_set gt_count          0            ;# GB_TRANSCEIVERS. No transceivers at all,
                                        ;# so gt_primitive stays unset.

# EVERY BANK THE DEVICE HAS, PL and PS. Bank NUMBERS are silicon and belong
# here. Bank VOLTAGES are a PCB fact and belong in the board pack's
# io_voltage_by_bank - which is exactly the split that lets `make check` catch a
# board pack assigning a voltage to a bank this device does not have.
part_set io_banks      {0 13 34 35 500 501 502}
part_set io_bank_types {0   BT_NO_USER_IO
                        13  BT_HIGH_RANGE
                        34  BT_HIGH_RANGE
                        35  BT_HIGH_RANGE
                        500 BT_PSS
                        501 BT_PSS
                        502 BT_PSS}
part_note {The three PL banks here are BT_HIGH_RANGE - HR banks, which carry the
           IDELAY/ISERDES IO logic. That is not true of every device: xck26's
           HD banks do not, which is why io_bank_types is recorded rather than
           inferred from the family.}


#### 3. CLOCKING ###############################################################
#
# PHYSICAL PRIMITIVES ONLY. See section 6 for what that means and what it costs
# to get wrong.

part_set global_buffer        BUFGCTRL
part_set global_buffer_count  32
part_set clock_buffer_ce      BUFHCE      ;# the 7-series horizontal clock buffer
part_set clock_buffer_ce_count 72

# clock_buffer_div IS DELIBERATELY UNSET. There is no BUFGCE_DIV on 7-series -
# create_cell rejects it outright - so a divided clock here costs an MMCM or PLL
# output instead of a buffer. A design ported from UltraScale that assumes a
# dividing buffer exists will find out from this key erroring, which is the
# point: an empty string would have been passed to the tool as a cell name.
part_note {No BUFGCE_DIV on this architecture: a divided clock costs an MMCM or
           PLL output. BUFR (16) and BUFMRCE (8) exist and BUFIO (16) exists;
           they are 7-series-only regional clocking resources with no
           UltraScale equivalent, recorded in primitive_bels.}

part_set has_mmcm        true
part_set mmcm_primitive  MMCME2_ADV
part_set mmcm_count      4
part_set pll_primitive   PLLE2_ADV
part_set pll_count       4


#### 4. IO #####################################################################

part_set io_buffer_primitive {IBUF OBUF OBUFT IOBUF IBUFDS IOBUFDS IOBUFDS_DCIEN}
part_note {IOBUFE3 is REJECTED on this architecture, not retargeted - it is in
           primitives_rejected. That is the good failure: a design ported back
           from UltraScale stops at elaboration instead of silently losing the
           DCI enable.}

part_set serdes_primitive {ISERDESE2 OSERDESE2}

part_set idelay_available        true
part_set idelay_primitive        IDELAYE2
part_set idelay_control_primitive IDELAYCTRL
part_set idelay_count            200          ;# IDELAYE2 sites; 4 IDELAYCTRL

# THE REFERENCE CLOCK. Read the three keys together, because they answer three
# different questions and the folklore answer conflates them.
#
#   idelay_ref_freq_range_hz    what the primitive's own model will ACCEPT
#   idelay_ref_freq_default_hz  what an unparameterised instance SILENTLY USES
#   idelay_ref_freq_hz          what this device REQUIRES  <- deferred, see below
#
# The ranges are the model's own check, from the unisim source shipped with the
# install: IDELAYE2.v lines 250-255 accept 190-210, 290-310 or 390-410 MHz and
# nothing else. Three DISJOINT bands, which is why this key is a list of pairs
# and not two numbers - a single min/max would admit 250 MHz, which the model
# rejects. The tap delay the primitive computes depends on which band you are
# in (IDELAYE2.v:278-288: 39 ps in the 390-410 band, 52 in 290-310, else 78),
# so the band is not a formality.
part_set idelay_ref_freq_range_hz   {190000000 210000000
                                     290000000 310000000
                                     390000000 410000000}
part_set idelay_ref_freq_default_hz 200000000    ;# IDELAYE2.v:36, REFCLK_FREQUENCY

# "IDELAYCTRL REFCLK must be 200 MHz" is the most repeated sentence about this
# primitive and NOTHING IN THE INSTALL SAYS IT. What the install has is the
# range check above and a default parameter; IDELAYCTRL.v itself has no
# frequency check at all - its only constrained parameter is SIM_DEVICE, which
# takes "7SERIES" or "ULTRASCALE". So the required figure is deferred rather
# than restated: 200 MHz is inside the legal band and is the model default, and
# neither of those makes it a requirement.
part_defer -permanent idelay_ref_freq_hz {
    error "no file in the Vivado install states a REQUIRED IDELAYCTRL reference
           frequency for this device. IDELAYE2.v gives legal ranges (recorded in
           idelay_ref_freq_range_hz) and a 200 MHz default (recorded in
           idelay_ref_freq_default_hz); IDELAYCTRL.v checks no frequency at all.
           The widely repeated '200 MHz' figure is folklore that happens to sit
           in a legal band. Pick a frequency, check it against
           idelay_ref_freq_range_hz, and state it in the DESIGN - it is a design
           decision, not a property of the silicon."
}


#### 5. PROCESSING SYSTEM ######################################################

part_set has_ps      true
part_set ps_type     PS7
part_set ps_io_banks {500 501 502}

# ps_clk_config IS DEFERRED, and the cascade in pack_api.tcl makes it required
# the moment has_ps is true - which is correct, and this is what the honest
# answer looks like when the number was not read.
part_defer -permanent ps_clk_config {
    error "how the PS7 presents clocks to the PL was not read from the install.
           The device property list carries no such property, and answering it
           needs a PS7 IP elaboration (create_bd_cell processing_system7 and
           read its CONFIG.PCW_FCLK_CLK*), which is a Vivado run this pack has
           not made. Until it is made, a design taking SYS_CLK_FREQ_HZ from the
           PS must state that frequency in its own board pack, where it is
           anyway a board fact."
}

part_note {The install reports 3 PS banks (500, 501, 502) and one PS7 site. It
           does NOT report the Cortex-A9 core count - no property carries it -
           so this pack does not state it. Two cores is correct for XC7Z020 and
           it is still not something this file read.}


#### 6. PHYSICAL VERSUS ACCEPTED ###############################################
#
# THE REASON THIS PACK EXISTS.
#
# On THIS architecture the retarget list is short - three entries - and that is
# itself the fact worth knowing: 7-series is the architecture whose primitive
# names everybody writes, so almost nothing needs retargeting here and almost
# everything does on UltraScale(+). A design written against this pack and moved
# to xck26 keeps compiling and stops meaning the same thing.
#
# Measured with create_cell -reference <prim> on a linked design, Vivado
# v2024.1. A retarget prints one [Coretcl 2-1024] warning; a rejection is
# [Coretcl 2-1475] "not supported in the current architecture".

part_set primitives_retargeted {
    MMCME2_BASE MMCME2_ADV
    BUFGCE      BUFGCTRL
    BUFGMUX     BUFGCTRL
}
part_note {BUFGCE retargets to BUFGCTRL HERE and is physical on both UltraScale
           parts in this toolkit. That is the whole trap in one line: the same
           source, the same primitive name, a clock enable on one device and no
           clock enable on the other, one warning either way.}

part_set primitives_rejected {
    IDELAYE3 ODELAYE3 MMCME3_ADV MMCME4_ADV PLLE3_ADV PLLE4_ADV
    BUFGCE_DIV BUFG_GT BUFG_GT_SYNC IOBUFE3 PS8
    RAMB36E2 RAMB18E2 URAM288 URAM288_BASE DSP48E2
    ISERDESE3 OSERDESE3 SYSMONE1 SYSMONE4 VCU
    BITSLICE_CONTROL RX_BITSLICE
}

part_note {BUFG and BUFH are ACCEPTED here with no retarget warning, and neither
           has a BEL of its own - the census has BUFGCTRL and BUFHCE. They are
           not listed as retargeted because no retarget was MEASURED; the probe
           saw them succeed silently. Recorded rather than resolved: use
           BUFGCTRL and BUFHCE, which are the sites.}

part_set bram_primitive   {RAMB36E1 RAMB18E1}
part_set dsp_primitive    DSP48E1
part_set sysmon_primitive XADC
# uram_primitive is unset. There is no UltraRAM here and urams is 0.

# THE EVIDENCE. A census, not a claim - this is what "physical" means above.
part_set primitive_sites {
    SLICEL     8950
    SLICEM     4350
    DSP48E1    220
    PS7        1
    MMCME2_ADV 4
    PLLE2_ADV  4
    BUFGCTRL   32
    BUFHCE     72
    IDELAYCTRL 4
    IDELAYE2   200
    IOB33      8
}
part_set primitive_bels {
    BUFGCTRL_BUFGCTRL       32
    BUFHCE_BUFHCE           72
    BUFIO_BUFIO             16
    BUFR_BUFR               16
    BUFMRCE_BUFMRCE         8
    MMCME2_ADV_MMCME2_ADV   4
    PLLE2_ADV_PLLE2_ADV     4
    IDELAYE2_IDELAYE2       200
    IDELAYCTRL_IDELAYCTRL   4
    DSP48E1_DSP48E1         220
    RAMB18E1_RAMB18E1       140
    RAMBFIFO36E1_RAMBFIFO36E1 140
    PS7_PS7                 1
    XADC_XADC               1
}


#### 7. CONFIGURATION ##########################################################
#
# cfgbvs, config_voltage and bitstream_compress are registered in the schema
# because CONTRACT.md section 8 lists them as part-pack keys, and they are LEFT
# UNSET here on purpose:
#
#   cfgbvs / config_voltage  follow how bank 0 is WIRED ON THE BOARD. This
#                            device supports 3.3 V and 1.8 V bank-0 supplies;
#                            which one is in front of you is a PCB fact, and a
#                            part pack stating it would be stating something it
#                            cannot know.
#   bitstream_compress       changes the FILE, not the silicon. It is a build
#                            setting and belongs to the project.
#
# Reading any of the three errors and names the key, which is a better outcome
# than reading a default somebody assumed. part/README.md section 5 argues this
# at length; it is the one place this pack knowingly declines to fill in a key
# the contract offers.

# Copyright (C) 2026, SoC Labs (www.soclabs.org)
