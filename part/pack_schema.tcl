################################################################################
# part/pack_schema.tcl - WHAT a pack may declare. Not HOW any of it is read.
#
# Sourced by part/pack_api.tcl, which owns the load order. NOTHING ELSE SHOULD
# SOURCE THIS FILE: on its own it defines tables and no way to use them, and a
# consumer that got the tables without the accessors would read them directly -
# which is the coupling the accessors exist to prevent.
#
# WHY IT IS A SEPARATE FILE. It is 500-odd lines of declarative rows with no
# control flow at all, and it answers the question a pack author actually
# arrives with - "what keys are there, which are required, and what does this
# one mean?" - which was previously answered a quarter of the way down a
# 2091-line file whose other two thirds were a loader, a validator and two
# cross-checkers. Splitting data from code costs one `source` and makes the
# schema greppable as itself.
#
# It is a FILE, not a directory, so neither pack lister offers it as a pack:
# pack_installed globs `-type d` and fpga-flow-init's part_packs tests `-d`.
# Both filter by shape rather than by a list of names to keep in step.
#
# Copyright (C) 2026, SoC Labs (www.soclabs.org)
################################################################################

################################################################################
# 1. THE SCHEMA TABLES
#
# One row per key: KEY  REQUIRED  TYPE  GROUP  {DESCRIPTION}
#
#   REQUIRED  yes   the pack must set it; absence is a validation failure
#             no    optional; ask with <role>_has or <role>_opt
#             cond  required only under a cascade in section 1b, which states
#                   its own reason when it fires
#
#   TYPE      str   one non-empty word or phrase
#             int   integer
#             num   integer or real
#             bool  0/1/true/false
#             list  one or more elements
#             path  one filesystem path, existence checked by <role>_check_files
#             paths one or more filesystem paths, likewise
#
# The DESCRIPTION is not decoration. It is what the validator prints when the
# key is missing, so it must say what the value is FOR - a reader who has never
# built a bitstream has only that sentence to go on.
################################################################################

#### 1a. THE PART ROLE #########################################################
#
# EVERY VALUE IN A PART PACK IS A SILICON FACT. The test: would it still be true
# of a completely different board carrying this device? A pin number, an IO
# STANDARD and a board name all fail that test and none of them may appear
# anywhere under part/ - they are facts about a board, or about a design meeting
# a board, and CONTRACT.md section 1 puts them in the project.
#
# THE DISTINCTION THIS TABLE EXISTS FOR is physical versus accepted. Vivado
# RETARGETS legacy 7-series primitives on UltraScale and UltraScale+: ask for an
# MMCME2_ADV on a zynquplus part and you get an MMCME4_ADV, with a warning
# ([Coretcl 2-1024]) in a log nobody reads. Ask for a PLLE2_ADV and you do not
# even get a PLL - measured on xck26, it retargets to MMCME4_ADV, so a design
# that thinks it is using one of eight PLLs is competing for one of four MMCMs.
# A pack therefore states the PHYSICAL primitive - the one with a real site or
# BEL - in every *_primitive key, and lists what is merely accepted in
# primitives_retargeted. Section 6 is the cross-check that makes the two
# statements answer to each other.

