# PPA 状态：什么已测、在哪测的、还差什么

## 1. 三类数据，不要混用

| 来源 | 内容 | 可信度 | 位置 |
| --- | --- | --- | --- |
| **本仓库（开源工具）** | 功能正确性、REG_IN/REG_OUT、无 latch/memory、逻辑深度、性能用例拍数、MP/MA 公式项 | 可复跑 | `verification/logs/`、`scripts/logs/` |
| **上一仓库（ASAP7 + OpenROAD）** | 1 GHz 在快角（FF/BC，100 ps uncertainty）收敛；真实慢角约 520 MHz；45.6 mW（vectorless）；后布线 47,297 µm²；拥塞 0 溢出 | 真实物理实现，但**工艺不是 N7+**，不能替代评分数据 | [vfir-7nm-rtl2gds](https://github.com/stevenchen0830/vfir-7nm-rtl2gds) |
| **官方 N7+ / DCG / PTPX** | Tx 收敛频率、PA/PB、Ax、拥塞 | **尚未运行** | `syn/`（脚本就绪） |

结论：**功能与接口层面满足题目；PPA 六项中只有 MA、MP、性能用例拍数在本仓库落地，
Tx 的频率因子、PA、PB、Ax、拥塞必须在官方环境跑 `syn/run_all.sh` 才能定论。**

## 2. DCG 时序预算（为什么不能宣称 1 GHz 已收敛）

题目条件换算：

```
设置周期            1.000 ns
DCG margin 10 %     -0.100 ns  ->  真实综合周期 0.900 ns
setup uncertainty   -0.150 ns
可用逻辑时间         0.750 ns  (再减 clk->q 与 setup, 约 0.65 ns 留给组合逻辑)
```

本 RTL 最长寄存器间路径为 28 级通用门（`scripts/logs/depth_ltp.txt`，
AND/NAND/OR/NOR/XOR/XNOR/MUX/AOI/OAI 计数），落在 MAC 第一级
（10 bit × 8 bit 乘法 + 一次加法，`pair_q`）。0.65 ns / 28 ≈ 23 ps/级。
N7+ ssgnp 0.675 V / 125 ℃ 下 ULVT 简单门约 20～30 ps，DCG 会用 DesignWare 乘法器
重构算术路径，所以**有机会收敛但没有余量可言**；ASAP7 慢角的 520 MHz 极限说明
在预测性 7 nm 库上是收敛不了的，但 ASAP7 慢角远慢于真实 N7+，不能外推。

如果官方 DCG 报告 `Critical Path Slack` 为负：

1. `scripts/score.py --wns <slack>` 会按“收敛周期 = 0.9 ns − slack”折算 Tx，
   只要 Tx ≤ 11,000,000 ps 就不判零；用例 A 假设下 9383 拍允许周期最大
   约 1,172 ps（即 slack ≥ −272 ps 仍达标）。
2. 得分敏感度：slack ≥ −100 ps 时收敛周期仍 ≤ 1 ns，按 1 GHz 计，一分不扣；
   slack = −200 ps 时周期 1.1 ns，Tx = 10.32e6，性能项 30 → 27.6，PA/PB 项同比缩
   8 %，总共约 −5 分；slack < −272 ps 才判零。
3. 两级兜底（都不改 REG_IN/REG_OUT，不改吞吐）：
   - 流程级：`DCG_RETIME_MAC=1`，`run_dcg.tcl` 把除 MAC 流水寄存器外的所有寄存器
     `set_dont_retime`，再 `compile_ultra -retime`，让 DC 把 `pair_q/part_q` 移进乘加树。
     不改 RTL、不重跑回归、面积基本不变。
   - RTL 级：`mac4` 分支，50 个 10×8 乘积先寄存，MAC 四级流水。最深级从
     "乘法 + 对加 + 20 bit 进位链" 变成裸乘法；代价 +16×50×18 bit ≈ 14k 触发器
     （主分支 22.5k），+1 拍延时，面积项估计少 3～4 分。只有当负 slack 造成的损失
     大于这 3～4 分时才值得切换。

## 3. 性能与功耗用例的假设

官方用例形状未公布。已知参考设计的性能用例耗时 T0 = 9,500,000 ps ≈ 9,500 拍，
而 1440 × 24 的图像刚好 8,640 个输出拍：

| 用例 | 假设形状 | 本设计拍数 | Tx @ 1 GHz | 备注 |
| --- | --- | --- | --- | --- |
| A（= 性能用例） | 1440 × 24，blk_v = 5 | 9383 | 9,383,000 ps | `(H + (blk_v−1)/2) × ⌈W/4⌉ + 23` |
| B | 1440 × 24，blk_v = 3 | 9023 | — | 只用于 PTPX 活动文件 |

任何形状下本设计的拍数都是 `(H + hv)·⌈W/4⌉ + 23`：前一项是任何 4 像素/拍设计
都无法避免的下限（输出拍数 + `blk_v` 决定的填充延时），只多 23 拍（PREP 13 拍 + 流水线与握手边沿）。
因此不论官方用例是什么形状，`Tx ≤ T0 + 23,000 ps = 9,523,000 ps < Tmax`——
前提是 DCG 在 1 GHz 收敛。

外部存储功耗项（用例 A）：41,760 次访存 → MPx = 160 × 41,760 / 6400 =
1044.0，得分 min(10, 2400 / 1044.0 × 5) = 10.00。
访存次数随 `blk_v` 线性变化（每输出拍 `blk_v − 1` 读 + 1 写，零权重不读），
与 `MEM_NUM` 无关。

## 4. MA 项：1.75 / 10 是有意的取舍

`MAx = 49 × 160 / 5 = 1568`，对参考值 550 只拿 1.75 分。原因：

- 4 像素/拍 × 49 抽头需要**同一拍 48 次读 + 1 次写**，单端口 SRAM 每片每拍只能
  做一件事，49 片是维持吞吐的最小片数；`MEM_DWTH = 160` 让一个字正好是一个
  4 像素拍，任何更窄的配置都要把一拍拆成多次访问，吞吐减半或减四分之一。
- 性能项权重 30 且有硬阈值（Tmax 判零），MA 权重 5 且封顶 10 分。用 5 分左右的
  MA 换所有 `blk_v` 下有保证的吞吐，是期望值更高的选择。
- 若官方性能用例的 `blk_v` 很小，把 `MEM_NUM` 降到略大于该 `blk_v` 可以拿回
  MA 分，但那是针对用例的调整，题目明确禁止。

## 5. 功耗（PA / PB）能说什么

不能给数值。可以说的结构性事实：

- 使能寄存器全部写成 `if (en) q <= d`，`compile_ultra -gate_clock` 会推断 ICG；
  ASAP7 上开启门控后 vectorless 功耗从 3.28 W 降到 45.6 mW（上一仓库 base → v4）。
- 未读 bank 的读数据被掩零，不进入乘法树；只有被写的 bank 看到写数据；
  零权重的 bank 不发读使能——活动率随 `blk_v` 缩放。
- PTPX 需要活动文件：`sh scripts/run_sim.sh CASE_A`（设 `VCD=` 环境变量即输出
  VCD），`syn/ptpx/run_ptpx.tcl` 用 `read_vcd -strip_path img_filter_tb/u_dut`
  读入。RTL 级 VCD 的寄存器名与 DCG 网表一致（`change_names -rules verilog`），
  综合新增的内部网络由 PT 从已标注寄存器传播。

## 6. 评分表当前状态

`python3 scripts/score.py --cycles 9383 --mp-accesses 41760`：

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

官方环境跑完后：
`python3 scripts/score.py --dcg-reports syn/dcg/reports --ptpx-reports syn/ptpx/reports --sim-log verification/logs/case_a.log`
（报告解析用正则，首次使用请对照真实报告核对一次）。
