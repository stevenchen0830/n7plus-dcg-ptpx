# syn/ — 官方评分环境的复现脚本（未在本机运行）

本机没有 Design Compiler / PrimeTime，也没有 N7+ 库；这里的脚本把题目给出的
综合与功耗评估条件写成可直接执行的形式，供有工具的机器一键运行：

```sh
N7P_PDK_ROOT=/path/to/n7p sh syn/run_all.sh
```

| 文件 | 作用 | 要改的地方 |
| --- | --- | --- |
| `dcg/setup.tcl` | N7+ 库与物理数据：H240 SVT/LVT/ULVT 的 `.db`、Milkyway 参考库、TLU+ | `PDK_ROOT` 与文件名模式必须按本地安装调整 |
| `dcg/setup_asap7.tcl` | **脚本试跑配置**：用开源 ASAP7 库（SS 0.63 V/100 ℃，RVT/LVT/SLVT）走同一套流程；自动把 `.lib(.gz)` 转成 `.db`；设置 ps/fF 单位缩放；无物理数据，按非 topographical 运行 | `ASAP7_NLDM` 指向 OpenROAD-flow-scripts 的 `flow/platforms/asap7/lib/NLDM` |
| `dcg/constraints.tcl` | 1 GHz、DCG 10 % margin（真实周期 0.9 ns）、setup uncertainty 0.15 ns、ICG 额外 0.10 ns、REG_IN/REG_OUT 口的 IO 预算、SRAM 接口时序；所有时间以 ns 书写，经 `TIME_SCALE` 适配库单位 | 若课程封装脚本已自动施加 DCG margin，把 `APPLY_DCG_MARGIN` 设为 0，避免双重扣减 |
| `dcg/run_dcg.tcl` | `dc_shell -topographical`：读 RTL → 物理设置 → 约束 → ICG 风格 → `compile_ultra -gate_clock -spg` → 报告（qor/timing/area/power/congestion/clock_gating/violators/reg_io_paths）→ 网表/ddc/sdc/sdf | 环境变量 `DCG_SETUP`、`DCG_RETIME_MAC`（见下） |
| `ptpx/run_ptpx.tcl` | 读 DCG 网表 + SDC，`read_vcd -strip_path img_filter_tb/u_dut`，`report_power` | `-x "set CASE A; set VCD <file>"` 传入用例 |
| `run_all.sh` | 顺序执行 DCG → 用例 A/B 活动文件（`scripts/run_sim.sh CASE_A/B`）→ PTPX → `scripts/score.py` | 无 |
| `dc_stub.tcl`、`check_scripts.sh` | 用 tclsh 把全部流程脚本真正执行一遍（工具命令替换成空操作），抓 Tcl 语法错误、未定义变量、控制流错误；CI 每次运行 | 无 |

## 三种运行方式

```sh
# 1. 官方：N7+ 库，topographical，出评分数字
cd syn/dcg && dc_shell -topographical -f run_dcg.tcl

# 2. 试跑：有 DC 没有 N7+ 库的机器，用 ASAP7 库把脚本跑通（数字不可用于评分）
cd syn/dcg && DCG_SETUP=./setup_asap7.tcl ASAP7_NLDM=/path/to/ORFS/flow/platforms/asap7/lib/NLDM \
    dc_shell -f run_dcg.tcl
cd ../ptpx && DCG_SETUP=./setup_asap7.tcl pt_shell -f run_ptpx.tcl -x "set CASE A; set VCD ../../verification/case_A.vcd"

# 3. 无工具：tclsh 桩环境执行（本机与 CI 都跑过）
sh syn/check_scripts.sh
```

试跑能证明的：RTL 读入、ICG 推断（ASAP7 SEQ 库的 `ICGx*` 带
`clock_gating_integrated_cell` 属性）、REG_IN/REG_OUT 路径报告、面积/时序/功耗报告、
网表/SDC/SDF 输出、PTPX 读 VCD。试跑不能证明的：拥塞报告格式（需要 topographical
物理数据）、N7+ 下的任何数值。

## 评分项与报告的对应

| 评分项 | 来源 | `score.py` 解析位置 |
| --- | --- | --- |
| Tx | 用例 A 拍数（`verification/logs/case_a.log`）× 收敛周期（`qor.rpt` 的 Critical Path Slack） | `--sim-log`、`--dcg-reports` |
| PAx / PBx | `ptpx/reports/power_A.rpt`、`power_B.rpt` 的 Total Power | `--ptpx-reports` |
| Ax | `dcg/reports/qor.rpt` Cell Area（或 `area.rpt` Total cell area） | `--dcg-reports` |
| 拥塞 both/H/V | `dcg/reports/congestion.rpt` | `--dcg-reports`（首次使用请对照真实报告核对正则） |
| MPx / MAx | 用例 A 访存次数 × `MEM_DWTH` / 6400；`MEM_NUM × MEM_DWTH / 5` | 自动 |

## 活动文件的两种来源

1. **RTL 级 VCD**（默认）：`VCD=verification/case_A.vcd sh scripts/run_sim.sh CASE_A`。
   寄存器名与 DCG 网表一致（`change_names -rules verilog`），综合新增的内部网络由 PT
   从已标注的寄存器传播；精度略低但不需要库的仿真模型。1440×24 的用例 A 全层次
   VCD 约数百 MB，`+VCD_PORTS` 只导出顶层。
2. **门级 VCD**：用同一 testbench 仿真 `dcg/outputs/IMG_FILTER.dcg.v`（需要标准单元
   Verilog 模型与 `write_sdf` 输出），精度最高。

## 若 DCG 在 0.9 ns 不收敛：两级兜底

先算容忍度：`score.py --wns <slack>` 按 `收敛周期 = 0.9 ns − slack` 折算 Tx。用例 A
9,383 拍下，slack ≥ −100 ps 一分不扣（周期仍 ≤ 1 ns），slack ≥ −272 ps 不判零。

| 级别 | 做法 | 代价 | 何时用 |
| --- | --- | --- | --- |
| 1. 流程级 | `DCG_RETIME_MAC=1 dc_shell -topographical -f run_dcg.tcl`：只解锁 MAC 流水寄存器（`pair_q/part_q`，其余全部 `set_dont_retime`），`compile_ultra -retime` 把它们移进乘加树 | 不改 RTL，不需重跑回归；面积基本不变 | slack 在 −50～−150 ps |
| 2. RTL 级 | 切到 `mac4` 分支：50 个乘积先寄存，MAC 四级流水 | +16×50×18 bit 寄存器（约 +14k 触发器），+1 拍延时，面积项估计少 3～4 分 | 级别 1 仍不够，且负 slack 的损失大于面积损失 |

两级都不改变 REG_IN/REG_OUT 结构，也不改变吞吐（4 像素/拍）。
