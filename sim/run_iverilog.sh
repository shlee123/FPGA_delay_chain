#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_dir}/build/iverilog"

if ! command -v iverilog >/dev/null 2>&1; then
    echo "ERROR: iverilog is required." >&2
    exit 127
fi

mkdir -p "${build_dir}"

iverilog \
    -g2012 \
    -Wall \
    -DOPEN_SOURCE_SIM \
    -s tb_ku115_delay_chain \
    -o "${build_dir}/tb_ku115_delay_chain.vvp" \
    "${repo_dir}/sim/xilinx_ultrascale_behavioral.sv" \
    "${repo_dir}/rtl/ku115_odelay4_select.sv" \
    "${repo_dir}/rtl/ku115_delay_chain_top.sv" \
    "${repo_dir}/sim/tb_ku115_delay_chain.sv"

vvp "${build_dir}/tb_ku115_delay_chain.vvp"
