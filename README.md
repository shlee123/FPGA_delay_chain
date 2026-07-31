# FPGA_delay_chain

[![Simulation](https://github.com/shlee123/FPGA_delay_chain/actions/workflows/simulation.yml/badge.svg)](https://github.com/shlee123/FPGA_delay_chain/actions/workflows/simulation.yml)

Xilinx Kintex UltraScale `xcku115-flvb1760-1-c` 的四元件可程式化
IODELAY cascade 範例。此專案同時示範 80 MHz forwarded-clock 的輸出
delay，以及由 input port 經 IBUF 進入 IODELAY cascade 後回到 fabric 的
輸入 delay；兩條路徑都使用 `SEL[1:0]` 在執行期間選擇四種 programmable
delay。

## 架構

UltraScale 的合法四元件 component-mode chain 必須交錯使用：

```text
ODELAYE3 MASTER
  -> IDELAYE3 SLAVE_MIDDLE
  -> ODELAYE3 SLAVE_MIDDLE
  -> IDELAYE3 SLAVE_END

由 input port 起始的路徑則從 `IBUF` 接到 IDELAYE3 MASTER，交錯方向相反：

```text
data_in (input port) -> IBUF -> IDELAYE3 MASTER
  -> ODELAYE3 SLAVE_MIDDLE
  -> IDELAYE3 SLAVE_MIDDLE
  -> ODELAYE3 SLAVE_END
  -> return path -> data_to_fabric
```
```

`SEL` 不會切換實體 cascade 級數。四個 delay element 永遠存在，
控制器以 `DELAY_TYPE="VAR_LOAD"` 同時更新各級 tap。

| `SEL` | 每級 programmable delay | 四級合計 |
|---|---:|---:|
| `00` | 約 312.5 ps | 約 1.25 ns |
| `01` | 約 625 ps | 約 2.50 ns |
| `10` | 約 937.5 ps | 約 3.75 ns |
| `11` | 約 1250 ps | 約 5.00 ns |

第4設定使用 `TIME` mode 的 1250 ps 合法端點；控制器直接以
0→1250 ps 的讀回 tap span 校正，不使用 1000 ps 外插，並在計算出的
`CNTVALUEIN[8:0]` 溢位時設定 `cal_error`。

表中不含每個 delay element 與專用 cascade route 的固定 insertion
delay。實際 pad delay 應以完成 placement/routing 後的 Vivado timing
report 為準。

## 目錄

```text
rtl/
  ku115_odelay4_select.sv   四元件 delay chain 與更新 FSM
  ku115_idelay4_select.sv   四元件 input-delay chain 與更新 FSM
  ku115_delay_chain_top.sv  ODDRE1/OBUFDS 與 IBUF/input-delay 整合範例
constraints/
  ku115_delay_chain_template.xdc
scripts/
  create_project.tcl
  run_post_impl_timing_sim.tcl
sim/
  Makefile                         VCS/Icarus 共用 simulation 流程
  filelist.f                       兩種 simulator 共用 RTL file list
  run-iverilog                     透過 make 執行 Icarus
  run-vcs                          透過 make 執行 VCS
  xilinx_ultrascale_behavioral.sv  CI 專用的輕量 primitive models
  tb_ku115_delay_chain.sv          self-checking testbench
  run_xsim.tcl                     Vivado UNISIM behavioral simulation
.github/workflows/
  simulation.yml                   GitHub Actions
```

## 主要 ports

| Port | 頻率/型態 | 用途 |
|---|---|---|
| `clk80_in` | 80 MHz | `ODDRE1.C` 與 VAR_LOAD `cfg_clk` |
| `refclk300_in` | 300 MHz | `IDELAYCTRL.REFCLK` |
| `rst` | 高有效 | 啟動 component-mode reset/calibration |
| `sel[1:0]` | 控制值 | 選擇四種 programmable delay |
| `ddr_clk_p/n` | 80 MHz differential output | 延遲後的 forwarded clock |
| `data_in` | single-ended input | 經 IBUF 輸入 input-delay cascade 的信號 |
| `data_to_fabric` | fabric signal | input-delay cascade 的延遲後輸出 |
| `delay_ready` | status | 1 表示選定 delay 已載入完成 |
| `update_busy` | status | 等於 `~delay_ready` |
| `idelayctrl_ready` | status | IDELAYCTRL calibration 已完成 |
| `sel_active[1:0]` | status | 目前真正生效的選項 |
| `cal_error` | sticky status | calibration tap 檢查失敗 |
| `input_delay_ready` / `input_update_busy` | status | input-delay chain 的 ready/busy |
| `input_idelayctrl_ready` | status | input chain 的 IDELAYCTRL calibration 已完成 |
| `input_sel_active` / `input_cal_error` | status | input chain 的 active SEL / sticky error |

若 `sel` 來自另一個 clock domain，來源端必須保持整個 2-bit 值不變，
直到 `delay_ready` 與 `input_delay_ready` 都再次成為 1。切換期間不得由
接收端使用 `ddr_clk_p/n` 取樣資料，也不得使用 `data_to_fabric`。

在 `cfg_clk=80 MHz`、`IDELAYCTRL.RDY` 持續有效且最小
2.5 ps/tap 的保守條件下，最壞的 `00 <-> 11` 更新預算約為
3.8 us（包含 `SEL` 同步與偵測時間）。

## 建立 Vivado project

```tcl
vivado -mode batch -source scripts/create_project.tcl
```

產生 project 後：

1. 在 XDC 補上實際 PCB 的 package pins 與 I/O standards。
2. 確認 80 MHz 與 300 MHz clocks 已穩定，再解除 `rst`。
3. 執行 synthesis、placement 與 routing。
4. 確認每條四元件 `IDELAYE3/ODELAYE3` chain 位於同一 byte、沿合法方向排列。
5. 執行 `report_drc`、`report_timing_summary` 與完整 output timing 分析。

範例 XDC 提到 `BA17/BB17` 只作為可能的差動輸出候選；在使用前仍須
核對板卡 schematic、bank voltage、I/O standard 及 cascade placement。

## Simulation

### 1. GitHub Actions／Icarus behavioral simulation

CI 使用輕量的 UltraScale primitive behavioral models，驗證：

- reset 與 `IDELAYCTRL.RDY` 啟動流程
- delay counter 由 `X` 啟動後，必須由有效的 primitive reset 初始化
- `IDELAYCTRL.RST` 必須在 `refclk300_in` rising edge 同步解除
- `EN_VTC=0` 至少 10 個 `cfg_clk` 後才可讀取 `CNTVALUEOUT`
- `SEL=00 -> 01 -> 10 -> 11 -> 00`
- 每次切換時兩條路徑的 `delay_ready` 先降為 0，再於 3.8 us 預算內回到 1
- output/input 的 `sel_active`、`update_busy` 與 `cal_error`
- forwarded clock 的 80 MHz 週期、差動互補，以及 input/output 兩條路徑的
  四種可程式延遲（最高 5 ns）

Ubuntu 安裝 Icarus Verilog 後可在本機執行：

```console
bash sim/run-iverilog
# 或：make -C sim SIMULATOR=iverilog TESTBENCH=tb_ku115_delay_chain.sv sim
```

Icarus 執行完成後會產生
`sim/build/iverilog/tb_ku115_delay_chain.vcd`。

若電腦已安裝 Synopsys VCS 與 Verdi：

```console
export XILINX_VIVADO=/tools/Xilinx/Vivado/2024.1
bash sim/run-vcs
make -C sim run_verdi
```

VCS flow 會編譯 `$XILINX_VIVADO/data/verilog/src/glbl.v`，並同時以
`tb_ku115_delay_chain` 與 `glbl` 作為 simulation tops。Testbench 將 user
reset 保持到 200 ns 之後才解除，避免與 `glbl.GSR` 的預設 startup
release 重疊。若 Vivado 安裝位置不同，可用 `VIVADO_HOME` 或 `GLBL_SRC`
覆寫。

VCS 執行時 testbench 會呼叫 `$fsdbDumpfile` 與 `$fsdbDumpvars`，產生
`sim/build/vcs/tb_ku115_delay_chain.fsdb`；`run_verdi` 會同時開啟 VCS
design database 與該 FSDB。可用 Makefile 變數覆寫工具或選項，例如：

```console
make -C sim SIMULATOR=vcs TESTBENCH=tb_ku115_delay_chain.sv \
  VCS=/tools/vcs/bin/vcs VERDI=/tools/verdi/bin/verdi sim
```

Icarus 不支援原生 FSDB，因此開源 CI 使用 VCD；FSDB 僅在
`SIMULATOR=vcs` 時啟用。

`sim/xilinx_ultrascale_behavioral.sv` 只模擬本專案使用到的 primitive
功能，並以固定 5 ps/tap 讓 CI 結果可重現。為了捕捉 startup 問題，
其 delay counter 會從 `X` 開始，並檢查 IDELAYCTRL reset 的解除時點；
它仍不能代表實際 silicon、PVT、IOB/cascade 固定 insertion delay 或
placement/routing。

### 2. Vivado UNISIM behavioral simulation

安裝含 Kintex UltraScale device support 的 Vivado 後執行：

```tcl
vivado -mode batch -source sim/run_xsim.tcl
```

此流程不載入 CI 的輕量 models，而是使用 Vivado 內建 UNISIM。
Testbench 仍驗證控制流程、3.8 us 更新預算、clock period 與 status；
programmable delay 的精確 CI model 數值檢查只在
`OPEN_SOURCE_SIM` 定義下啟用。

### 3. Post-implementation timing simulation

先補齊板級 XDC，並完成 `synth_1`、`impl_1` 與 route，再執行：

```tcl
vivado -mode batch -source scripts/run_post_impl_timing_sim.tcl
```

這一層才包含實際 netlist、placement/routing 與 SDF timing。最終的
IO timing sign-off 仍須以 routed design 的 `report_timing`、
receiver setup/hold、PCB delay 與量測結果為準。

## 重要限制

- `CASCADE`、cascade 級數及 physical topology 是 implementation-time
  屬性，不能由 runtime `SEL` 改變。
- `DELAY_TYPE="FIXED"` 適合每個 bitstream 固定一種設定；若 runtime
  需要四種選擇，應使用本專案的固定 topology 加 `VAR_LOAD`。
- 不要在 delay-chain 輸出與 `OBUF/OBUFDS` 之間插入 LUT 或 fabric mux。
- `data_in` 必須直接由 `IBUF` 餵入 input chain 的 IDELAYE3 MASTER；不要在
  兩者之間插入 LUT 或 fabric mux。
- 每個使用 IODELAY 的 I/O bank 只能使用一個 IDELAYCTRL reset/calibration
  domain。本範例的 input/output chain 各自帶有一個 IDELAYCTRL，因此實作時
  應將兩條 chain 放到不同的 I/O bank，或將設計整合為同一個 bank-level
  IDELAYCTRL controller；不可在同一 bank 讓兩個 controller 獨立 reset。
- 本專案尚未選定實際板卡，因此 XDC 不包含可直接 sign-off 的
  package pins、I/O standards 或 receiver setup/hold constraints。
- 5 ns 是 programmable delay 合計，不是 pipeline latency；80 MHz 下
  約等於 144° 相位位移，外部 receiver setup/hold 必須重新檢查。
- 1250 ps 位於單一 delay element 的設定上緣，需確認 `cal_error=0`，
  並以 routed timing/SDF 檢查 PVT、量化與固定 insertion delay。
- 必須在有 UltraScale device support 的 Vivado 中完成 primitive
  synthesis、placement、DRC 與 timing sign-off。

## 參考資料

- AMD UG571, *UltraScale Architecture SelectIO Resources*
- AMD UG974, *UltraScale Architecture Libraries Guide*
- AMD DS892, *Kintex UltraScale Data Sheet: DC and AC Switching Characteristics*
