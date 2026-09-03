# N7+ + DCG + PTPX — IMG_FILTER 交付与官方评分环境复现

> 49 抽头垂直 FIR 图像滤波器（RGBA10，4 像素/拍，`blk_v` = 1～49，边界镜像，
> 49 片外部单端口 SRAM）按题目交付形态整理，并把题目指定的
> **N7+ / H240 / ssgnp 0.675 V 125 ℃ / DCG 1 GHz / PTPX** 评分条件写成可直接运行的脚本。
> RTL 来自 [vfir-7nm-rtl2gds](https://github.com/stevenchen0830/vfir-7nm-rtl2gds) 的 v4
> 版本（五轮开源 RTL-to-GDS 之后的最终 RTL），只改了一处以满足严格 REG_IN。

## 一句话结论

| 问题 | 答案 |
| --- | --- |
| RTL 功能 / 接口是否满足题目？ | **是**。逐项核对见 [docs/requirements_checklist.md](docs/requirements_checklist.md)，全部功能项都有可复跑证据。 |
| 需要重写吗？ | 不需要。 |
| 能否宣称通过官方评分？ | **不能**。Tx 的频率因子、PA、PB、Ax、拥塞五项只有官方 N7+ / DCG / PTPX 环境能给出，本机没有这些工具。`syn/run_all.sh` 在有工具的机器上一条命令跑完并出评分表。 |
| 本仓库新增了什么？ | 4 个此前未直接测试的 `blk_v`（27/31/37/45）定向帧、全部 25 个合法 `blk_v` 的 50 帧扫描、系数无效字节 X 注入、REG_IN/REG_OUT 结构检查、性能/功耗用例的拍数与访存统计、DCG/PTPX 脚本、评分计算器。 |

## 仓库结构

```
rtl/                 交付件：img_filter.v (顶层 IMG_FILTER)、img_filter_def.v、rtl.f
verification/        自检 testbench、Python 参考模型、旋转器测试；logs/ 为本次回归日志
scripts/             Yosys 结构检查 (REG_IN/REG_OUT、无 latch/memory、逻辑深度)、
                     仿真驱动 run_sim.sh、评分计算 score.py；logs/ 为检查输出
syn/dcg/             Design Compiler Graphical 脚本 (setup / constraints / run)
syn/ptpx/            PrimeTime PX 脚本 (用例 A / B)
syn/run_all.sh       DCG -> 用例活动文件 -> PTPX -> 评分表 的一键流程
docs/                requirements_checklist.md 逐项核对 · ppa_status.md PPA 状态 · design.md 设计要点
.github/workflows/   CI：参考模型 + 13 帧 smoke + blk_v 定向帧 + 旋转器 + Yosys 检查 + lint；
                     第二个 job 跑 50 帧全 blk_v 扫描
```

## 交付件

| 文件 | 内容 |
| --- | --- |
| [`rtl/img_filter.v`](rtl/img_filter.v) | 可综合 Verilog-2001，顶层 `IMG_FILTER`，接口与题目表 1 完全一致 |
| [`rtl/img_filter_def.v`](rtl/img_filter_def.v) | `` `define MEM_NUM 49 ``、`` `define MEM_DWTH 160 `` |
| [`rtl/rtl.f`](rtl/rtl.f) | 相对路径 filelist |

## 本仓库实际运行过的验证（开源工具，全部可复跑）

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| 13 帧 smoke（`+SMOKE`） | 13 帧 / 42,972 次分量比对 / 0 错误 | `verification/logs/smoke.log` |
| `blk_v` = 27 / 31 / 37 / 45 定向（`+BLKV_GAP`） | 8 帧 / 42,072 次比对 / 0 错误 | `verification/logs/blkv_gap.log` |
| 全部合法 `blk_v` 1…49，各 2 帧（`+ALL_BLKV`） | 运行中（提交时 27/50 帧完成，0 错误）；完成后日志与掩码随后提交 | `verification/logs/all_blkv.log` |
| 完整发布回归（54 帧 + 8 帧 gap，含 1440 宽、4096 高、随机扫描） | 运行中（提交时已完成 4 帧，0 错误；日志随后更新） | `verification/logs/full.log` |
| 性能 / 功耗用例 A（1440×24，blk_v=5） | 9383 拍，41,760 次 SRAM 访存 | `verification/logs/case_a.log` |
| 功耗用例 B（1440×24，blk_v=3） | 9023 拍，25,560 次访存 | `verification/logs/case_b.log` |
| Python 参考模型：题目公式 vs 权重旋转架构，117 组形状×核 | ALL REFERENCE CHECKS PASSED | `verification/logs/reference_model.log` |
| 分裂旋转器 0…48 全移位量 | 3234 checks / 0 errors | `verification/logs/rotator_tb.log` |
| REG_IN / REG_OUT 结构检查（Yosys 网表逐位遍历） | PASSED：6 个受约束输入的每一位只到触发器 D 端；`out_pix_data` 160 位全由 Q 端驱动 | `scripts/logs/check_reg_io.log` |
| 无 latch / 无推断 memory | 断言通过；22,498 个触发器，470,032 个通用门 | `scripts/logs/synth_check.log` |
| 寄存器间逻辑深度 | 28 级通用门（MAC 第一级） | `scripts/logs/depth_ltp.txt` |
| Verilator lint | 无警告 | `scripts/logs/verilator_lint.log` |

每个仿真日志开头都记录了 RTL 与 TB 的 SHA-256 前缀，所有日志对应同一份 RTL。
testbench 特性：行为级单端口 SRAM（未写地址读出 X）、两侧随机断流/反压、行尾无效
lane 与系数无效字节注入 X、20000 拍无握手监视、首拍延时与 `blk_v` 成正比断言、
每个行边界白盒重建权重向量比对。

## 官方评分环境：脚本就绪，未运行

题目条件 → 脚本实现（[`syn/dcg/constraints.tcl`](syn/dcg/constraints.tcl)）：

| 题目 | 实现 |
| --- | --- |
| 1 GHz，不得超出 | `create_clock -period 0.900`（1.000 × (1 − 0.1 DCG margin)，`APPLY_DCG_MARGIN` 可关） |
| setup uncertainty 0.15 ns | `set_clock_uncertainty -setup 0.150` |
| ICG 额外 setup uncertainty 0.10 ns | `set_clock_gating_check -setup 0.100`（叠加在 0.15 之上） |
| N7+ H240 ssgnp 0.675 V 125 ℃，SVT/LVT/ULVT 不限比例 | `syn/dcg/setup.tcl`：`N7P_PDK_ROOT` 参数化，三种 VT 同时入 `target_library` |
| DCG 模式 | `dc_shell -topographical`，`compile_ultra -gate_clock -spg -timing_high_effort_script`，`report_congestion` |
| 功耗用例 A / B 的 PTPX | `syn/ptpx/run_ptpx.tcl`，活动文件由 `sh scripts/run_sim.sh CASE_A`（`VCD=` 环境变量）生成 |
| 评分公式与阈值 | `scripts/score.py`（手工传值或解析报告） |

```sh
N7P_PDK_ROOT=/path/to/n7p sh syn/run_all.sh     # 在有 dc_shell / pt_shell 的机器上
```

**为什么不能用上一仓库的 1 GHz 结果代替**：那是 ASAP7 预测性 PDK + OpenROAD 在快角
（FF）下、100 ps uncertainty 的收敛；同一网表在 ASAP7 慢角只有约 520 MHz。
题目要求的是 N7+ 慢角 ssgnp、0.9 ns 真实周期、0.15 ns uncertainty 的 DCG 结果，
两者不可互推。时序预算与若不收敛的对策见 [docs/ppa_status.md](docs/ppa_status.md)。

## 评分状态

```
========================================================================
IMG_FILTER score sheet   (MEM_NUM=49, MEM_DWTH=160)
========================================================================
Tx         9383000 ps  (thr 11000000)  PASS  score 30.37/30   [assumes DCG closes 1 GHz (no WNS given)]
PAx   PENDING  (needs PTPX, syn/ptpx/run_ptpx.tcl)
PBx   PENDING  (needs PTPX, syn/ptpx/run_ptpx.tcl)
Ax    PENDING  (needs DCG, syn/dcg/run_dcg.tcl)
MPx         1044.0     (ref 2400)  accesses=41760  score 10.00/10
MAx         1568.0     (ref 550)  score 1.75/10
cong  PENDING  (both / H / V from syn/dcg/reports/congestion.rpt)
------------------------------------------------------------------------
partial score 42.13 (terms available so far); PENDING: Tx: DCG slack; PAx: PTPX; PBx: PTPX; Ax: DCG area; congestion: DCG report_congestion
```

- Tx：拍数已测（任何形状下 = 理论下限 + 23 拍），频率因子待 DCG；
- MP：用例 A 假设下满分；MA：1.75/10，是为保证所有 `blk_v` 下 4 像素/拍吞吐的有意取舍
  （[docs/ppa_status.md](docs/ppa_status.md) §4）；
- PA / PB / Ax / 拥塞：待官方环境。

## 与上一仓库的关系

- RTL = v4（`vfir-7nm-rtl2gds` main `9e238d5`）+ 一处修改：`rem_q` / `rem_f` 改为从已寄存的
  `h_m1_q` 装载，使 `img_height` 端口只扇出到一个触发器（严格 REG_IN）。
  修改前 Yosys 结构检查报告该端口经 `frm_start` mux 进入两个寄存器；修改后 6 个受约束
  输入全部通过。所有回归在修改后的 RTL 上重跑。
- 开源物理实现（ASAP7 五轮、时序收敛研究、hold 研究、形式验证、等价性）保留在上一仓库，
  本仓库不重复。

## 复现

```sh
python3 verification/reference_model.py          # 参考模型
sh scripts/run_sim.sh SMOKE                      # 13 帧，Icarus 11 约 10～20 分钟
sh scripts/run_sim.sh BLKV_GAP                   # blk_v 27/31/37/45
sh scripts/run_sim.sh ALL_BLKV                   # 25 个 blk_v × 2 帧
sh scripts/run_sim.sh FULL                       # 完整回归，数小时
sh scripts/run_sim.sh CASE_A                     # 性能用例拍数与访存；VCD=case_A.vcd 可输出活动文件
sh scripts/run_yosys_checks.sh                   # REG_IN/REG_OUT、无 latch/memory、逻辑深度
python3 scripts/score.py --cycles 9383 --mp-accesses 41760
```

工具：Icarus Verilog 11 / Verilator 4.038（WSL2 Ubuntu 22.04）、Yosys 0.68；
CI 使用 Ubuntu 仓库版本。

## License

MIT — see [LICENSE](LICENSE).
