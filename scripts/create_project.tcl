# Recreate the Vivado project from repository sources.
#
# Usage:
#   vivado -mode batch -source scripts/create_project.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_dir   [file normalize [file join $script_dir ..]]
set build_dir  [file join $repo_dir build]

create_project FPGA_delay_chain $build_dir \
    -part xcku115-flvb1760-1-c \
    -force

add_files [list \
    [file join $repo_dir rtl ku115_odelay4_select.sv] \
    [file join $repo_dir rtl ku115_delay_chain_top.sv]]

add_files -fileset constrs_1 \
    [file join $repo_dir constraints ku115_delay_chain_template.xdc]

set_property top ku115_delay_chain_top [current_fileset]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1

puts "Created project: [file join $build_dir FPGA_delay_chain.xpr]"
puts "Before implementation, complete all PACKAGE_PIN and IOSTANDARD entries."
