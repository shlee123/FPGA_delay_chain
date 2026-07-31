# Run AMD UNISIM behavioral simulation.
#
# Usage:
#   vivado -mode batch -source sim/run_xsim.tcl
#
# The lightweight models in xilinx_ultrascale_behavioral.sv are deliberately
# not added; Vivado resolves the instantiated primitives from UNISIM.

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_dir build xsim]

create_project xsim_delay_chain $build_dir \
    -part xcku115-flvb1760-1-c \
    -force

add_files [list \
    [file join $repo_dir rtl ku115_odelay4_select.sv] \
    [file join $repo_dir rtl ku115_idelay4_select.sv] \
    [file join $repo_dir rtl ku115_delay_chain_top.sv]]

add_files -fileset sim_1 \
    [file join $repo_dir sim tb_ku115_delay_chain.sv]

set_property top tb_ku115_delay_chain [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

launch_simulation -mode behavioral
run all
close_sim
close_project
