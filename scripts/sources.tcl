# Source lists shared by the project, packaging and synthesis scripts.
# Sets: root_dir, rtl_files, ntt_files, inc_dirs, hdr_files.
set root_dir [file dirname [file dirname [file normalize [info script]]]]

# rtl/modules/<block>/*.v plus the NTT (poly/ntt) and Keccak (hash/keccak) cores
set rtl_files [lsort [concat \
    [glob [file join $root_dir rtl modules * *.v]] \
    [glob [file join $root_dir rtl modules * * *.v]]]]
set ntt_files [lsort [glob [file join $root_dir rtl modules poly ntt *.v]]]

set inc_dirs [list [file join $root_dir rtl utils]]
set hdr_files [lsort [glob [file join $root_dir rtl utils *.vh]]]
