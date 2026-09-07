# Reproducible non-project Vivado build for Digilent Nexys A7-100T.
#
# Usage:
#   vivado -mode batch -source fpga/build.tcl -tclargs synth
#   vivado -mode batch -source fpga/build.tcl -tclargs impl
#   vivado -mode batch -source fpga/build.tcl -tclargs strategy explore
#   vivado -mode batch -source fpga/build.tcl -tclargs strategy aggressive
#   vivado -mode batch -source fpga/build.tcl -tclargs strategy postroute
#   vivado -mode batch -source fpga/build.tcl -tclargs build

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_root build fpga]

set part_name  xc7a100tcsg324-1
set top_name   nexys_a7_top
set mode       build
set strategy   default

if {$argc > 0} {
    set mode [lindex $argv 0]
}
if {$argc > 1} {
    set strategy [lindex $argv 1]
}
if {$mode ni {synth impl strategy build}} {
    error "Unknown build mode '$mode'; expected 'synth', 'impl', 'strategy', or 'build'"
}
if {$mode eq "strategy" && $strategy ni {explore aggressive postroute}} {
    error "Unknown implementation strategy '$strategy'; expected 'explore', 'aggressive', or 'postroute'"
}

file mkdir $build_dir

if {$mode eq "strategy"} {
    set synth_checkpoint [file join $build_dir post_synth.dcp]
    if {![file exists $synth_checkpoint]} {
        error "Required synthesis checkpoint is missing: $synth_checkpoint. Run synthesis first."
    }

    set strategies_dir [file join $build_dir strategies]
    set strategy_dir [file join $strategies_dir $strategy]
    file mkdir $strategy_dir

    puts "INFO: Running implementation strategy '$strategy'"
    if {$strategy eq "explore"} {
        open_checkpoint $synth_checkpoint
        opt_design
        place_design -directive Explore
        phys_opt_design -directive AggressiveExplore
        write_checkpoint -force [file join $strategy_dir post_place.dcp]
        route_design -directive Explore
    } elseif {$strategy eq "aggressive"} {
        set placed_checkpoint [file join $strategies_dir explore post_place.dcp]
        if {![file exists $placed_checkpoint]} {
            error "Required Explore placement checkpoint is missing: $placed_checkpoint"
        }
        open_checkpoint $placed_checkpoint
        route_design -directive AggressiveExplore
    } else {
        set routed_checkpoint [file join $strategies_dir explore post_route.dcp]
        if {![file exists $routed_checkpoint]} {
            error "Required Explore route checkpoint is missing: $routed_checkpoint"
        }
        open_checkpoint $routed_checkpoint
        phys_opt_design -directive AggressiveExplore
    }

    write_checkpoint -force [file join $strategy_dir post_route.dcp]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -file [file join $strategy_dir timing_summary.rpt]
    report_timing -delay_type max -max_paths 5 -path_type full \
        -file [file join $strategy_dir timing_top5.rpt]
    report_utilization -file [file join $strategy_dir utilization.rpt]
    report_drc -file [file join $strategy_dir drc.rpt]
    check_timing -verbose -file [file join $strategy_dir check_timing.rpt]
    report_route_status -file [file join $strategy_dir route_status.rpt]

    puts "INFO: Strategy '$strategy' completed; bitstream was not generated."
    exit 0
}

# nexys_a7_top intentionally keeps IMEM_FILE="bootloader.mem". Copy the
# generated image into Vivado's working directory so $readmemh resolves that
# exact name in both synthesis and bitstream memory initialization.
set bootloader_src [file join $repo_root sw tests bootloader.mem]
set bootloader_mem [file join $build_dir bootloader.mem]
if {![file exists $bootloader_src]} {
    error "Required bootloader image is missing: $bootloader_src. Run 'make fpga_bootloader' first."
}
file copy -force $bootloader_src $bootloader_mem

