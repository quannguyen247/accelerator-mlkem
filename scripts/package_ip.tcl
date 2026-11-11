# Packages the IPs of project/ip_repo (component.xml, src/, xgui/):
#   mlkem_core  quannguyen247.org:user:mlkem_core:1.0  top mlkem_axi (all RTL)
#   ntt_core    quannguyen247.org:user:ntt_core:1.0    top ntt_core_top (rtl/modules/poly/ntt)
# keccak_core is the IP of keccak-mlkem, copied unchanged.
#   vivado -mode batch -source scripts/package_ip.tcl
source [file join [file dirname [file normalize [info script]]] sources.tcl]

proc package_core {name top files display desc} {
    global root_dir hdr_files
    set ip_dir [file join $root_dir project ip_repo $name]
    set tmp_dir [file join $root_dir build ip_pkg_$name]

    file delete -force $ip_dir $tmp_dir
    create_project -force ip_pkg $tmp_dir -part xck26-sfvc784-2LV-c
    add_files -norecurse $files
    add_files -norecurse $hdr_files
    set_property file_type {Verilog Header} [get_files *.vh]
    set_property top $top [get_filesets sources_1]
    update_compile_order -fileset sources_1

    ipx::package_project -root_dir $ip_dir -vendor quannguyen247.org -library user \
        -taxonomy /UserIP -import_files -set_current false -force
    set core [ipx::open_core [file join $ip_dir component.xml]]
    set_property name $name $core
    set_property version 1.0 $core
    set_property display_name $display $core
    set_property description $desc $core
    set_property vendor_display_name {quannguyen247} $core
    set_property supported_families {zynquplus Production artix7 Production kintex7 Production} $core
    set_property core_revision 1 $core
    return $core
}

proc finish_core {core name} {
    global root_dir
    set ip_dir [file join $root_dir project ip_repo $name]
    # The GUI file is regenerated under the final IP name.
    foreach g [ipx::get_file_groups *xgui* -of_objects $core] { ipx::remove_file_group [get_property NAME $g] $core }
    file delete -force [file join $ip_dir xgui]
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::check_integrity $core
    ipx::save_core $core
    ipx::unload_core [file join $ip_dir component.xml]
    close_project
    file delete -force [file join $root_dir build ip_pkg_$name]
    puts "Packaged IP: $ip_dir"
}

# ML-KEM accelerator: one clock for both slaves; active-low reset.
set core [package_core mlkem_core mlkem_axi $rtl_files {ML-KEM accelerator core} \
    {FIPS 203 ML-KEM-512/768/1024 KeyGen, Encaps and Decaps. AXI4-Lite CSR (s_axil), AXI4 slave on the 4736-byte request/result buffer (s_axi), interrupt.}]
ipx::associate_bus_interfaces -busif s_axil -clock aclk $core
ipx::associate_bus_interfaces -busif s_axi -clock aclk $core
if {[llength [ipx::get_bus_interfaces irq -of_objects $core]] == 0} {
    ipx::infer_bus_interface irq xilinx.com:signal:interrupt_rtl:1.0 $core
}
finish_core $core mlkem_core

# NTT/INTT core: native port (start, mode, 8-bit coefficient port), clk, active-low rst_n.
set core [package_core ntt_core ntt_core_top $ntt_files {ML-KEM NTT/INTT core} \
    {256-point NTT and INTT over Z_3329 with in-place distributed RAM. INTT_SCALE = 1 multiplies the INTT result by 128^-1, INTT_SCALE = 0 skips that pass.}]
finish_core $core ntt_core
