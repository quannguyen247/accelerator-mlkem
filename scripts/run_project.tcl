# Runs synthesis and implementation of project/mlkem_top once and writes the
# routed reports to build/impl. Stops before implementation if synthesis
# inferred any block RAM, UltraRAM or DSP.
#   vivado -mode batch -source scripts/run_project.tcl -tclargs [jobs]
set root_dir [file dirname [file dirname [file normalize [info script]]]]
set jobs [expr {[llength $argv] > 0 ? [lindex $argv 0] : 8}]
set out_dir [file join $root_dir build impl]
file mkdir $out_dir

open_project [file join $root_dir project mlkem_top mlkem_top.xpr]
reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "synth_1 failed" }

open_run synth_1 -name synth_1
set n_bram [llength [get_cells -hier -filter {REF_NAME =~ RAMB* || REF_NAME =~ FIFO*}]]
set n_uram [llength [get_cells -hier -filter {REF_NAME =~ URAM*}]]
set n_dsp  [llength [get_cells -hier -filter {REF_NAME =~ DSP*}]]
puts "MLKEM_SYNTH block RAM = $n_bram, UltraRAM = $n_uram, DSP = $n_dsp"
close_design
if {$n_bram + $n_uram + $n_dsp != 0} { error "hard macros inferred; implementation not started" }

launch_runs impl_1 -to_step route_design -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "impl_1 failed" }

open_run impl_1 -name impl_1
report_timing_summary -delay_type min_max -max_paths 10 -file [file join $out_dir timing.rpt]
report_timing -max_paths 40 -nworst 1 -unique_pins -path_type summary -file [file join $out_dir critical_paths.rpt]
report_utilization -file [file join $out_dir utilization.rpt]
report_utilization -hierarchical -hierarchical_depth 3 -file [file join $out_dir utilization_hier.rpt]
report_power -file [file join $out_dir power_vectorless.rpt]
puts "MLKEM_IMPL WNS = [get_property STATS.WNS [get_runs impl_1]] ns, WHS = [get_property STATS.WHS [get_runs impl_1]] ns"
puts "Implementation reports: $out_dir"
close_project
