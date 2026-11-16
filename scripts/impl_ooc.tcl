# Non-project out-of-context synthesis and implementation of one IP top
# (same part, XDC and 0 BRAM / 0 DSP as scripts/create_project.tcl; does not
# touch project/). Arguments: <top> <output directory>.
#   make impl-ooc TOP=mlkem_axis_top   (Lite + Stream)
#   make impl-ooc TOP=mlkem_axi        (Lite + AXI4 buffer)
set top [lindex $argv 0]
set out [file normalize [lindex $argv 1]]
file mkdir $out
source [file join [file dirname [file normalize [info script]]] sources.tcl]
set_part xc7a200tfbg676-3
set_param general.maxThreads 8
# The stream top is read last (the order the reported results were built with)
set axis_top [file join $root_dir rtl modules top mlkem_axis_top.v]
read_verilog [lsearch -all -inline -not -exact $rtl_files $axis_top]
read_verilog $axis_top
read_xdc [file join $root_dir constraint mlkem.xdc]
read_xdc -mode out_of_context [file join $root_dir constraint mlkem_ooc.xdc]
synth_design -top $top -mode out_of_context -include_dirs $inc_dirs -max_bram 0 -max_uram 0 -max_dsp 0
report_utilization -file $out/synth_util.rpt
puts "MLKEM_SYNTH BRAM=[llength [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]] DSP=[llength [get_cells -quiet -hier -filter {REF_NAME =~ DSP*}]]"
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force $out/routed.dcp
report_timing_summary -max_paths 10 -file $out/timing.rpt
report_utilization -file $out/utilization.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $out/utilization_hier.rpt
set_switching_activity -deassert_resets
report_power -file $out/power.rpt
puts "MLKEM_IMPL WNS=[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]"
# Every setup path within 0.25 ns of failing, one line each
set fh [open $out/near_critical.txt w]
foreach p [get_timing_paths -max_paths 20000 -nworst 1 -setup -slack_lesser_than 0.25] {
    puts $fh "[format %.3f [get_property SLACK $p]] L=[get_property LOGIC_LEVELS $p] D=[format %.2f [get_property DATAPATH_DELAY $p]] N=[format %.2f [get_property DATAPATH_NET_DELAY $p]] [get_property STARTPOINT_PIN $p] -> [get_property ENDPOINT_PIN $p]"
}
close $fh
