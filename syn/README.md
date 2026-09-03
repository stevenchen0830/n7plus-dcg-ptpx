# syn/ — 官方评分环境的复现脚本（未在本机运行）

本机没有 Design Compiler / PrimeTime，也没有 N7+ 库；这里的脚本把题目给出的
综合与功耗评估条件写成可直接执行的形式，供有工具的机器一键运行：

```sh
N7P_PDK_ROOT=/path/to/n7p sh syn/run_all.sh
```

| 文件 | 作用 | 要改的地方 |
| --- | --- | --- |
| `dcg/setup.tcl` | 库与物理数据：H240 SVT/LVT/ULVT 的 `.db`、Milkyway 参考库、TLU+ | `PDK_ROOT` 与文件名模式必须按本地安装调整 |
| `dcg/constraints.tcl` | 1 GHz、DCG 10 % margin（真实周期 0.9 ns）、setup uncertainty 0.15 ns、ICG 额外 0.10 ns、REG_IN/REG_OUT 口的 IO 预算、SRAM 接口时序 | 若课程封装脚本已自动施加 DCG margin，把 `APPLY_DCG_MARGIN` 设为 0，避免双重扣减 |
| `dcg/run_dcg.tcl` | `dc_shell -topographical`：读 RTL → 物理设置 → 约束 → ICG 风格 → `compile_ultra -gate_clock -spg` → 报告（qor/timing/area/power/congestion/clock_gating/violators/reg_io_paths）→ 网表/ddc/sdc/sdf | 一般不需要改 |
| `ptpx/run_ptpx.tcl` | 读 DCG 网表 + SDC，`read_vcd -strip_path img_filter_tb/u_dut`，`report_power` | `-x "set CASE A; set VCD <file>"` 传入用例 |
| `run_all.sh` | 顺序执行 DCG → 用例 A/B 活动文件（`scripts/run_sim.sh CASE_A/B`）→ PTPX → `scripts/score.py` | 无 |

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

## 若 DCG 在 0.9 ns 不收敛

`score.py --wns <slack>` 会按 `收敛周期 = 0.9 ns − slack` 折算 Tx；结构性对策见
`docs/ppa_status.md` §2（MAC 第一级再拆一级流水）。
