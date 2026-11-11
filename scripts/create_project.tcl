# Creates project/mlkem_top/mlkem_top.xpr: standalone out-of-context build of
# the IP top (mlkem_axi) with the 4.4 ns clock of constraint/mlkem.xdc. On 7-series
# parts constraint/mlkem_ooc.xdc adds the clock source and partition pins of
# the out-of-context implementation (Artix-7 XC7A200T-3 by default).
#   vivado -mode batch -source scripts/create_project.tcl -tclargs [part]
source [file join [file dirname [file normalize [info script]]] sources.tcl]
set part [expr {[llength $argv] > 0 ? [lindex $argv 0] : "xc7a200tfbg676-3"}]
set proj_dir [file join $root_dir project mlkem_top]

# Generated folders first, with retries: on some file systems (ntfs3) a tree
# is not always removable in one pass, and create_project -force then stops.
foreach sub {mlkem_top.runs mlkem_top.cache mlkem_top.hw mlkem_top.ip_user_files mlkem_top.sim mlkem_top.gen} {
    set d [file join $proj_dir $sub]
    for {set try 0} {$try < 5 && [file exists $d]} {incr try} {
        catch {file delete -force $d}
        if {[file exists $d]} { after 1000 }
    }
}
create_project -force mlkem_top $proj_dir -part $part
set_property target_language Verilog [current_project]

add_files -norecurse $rtl_files
add_files -norecurse $hdr_files
set_property file_type {Verilog Header} [get_files *.vh]
set_property include_dirs $inc_dirs [get_filesets sources_1]
set_property top mlkem_axi [get_filesets sources_1]

add_files -fileset constrs_1 -norecurse [file join $root_dir constraint mlkem.xdc]
if {[string match xc7* $part]} {
    set ooc_xdc [file join $root_dir constraint mlkem_ooc.xdc]
    add_files -fileset constrs_1 -norecurse $ooc_xdc
    set_property USED_IN_SYNTHESIS false [get_files $ooc_xdc]
}

# Behavioral simulation of the IP top; vectors are read from vector/
# (path relative to the xsim run directory, so the project can be moved).
add_files -fileset sim_1 -norecurse [file join $root_dir testbench tb_mlkem_axi.sv]
set_property include_dirs $inc_dirs [get_filesets sim_1]
set_property top tb_mlkem_axi [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]
set_property -name {xsim.simulate.xsim.more_options} \
    -value {-testplusarg VEC=../../../../../../vector} -objects [get_filesets sim_1]

# Out-of-context top level: no I/O buffers, no package pins.
# The design uses LUTs, flip-flops and distributed RAM only.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.MAX_BRAM 0 [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.MAX_URAM 0 [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 0 [get_runs synth_1]
# Every run is a full run (no reference checkpoint for incremental synthesis).
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
close_project
puts "Project: [file join $proj_dir mlkem_top.xpr]"