set ::pack_schema_spec(part) {

    ## --- identity -----------------------------------------------------------
    part_name             yes str   identity
        {The FULL Vivado part string - device, package, speed grade and, where
         the device has one, temperature grade. Not the bare device. A part
         string missing its speed grade selects a different part or none, and
         "none" surfaces as an elaboration failure several minutes in.}
    family                yes str   identity
        {Architecture as Vivado's ARCHITECTURE property spells it, e.g. zynq,
         zynquplus, kintexu. This is the key that decides which primitives are
         physical, so it is required and it is spelled the tool's way.}
    family_full_name      no  str   identity
        {ARCHITECTURE_FULL_NAME, e.g. Zynq UltraScale+. For humans and reports;
         nothing branches on it.}
    device                yes str   identity
        {The bare device, e.g. xc7z020. Reports group by this, and two boards
         carrying the same device in different packages share it.}
    package               yes str   identity
        {Package code, e.g. clg400, sfvc784. Decides the pinout, so a board pack
         naming a part with a different package is naming a different board.}
    speed_grade           yes str   identity
        {Speed grade as it appears in the part string, leading dash included,
         e.g. -1, -2LV. Timing closure is a statement about this and nothing
         else; a report that does not carry it cannot be compared with another.}
    temp_grade            no  str   identity
        {Temperature grade letter, e.g. c for commercial 0-85C. UNSET, never
         "", on a device whose part string carries none - an empty grade and a
         commercial grade are different claims.}
    vendor                yes str   identity
        {Who makes it. xilinx for everything here; the key exists so a report
         does not have to infer it from a part string.}
    idcode                no  str   identity
        {JTAG IDCODE as the install states it, e.g. 0x03727093. This is what a
         cable actually reads back, so it is the one fact that can prove the
         board on the bench is the device this bitstream was built for.}
    license_class         no  str   identity
        {The tool licence the part needs - Webpack, Full. A part that needs a
         full licence cannot be built on a Webpack-only runner, and the failure
         arrives at the end of synthesis rather than at the start.}
    min_vivado_version    yes str   identity
        {The oldest Vivado this pack's facts are known to hold for. It is an
         OBSERVATION, not a vendor support statement: a pack states the oldest
         version it was actually read from, and says so in a note. VIVADO_VER in
         design.mk is asserted against the host; this is asserted against the
         pack.}
    facts_source          no  str   identity
        {How the numbers in this pack were obtained, precisely enough to repeat:
         the tool and build, the commands, and the date. A pack whose provenance
         is "somebody typed them" is a pack nobody can re-check.}

    ## --- capacity -----------------------------------------------------------
    #
    # These bound a design. They are what EXPECT_LUT_MAX and friends are a
    # percentage OF, and what a utilisation gate reports against.
    luts                  no  int   capacity
        {LUT_ELEMENTS: usable LUTs in the fabric. NOT slices and NOT CLBs.}
    ffs                   no  int   capacity
        {FLIPFLOPS: fabric registers.}
    slices                no  int   capacity
        {SLICES on a 7-series part, CLBs on UltraScale(+) - Vivado reports both
         through the same property. Placement pressure is a statement about
         these, not about LUT count.}
    brams                 no  int   capacity
        {BLOCK_RAMS: 36Kb block RAMs. The unit a utilisation report counts.}
    bram18s               no  int   capacity
        {18Kb halves - twice brams on every architecture here. Recorded because
         inference reports in 18Kb units and the two numbers are routinely
         compared without noticing they have different denominators.}
    dsps                  no  int   capacity
        {DSP slices.}
    urams                 no  int   capacity
        {UltraRAM blocks. Zero, not unset, on a device that has none: "this
         device has no URAM" is an answer a design needs, and an unset key
         cannot give it.}
    clock_regions         no  int   capacity
        {Clock regions. The unit clock routing is budgeted in: a design needing
         more clock tracks than a region has fails placement with a message
         about the region, and this is the number that message is against.}
    clock_region_grid     no  str   capacity
        {The grid as coordinates, e.g. X0Y0-X2Y3. Reading a placement message
         that names X2Y3 needs to know whether that is the corner or the middle.}
    slrs                  no  int   capacity
        {Super logic regions. 1 on a monolithic device. Above 1 the device is
         stacked silicon and every path that crosses needs a Laguna register;
         see slr_topology, which this makes required.}
    slr_topology          cond list capacity
        {The SLRs in the order the device enumerates them. Required when slrs is
         above 1, because on a stacked device the FLOORPLAN is part of timing
         closure and a report that says "SLR1" means nothing without the list.}
    slr_crossing_registers no int   capacity
        {Laguna crossing registers PER REGISTER BANK. This is the hard ceiling
         on how much a design may cross between SLRs, and the number nobody
         looks up until a cross-SLR path will not close.}
    io_banks              no  list  capacity
        {Every IO bank number the device has, PL and PS. Bank NUMBERS are
         silicon; bank VOLTAGES are a board fact and live in the board pack's
         io_voltage_by_bank. Keeping the numbers here is what lets `make check`
         catch a board pack assigning a voltage to a bank the device lacks.}
    io_bank_types         no  list  capacity
        {{bank type} pairs as the install reports them - BT_HIGH_RANGE,
         BT_HIGH_PERFORMANCE, BT_HIGH_DENSITY, BT_PSS, BT_MGT, BT_NO_USER_IO.
         The type is what decides whether an IO feature exists in that bank at
         all: HD banks have no IDELAY, which is a silicon fact with immediate
         consequences for a design that assumed one.}
    user_iobs             no  int   capacity
        {AVAILABLE_IOBS: user IO the fabric can reach.}
    gt_count              no  int   capacity
        {Gigabit transceivers. Zero, not unset, when there are none.}
    gt_primitive          no  str   capacity
        {The transceiver primitive, e.g. GTHE4_CHANNEL. Generations are not
         interchangeable and a GT wizard configured for the wrong one produces
         a core that will not place.}

    ## --- clocking -----------------------------------------------------------
    #
    # PHYSICAL primitives only. See the header of this table.
    global_buffer         yes str   clocking
        {The global clock buffer that physically exists, e.g. BUFGCTRL. Required
         because every clock in the design goes through one and a wrong name
         here is a clock that is routed on fabric.}
    global_buffer_count   no  int   clocking
        {How many of them the device has. The ceiling on distinct global clocks,
         and the number a "no more global clock resources" placement error is
         measured against.}
    clock_buffer_ce       no  str   clocking
        {The physical clock buffer WITH a clock enable, e.g. BUFHCE on 7-series,
         BUFGCE on UltraScale(+). Naming the wrong one is the classic retarget
         trap: BUFHCE is accepted on UltraScale+ and silently becomes a
         BUFGCTRL, which has no CE, so the gating the design asked for is gone.}
    clock_buffer_ce_count no  int   clocking
        {How many.}
    clock_buffer_div      no  str   clocking
        {The physical dividing clock buffer, e.g. BUFGCE_DIV. Absent on
         7-series, where a divided clock costs an MMCM output instead.}
    has_mmcm              no  bool  clocking
        {True when the device has an MMCM. Makes mmcm_primitive required,
         because "there is an MMCM" is useless without which one.}
    mmcm_primitive        cond str  clocking
        {The PHYSICAL MMCM primitive - MMCME2_ADV on 7-series, MMCME3_ADV on
         UltraScale, MMCME4_ADV on UltraScale+. The legacy names are ACCEPTED
         everywhere and retargeted silently, which is exactly why this key is
         stated rather than inferred.}
    mmcm_count            no  int   clocking
        {How many MMCMs. Half a clocking wizard's failures are this number.}
    pll_primitive         no  str   clocking
        {The PHYSICAL PLL primitive - PLLE2_ADV, PLLE3_ADV, PLLE4_ADV. MEASURED
         TRAP: on xck26 and xcku115 a legacy PLLE2_ADV does not retarget to the
         local PLL, it retargets to the MMCM. A design that believes it is
         spending a PLL is spending an MMCM, and MMCMs are the scarcer of the
         two on both parts.}
    pll_count             no  int   clocking
        {How many PLLs.}

    ## --- IO -----------------------------------------------------------------
    io_buffer_primitive   no  list  clocking
        {The IO buffer primitives this architecture instantiates physically, in
         no particular order. IOBUFE3 is the one that moves: rejected outright
         on 7-series, physical on UltraScale(+).}
    serdes_primitive      no  list  clocking
        {The physical SERDES primitives, e.g. ISERDESE2/OSERDESE2 on 7-series,
         ISERDESE3/OSERDESE3 on UltraScale(+). The E2 pair is REJECTED on
         UltraScale(+), not retargeted - which is the good outcome, because it
         fails at elaboration instead of silently.}
    idelay_available      no  bool  io
        {True when the device has an input delay primitive at all. Makes the
         three idelay_* keys below required: an IDELAY that exists but whose
         reference clock nobody stated is a design that calibrates against a
         frequency it guessed.}
    idelay_primitive      cond str  io
        {The PHYSICAL input delay primitive - IDELAYE2 on 7-series, IDELAYE3 on
         UltraScale(+). IDELAYE2 is ACCEPTED on UltraScale(+) and retargeted to
         IDELAYE3, whose tap semantics and reference-clock range are different.}
    idelay_control_primitive no str io
        {The delay controller, IDELAYCTRL. Its SIM_DEVICE parameter takes only
         "7SERIES" or "ULTRASCALE", so a design that instantiates one has to
         know which architecture it is on.}
    idelay_count          no  int   io
        {How many input delay elements the device physically has.}
    idelay_ref_freq_hz    cond int  io
        {The reference clock IDELAYCTRL must be driven at ON THIS DEVICE, in Hz.
         Required when idelay_available is true. A pack that cannot read this
         off the install DEFERS it with the reason rather than restating the
         folklore figure - 200 MHz is right for 7-series and wrong for
         UltraScale+, and no installed file states it as a requirement at all.}
    idelay_ref_freq_range_hz cond list io
        {The LEGAL reference-clock range(s), as {min max} pairs in Hz, read from
         the unisim model's own range check. This is the fact the install
         actually carries, and it is a range because on 7-series it is three
         disjoint bands, not one. Required alongside idelay_ref_freq_hz so that
         a design choosing its own reference clock has something to check
         against even where the exact figure is deferred.}
    idelay_ref_freq_default_hz no int io
        {The unisim model's DEFAULT REFCLK_FREQUENCY. Recorded because it is
         what an unparameterised instantiation silently uses, which is a
         different question from what is legal and from what is required.}

    ## --- processing system --------------------------------------------------
    has_ps                no  bool  ps
        {True on a device with a hard processing system. Makes ps_type and
         ps_clk_config required.}
    ps_type               cond str  ps
        {The PS primitive - PS7 on Zynq-7000, PS8 on Zynq UltraScale+. They are
         REJECTED on each other's architecture, which is the one part of this
         that fails loudly.}
    ps_clk_config         cond str  ps
        {How the PS supplies clocks to the fabric - the PL clock ports it
         presents and any constraint on them. This is what decides whether
         SYS_CLK_FREQ_HZ can come from the PS at all, and it is the difference
         between a board that boots and one whose every baud rate is wrong.}
    ps_io_banks           no  list  ps
        {The PS-dedicated IO banks. Listed separately from io_banks because a
         constraint that assigns a PL signal to one of these is rejected, and
         the message does not say why.}

    ## --- the physical / accepted distinction --------------------------------
    #
    # THE REASON THIS PACK EXISTS. See section 6.
    primitives_retargeted no  list  primitives
        {{requested actual} PAIRS: primitives Vivado ACCEPTS on this device by
         silently retargeting them to something else, measured with create_cell
         on a linked design. These names have no site or BEL of their own here.
         Listing them is what lets the validator refuse a pack that names one in
         a *_primitive key - the single silent defect this pack exists to stop.}
    primitives_rejected   no  list  primitives
        {Primitives this architecture REJECTS outright, with [Coretcl 2-1475].
         The benign case: it fails at elaboration. Listed so a *_primitive key
         naming one is caught here rather than there, and so a design porting
         between parts can see what it must replace.}
    primitive_sites       no  list  primitives
        {{SITE_TYPE count} pairs from the device's own site census - the
         EVIDENCE that a primitive is physical rather than accepted. Note that a
         site type and a primitive name are not always spelled the same on
         UltraScale+: the MMCM site is not called MMCME4_ADV. That is why this
         is a recorded census and not a cross-check.}
    primitive_bels        no  list  primitives
        {{BEL_TYPE count} pairs from the BEL census, for the primitives whose
         site type does not carry their name. Same purpose: evidence.}
    bram_primitive        no  list  primitives
        {Physical block-RAM primitives, e.g. RAMB36E1/RAMB18E1. The E1 pair is
         accepted on UltraScale(+) and retargeted to E2, which has different
         cascade and ECC behaviour.}
    dsp_primitive         no  str   primitives
        {Physical DSP primitive - DSP48E1 or DSP48E2.}
    uram_primitive        no  str   primitives
        {Physical UltraRAM primitive. Unset on a device with no URAM.}
    sysmon_primitive      no  str   primitives
        {Physical system monitor - XADC, SYSMONE1, SYSMONE4. All three are
         rejected on each other's architecture.}

    ## --- configuration ------------------------------------------------------
    #
    # cfgbvs and config_voltage USED TO BE HERE and are now BOARD keys. Both
    # follow how bank 0 is WIRED, which is a fact about a PCB, not about a die.
    # CONTRACT.md section 8 was corrected on 2026-09-08 and this table was not,
    # which left them registered in the part role and absent from the board
    # role - and because an unknown key is a hard error, the consequence was
    # that NOTHING COULD STATE THEM AT ALL. All three shipped packs had already
    # declined to set them, so the gap was invisible until a board pack tried.
    # Moved 2026-09-08. part/README.md section 5 made the same argument first.
    bitstream_compress    no  bool  config
        {Whether to write a compressed bitstream. A build SETTING, not a device
         fact - it changes the file, not the silicon. Left unset here.}
}

#### 1b. THE BOARD ROLE ########################################################
#
# The mirror image: everything here is a fact about a PCB. If it would still be
# true with the board in a drawer and no design in sight, it belongs here.

set ::pack_schema_spec(board) {

    ## --- identity -----------------------------------------------------------
    board_name            yes str   identity
        {The board's name as this project spells it. It must match the directory
         holding this file, which is what BOARD in design.mk selects.}
    part                  yes str   identity
        {The FULL Vivado part string of the device soldered to this board. This
         is the normal place for the part to be stated; a PART override in
         design.mk wins over it, and the engine announces the divergence every
         run because a legitimate override and a stale one look identical.}
    platform              yes str   identity
        {What runs on the board once it is programmed: bare or pynq. Must agree
         with PLATFORM in design.mk, and `make check` compares them.}
    board_rev             no  str   identity
        {The board revision this pack describes. Two revisions of one board are
         two boards whenever a net moved, and the only thing that says which one
         a bitstream was built for is this.}

    ## --- clocking -----------------------------------------------------------
    sys_clk_freq_hz       yes int   clocking
        {The system clock in Hz, as an integer - the clock the design is closed
         at. NOT the oscillator; see oscillator_hz. It is compiled into the
         firmware AND constrains the fabric, so a build where the two disagree
         boots and gets every baud rate and timer wrong. That is why it is
         required rather than something a design mentions in passing.}
    oscillator_hz         no  int   clocking
        {The crystal or clock generator ON THE PCB, in Hz - the number from the
         schematic. Recorded beside sys_clk_freq_hz so a reader can see the
         ratio and check it against the MMCM settings.}

    ## --- programming and deployment -----------------------------------------
    bin_style             yes str   deploy
        {How a .bin is made for this family: zynq7 (byte swap) or zynqmp (header
         strip). THEY ARE NOT INTERCHANGEABLE AND THE WRONG ONE CORRUPTS THE
         LOAD - the conversion succeeds, the file is the right size, the loader
         accepts it, the device does not come up and nothing says why. Required
         because guessing it from the part string is the kind of inference that
         is right until it is not.}
    deploy_style          no  str   deploy
        {How this board is normally loaded: jtag, qspi, sd, tftp.}
    jtag_serial           no  str   deploy
        {The JTAG cable's serial number, when the bench has more than one board.
         Without it the tool takes whichever enumerated first, and the symptom
         is a bitstream landing on somebody else's board.}
    fpgahub_board         no  str   deploy
        {The board GROUP - the LEASE scope. Leases, queues and reservations
         address this name. Setting it makes fpgahub_target required.}
    fpgahub_target        cond str  deploy
        {The TARGET - the PROGRAM scope. Program, reset and actions address this
         one. IT IS A DIFFERENT NAMESPACE from fpgahub_board and the two do not
         overlap: using either where the other is expected returns 404, and
         neither 404 says which of the two was wrong.}

    ## --- vendor board files -------------------------------------------------
    board_part            no  str   vendor
        {The vendor board VLNV, e.g. vendor:board:part0:1.1. Setting it makes
         board_repo_paths required.}
    board_repo_paths      cond paths vendor
        {Directories holding the board files that VLNV resolves against.
         Required whenever board_part is set: without it Vivado resolves the
         VLNV against whatever is installed on THIS machine, which is a build
         dependency nobody wrote down. It works until CI runs it.}

    ## --- the board itself ---------------------------------------------------
    io_voltage_by_bank    no  list  board
        {{bank volts} pairs: what the BOARD supplies to each bank. The target's
         XDC states an IOSTANDARD per port; this states what the board can
         actually drive, so a mismatch is catchable before the bitstream rather
         than with a scope.}
    cfgbvs                no  str   config
        {CFGBVS: VCCO or GND. It states how config bank 0 is WIRED on this
         board, which is why it is a board key and not a part key. Wrong or
         unset, the DRC that checks it (CFGBVS-1) is only a WARNING, so the
         symptom is a warning nobody can clear rather than a failure.}
    config_voltage        no  num   config
        {CONFIG_VOLTAGE in volts - the bank 0 supply on this board. Stated
         together with cfgbvs or not at all; one without the other describes
         half a decision.}
    connectors            no  list  board
        {{name description} pairs. Free-form and for humans: the note that stops
         the next person tracing a header with a multimeter.}
}

#### 1c. CONDITIONAL CASCADES ##################################################
#
# Rows of {TRIGGER-KEY OP {KEYS IT THEN REQUIRES} {WHY}}.
#
#   OP  set    the trigger key is present
#       true   the trigger key is present and boolean-true
#       >N     the trigger key is present and numerically greater than N
#
# DECLARATIVE ON PURPOSE. Written as `if` statements these become four
# indistinguishable blocks that each grow a special case; as a table they are
# reviewable in one screen and a new cascade is a row. The WHY is printed when
# the cascade fires, so a reader learns the rule rather than just that they
# broke it - and each required key's own description is printed with it.

set ::pack_cascade_spec(part) {
    {has_ps true {ps_type ps_clk_config}
        {The pack says this device has a hard processing system. Which one it is
         and how it clocks the fabric are then not optional: PS7 and PS8 are
         rejected on each other's architecture, and a design that takes its
         system clock from the PS cannot be constrained without knowing what the
         PS presents.}}
    {idelay_available true {idelay_primitive idelay_ref_freq_hz idelay_ref_freq_range_hz}
        {The pack says this device has an input delay element. An IDELAY is
         calibrated against a reference clock, so a design using one against a
         frequency nobody stated is a design that samples at a delay it did not
         choose. The primitive matters just as much: IDELAYE2 and IDELAYE3 have
         different tap counts and different legal reference ranges, and the
         legacy name is silently accepted on the architecture that has the other
         one.}}
    {slrs >1 {slr_topology}
        {The pack says this is stacked silicon. Every path crossing between SLRs
         needs a Laguna register and every report that names an SLR needs the
         list to be read against. On a stacked device the floorplan is part of
         timing closure, not a tuning step after it.}}
    {has_mmcm true {mmcm_primitive}
        {The pack says the device has an MMCM. Which one is the whole question:
         MMCME2_ADV, MMCME3_ADV and MMCME4_ADV are accepted on each other's
         architectures and silently retargeted, so "there is an MMCM" without a
         name is the exact shape of the defect this pack exists to prevent.}}
}

set ::pack_cascade_spec(board) {
    {board_part set {board_repo_paths}
        {The pack names a vendor board VLNV. Without the repository path Vivado
         resolves it against whatever board files happen to be installed on the
         machine running the build - an undeclared dependency on one host, which
         works until CI, or until somebody upgrades a tool.}}
    {fpgahub_board set {fpgahub_target}
        {THE LEASE SCOPE AND THE PROGRAM SCOPE ARE DIFFERENT NAMESPACES. A pack
         that names only the board group can lease the board and cannot program
         it, and finds that out at the end of a long build. The two names are
         usually similar enough to read as typos of each other, and the 404 that
         comes back from using one for the other does not say which.}}
}

#### 1d. CLOSED VALUE SETS #####################################################
#
# Only where the set really is closed and a wrong member is silent. bin_style is
# the case that earns the mechanism: both values "work", and one of them
# corrupts the load.

array set ::pack_enum_spec {
    board,platform     {bare pynq}
    board,bin_style    {zynq7 zynqmp}
    board,deploy_style {jtag qspi sd tftp}
}

#### 1e. ALIASES ###############################################################
#
# A pack that spells a key differently is a TABLE ENTRY, not forty guarded call
# sites. Entries are evidence that a real pack spelled something a second way -
# not a guess about one that might, so this table stays close to empty and every
# addition names the pack that motivated it.
#
# NOTE this is the PACK-FACING table: it canonicalises what a pack writes.
# flow/common/flow_utils.tcl owns a second, ENGINE-FACING one for what a stage
# script asks for. They are different questions and they are deliberately not
# shared.

array set ::pack_alias_spec {
    part,part            part_name
    part,name            part_name
    part,architecture    family
    part,arch            family
    part,speed           speed_grade
    part,min_vivado      min_vivado_version
    board,name           board_name
    board,part_name      part
    board,clk_freq_hz    sys_clk_freq_hz
    board,sys_clk_hz     sys_clk_freq_hz
}

#### 1f. KEYS WHERE EMPTY IS A DECISION ########################################
#
# Everywhere else an empty list is a silent no-op downstream and the validator
# rejects it. `part_set io_banks {}` would otherwise assert that a device has no
# IO banks by accident and nothing would ever say so.
#
# Nothing qualifies yet in either role. The mechanism is here because the
# reference toolkit needed it within a year and the alternative - one special
# case in the validator - is how a validator starts to rot.

set ::pack_empty_ok(part)  {}
set ::pack_empty_ok(board) {}

#### 1g. THE PHYSICAL-PRIMITIVE KEYS ###########################################
#
# Every key whose value must name a primitive that PHYSICALLY EXISTS on this
# device. Section 6 cross-checks each of these against primitives_retargeted and
# primitives_rejected. One list, so adding a primitive key to the schema and
# forgetting to protect it is one omission rather than a silent one.
#
# Part role only: a board has no primitives.

set ::pack_physical_primitive_keys {
    global_buffer clock_buffer_ce clock_buffer_div
    mmcm_primitive pll_primitive
    idelay_primitive idelay_control_primitive
    io_buffer_primitive serdes_primitive
    bram_primitive dsp_primitive uram_primitive
    sysmon_primitive gt_primitive ps_type
}

# Which file name a pack of each role is called. Also what the loader scans for
# when it enumerates the installed packs, so the directory is always the
# authority on what exists - CONTRACT.md section 0, third rule.
set ::pack_file_name(part)  part.tcl
set ::pack_file_name(board) board.tcl

set ::pack_roles {part board}