# Explicit source order keeps packages ahead of modules and excludes all
# simulation-only tb/ sources.
set rtl_sources [list \
    [file join $repo_root rtl core alu_ops.sv] \
    [file join $repo_root rtl core riscv_pkg.sv] \
    [file join $repo_root rtl core pipeline_decode.sv] \
    [file join $repo_root rtl core pipeline_control.sv] \
    [file join $repo_root rtl core forwarding_unit.sv] \
    [file join $repo_root rtl core alu.sv] \
    [file join $repo_root rtl core mdu.sv] \
    [file join $repo_root rtl core register_file.sv] \
    [file join $repo_root rtl core imm_gen.sv] \
    [file join $repo_root rtl core csr_file.sv] \
    [file join $repo_root rtl core control_unit.sv] \
    [file join $repo_root rtl core datapath.sv] \
    [file join $repo_root rtl core cpu.sv] \
    [file join $repo_root rtl memory imem.sv] \
    [file join $repo_root rtl memory dmem.sv] \
    [file join $repo_root rtl peripheral uart.sv] \
    [file join $repo_root rtl peripheral timer.sv] \
    [file join $repo_root rtl peripheral gpio.sv] \
    [file join $repo_root rtl peripheral sevenseg.sv] \
    [file join $repo_root rtl peripheral spi_flash.sv] \
    [file join $repo_root rtl soc_top.sv] \
    [file join $repo_root rtl nexys_a7_top.sv]]

foreach source $rtl_sources {
    if {![file exists $source]} {
        error "Required RTL source is missing: $source"
    }
}

set constraints_file [file join $repo_root constraints nexys_a7.xdc]
if {![file exists $constraints_file]} {
    error "Required constraints file is missing: $constraints_file"
}

cd $build_dir
read_verilog -sv $rtl_sources
read_mem $bootloader_mem
read_xdc $constraints_file

puts "INFO: Synthesizing $top_name for $part_name"
synth_design -top $top_name -part $part_name
write_checkpoint -force [file join $build_dir post_synth.dcp]

report_utilization \
    -file [file join $build_dir post_synth_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $build_dir post_synth_utilization_hierarchical.rpt]
report_timing_summary -delay_type max -report_unconstrained \
    -file [file join $build_dir post_synth_timing_summary.rpt]
check_timing -verbose \
    -file [file join $build_dir post_synth_check_timing.rpt]

if {[llength [info commands report_ram_utilization]] != 0} {
    report_ram_utilization \
        -file [file join $build_dir post_synth_ram_utilization.rpt]
}

if {$mode eq "synth"} {
    puts "INFO: Synthesis-only build completed successfully."
    exit 0
}

puts "INFO: Running implementation"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $build_dir post_route.dcp]

report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $build_dir post_route_timing_summary.rpt]
report_timing -delay_type max -max_paths 5 -path_type full \
    -file [file join $build_dir post_route_timing_top5.rpt]
report_utilization \
    -file [file join $build_dir post_route_utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 4 \
    -file [file join $build_dir post_route_utilization_hierarchical.rpt]
report_drc \
    -file [file join $build_dir post_route_drc.rpt]
check_timing -verbose \
    -file [file join $build_dir post_route_check_timing.rpt]
report_route_status \
    -file [file join $build_dir post_route_status.rpt]

if {$mode eq "impl"} {
    puts "INFO: Implementation-only build completed successfully; bitstream was not generated."
    exit 0
}

# Treat negative routed setup slack as a failed build instead of producing a
# bitstream that does not meet the declared 100 MHz clock constraint.
set worst_paths [get_timing_paths -quiet -delay_type max -max_paths 1]
if {[llength $worst_paths] == 0} {
    error "No routed setup timing path was found; inspect the timing constraints."
}
set routed_wns [get_property SLACK [lindex $worst_paths 0]]
puts "INFO: Routed setup WNS = $routed_wns ns"
if {$routed_wns < 0.0} {
    error "Timing failure: routed setup WNS is $routed_wns ns"
}

set drc_errors [get_drc_violations -quiet -filter \
    {SEVERITY == "Error" || SEVERITY == "Critical Warning"}]
if {[llength $drc_errors] != 0} {
    error "DRC failure: [llength $drc_errors] error violation(s); see post_route_drc.rpt"
}

set bitstream_file [file join $build_dir nexys_a7_100t.bit]
write_bitstream -force $bitstream_file
puts "INFO: Bitstream written to $bitstream_file"
