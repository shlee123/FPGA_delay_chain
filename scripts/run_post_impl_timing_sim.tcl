# Run post-implementation timing simulation after board-specific constraints
# have been completed and impl_1 has successfully routed.
#
# Usage:
#   vivado -mode batch -source scripts/run_post_impl_timing_sim.tcl

set script_dir   [file dirname [file normalize [info script]]]
set repo_dir     [file normalize [file join $script_dir ..]]
set project_file [file join $repo_dir build FPGA_delay_chain.xpr]
set tb_file      [file join $repo_dir sim tb_ku115_delay_chain.sv]

if {![file exists $project_file]} {
    error "Project not found: $project_file. Run scripts/create_project.tcl first."
}

open_project $project_file

set impl_status [get_property STATUS [get_runs impl_1]]
if {![string match "*Complete*" $impl_status]} {
    error "impl_1 is not complete (STATUS='$impl_status'). Complete route_design first."
}

if {[llength [get_files -quiet $tb_file]] == 0} {
    add_files -fileset sim_1 $tb_file
}

set_property top tb_ku115_delay_chain [get_filesets sim_1]
update_compile_order -fileset sim_1

launch_simulation -mode post-implementation -type timing
run all
close_sim
close_project
