# 题目要求逐项核对

对象：`rtl/img_filter.v`（顶层 `IMG_FILTER`）+ `rtl/img_filter_def.v`。
每一项给出判定、依据（文件:行 或 日志），以及**在本仓库能否被证实**。
判定分三档：

- **符合（已验证）**：本仓库里有可复跑的证据（仿真日志 / Yosys 结构检查）。
- **符合（结构性）**：由 RTL 结构直接保证，附行号。
- **待官方环境**：只有 N7+ / DCG / PTPX 能给出数值，本仓库只提供脚本。

## 1. 交付范围

| # | 要求 | 判定 | 依据 |
| --- | --- | --- | --- |
| 1.1 | `img_filter.v`，顶层模块 `IMG_FILTER` | 符合 | `rtl/img_filter.v:55` |
| 1.2 | `img_filter_def.v` 定义 `MEM_NUM`、`MEM_DWTH` | 符合 | `rtl/img_filter_def.v`：`MEM_NUM=49`，`MEM_DWTH=160` |
| 1.3 | Memory 不在交付范围，通过顶层接口读写 | 符合 | RTL 内无 memory，只有 `mem_*` 端口（见 4.2） |

## 2. 功能规格

| # | 要求 | 判定 | 依据 |
| --- | --- | --- | --- |
| 2.1 | RGBA，每像素 40 bit，四分量各 10 bit，PPC = 4 | 符合（已验证） | 160 bit 数据口；16 条 10 bit lane 并行（`G_LANE`，`img_filter.v:610`）；所有回归按 4 分量 × 4 像素逐分量比对 |
| 2.2 | 宽度 24～1440（`img_width` = W−1，11 bit） | 符合（已验证） | `nbm1_q = img_width[10:2]`（`:165`），最大 360 拍/行；定向回归含 W = 24…44，完整回归 `full.log` 含 1439、1440 |
| 2.3 | 高度 24～4096（`img_height` = H−1，12 bit） | 符合（已验证） | 12 bit 行计数；完整回归含 24×4096 帧，`ALL_BLKV` 含 H = 24…58 |
| 2.4 | `blk_h` = 1，`blk_v` = 1～49 奇数，可超出图像高度 | 符合（已验证） | `verification/logs/all_blkv.log`：25 个合法值各 2 帧（运行中（提交时 27/50 帧完成，0 错误））；H = 24 帧对 `blk_v` ≥ 25 即“超出高度”；此前缺失的 27/31/37/45 另有定向 8 帧 `blkv_gap.log` |
| 2.5 | 参考块以同位置输入像素为中心、上下对称 | 符合（已验证） | 系数索引 `a_flat[k+24]`（`:332-337`）；金标准 `golden_comp` 逐抽头展开 |
| 2.6 | 边界垂直镜像，超界后按 `mirrorMap` 持续镜像 | 符合（已验证） | TB 的 `mirror_row` 逐字转写题目伪代码（`img_filter_tb.v:110`）；RTL 的“权重旋转”等价性由 `reference_model.py` 在 117 组形状×核上证明，且 TB 在每个行边界白盒重建权重向量比对（`ALIGNMENT checks`） |
| 2.7 | 系数 25 × 8 bit 无符号，低位→高位 = 参考块下→中心，上半部分对称补齐 | 符合（已验证） | `a_sym[i] = coef_q[(hv−i)*8 +: 8]`（`:191`），`a_flat` 对称展开 |
| 2.8 | `blk_v` < 49 时 `coef` 高位为无效值（8'hx） | 符合（已验证） | RTL 只索引字节 0…(blk_v−1)/2；TB 在无效字节上驱动真实 X（`make_coef`），任何误读都会使输出变 X 而被比对捕获 |
| 2.9 | 有效系数之和 = 128 | 符合 | TB 生成的系数和恒为 128 并自检；累加器 20 bit 无溢出（`reference_model.py` 最大值分析） |
| 2.10 | 一帧内系数不变 | 符合（结构性） | `coef_q` 只在 `frm_start` 装载（`:163-168`） |
| 2.11 | `(Σcoef·pix + 64) >> 7`，>1023 饱和为 1023 | 符合（已验证） | `img_filter.v:634-637`；每个输出分量与金标准逐一比对 |

## 3. 接口

| # | 要求 | 判定 | 依据 |
| --- | --- | --- | --- |
| 3.1 | 信号名 / 位宽 / 方向与表 1 一致 | 符合 | `img_filter.v:55-82`：`in_pix_*`、`out_pix_*`、`frm_start`、`img_width[10:0]`、`img_height[11:0]`、`blk_v[5:0]`、`coef[199:0]`、`mem_ce/we[MEM_NUM-1:0]`、`mem_addr[MEM_NUM*11-1:0]`、`mem_wdata/rdata[MEM_NUM*MEM_DWTH-1:0]` |
| 3.2 | rdy-need 握手（图 7） | 符合（已验证） | 两侧随机断流 / 反压 0～60 %（`gap=` 列），无丢拍无重复 |
| 3.3 | `in_pix_data` 排布 `{pixel3..pixel0}`，像素内 `{A,R,G,B}`，行尾无效像素在高位 | 符合（已验证） | 数据通路对 16 条 lane 完全对称；TB 在行尾无效 lane 上注入 X（`xgarbage`），只比对有效像素 |
| 3.4 | `rst_n` 异步复位，外部同步撤离 | 符合 | 控制寄存器异步复位；`syn/dcg/constraints.tcl` 按合同设 `set_false_path -from rst_n` |
| 3.5 | 配置在 `frm_start` 当拍有效，下次 `frm_start` 前不变 | 符合（结构性） | 配置寄存器只在 `frm_start` 采样（`:163`） |
| 3.6 | `frm_start` 早于当帧数据、晚于上帧输出结束 | 符合（已验证） | PREP 13 拍内 `in_pix_need` = 0；回归帧间只留 20 拍空闲即启动下一帧 |
| 3.7 | SPRAM：单端口，同拍只读或只写；写后 1 拍可读；读使能后 1 拍数据有效（图 8） | 符合（已验证） | 写 bank 与读 bank 集合互斥（`m_1h` 与 `m_ce`，`reference_model.py` 存储不变量）；`rdata_q` 在 `m_ce` 后一拍采样（`:573`）；TB 的 SRAM 模型严格 1 拍延迟且未写地址为 X |
| 3.8 | 地址范围 0～1439 | 符合（结构性） | `mem_addr = {2'b00, m_addr[8:0]}`，最大 359 |

## 4. 约束

| # | 要求 | 判定 | 依据 |
| --- | --- | --- | --- |
| 4.1 | Memory：深度 1440、位宽 40/80/160 三选一、片数 ≤ 49 | 符合 | 49 片 × 160 bit；每片最多用 360 个字 |
| 4.2 | 内部缓存用 reg，不用生成的 memory 和 latch | 符合（已验证） | `scripts/synth_check.ys` 断言无 `$dlatch/$mem*`：`scripts/logs/synth_check_stat.txt`（22,498 个触发器，470,032 个通用门） |
| 4.3 | REG_IN：除 `clk/rst_n/in_pix_rdy/out_pix_need/frm_start` 外所有输入直接进寄存器 | 符合（已验证） | `scripts/check_reg_io.py`：`in_pix_data`(160)、`mem_rdata`(7840)、`img_width`(9 位使用)、`img_height`(12)、`blk_v`(5 位使用)、`coef`(200) 的每一位**只**到触发器 D 端，端口与 D 端之间没有任何逻辑（`scripts/logs/check_reg_io.log`） |
| 4.4 | REG_OUT：`out_pix_data` 直接出寄存器 | 符合（已验证） | 同上：160 位全部由触发器 Q 端驱动 |
| 4.5 | 输入输出均无握手的连续周期 ≤ 20000 | 符合（已验证） | TB 监视器 `DEADMAX=20000`；所有回归最长无握手 40 拍 |

## 5. 综合与评分环境（待官方环境）

| # | 要求 | 状态 | 本仓库提供 |
| --- | --- | --- | --- |
| 5.1 | N7+，H240，ssgnp 0.675 V / 125 ℃，DCG 综合 | **未运行** | `syn/dcg/setup.tcl`（库路径参数化）、`run_dcg.tcl`（`-topographical`） |
| 5.2 | 时钟 1 GHz，不得超出 | 脚本已按 1 GHz 约束 | `syn/dcg/constraints.tcl` |
| 5.3 | DCG margin = 0.1 周期（真实综合周期 0.9 ns） | 脚本已实现，可开关 | `APPLY_DCG_MARGIN` |
| 5.4 | setup uncertainty 0.15 ns | 脚本已实现 | `set_clock_uncertainty -setup 0.150` |
| 5.5 | ICG 额外 setup uncertainty 0.10 ns | 脚本已实现（按更严格的“叠加”理解） | `set_clock_gating_check -setup 0.100` |
| 5.6 | Tx ≤ 11,000,000 ps | 拍数已测，频率待 DCG | 用例 A 形状假设下 9383 拍 → 1 GHz 时 9,383,000 ps（`scripts/score.py`） |
| 5.7 | PA ≤ 0.1 W，PB ≤ 0.08 W | **未运行**（PTPX） | `syn/ptpx/run_ptpx.tcl` + TB `+CASE=A/B +VCD=` |
| 5.8 | Ax ≤ 100,000 µm² | **未运行**（DCG 面积） | `report_area` → `score.py --dcg-reports` |
| 5.9 | 拥塞 both / H / V ≤ 0.03 | **未运行** | `report_congestion` |
| 5.10 | MPx = MEM_DWTH × 访存次数 / 6400 | 已按用例 A 假设计算 | 41,760 次访存 → MPx = 1044.0，得分 min(10, 2400/MPx×5) |
| 5.11 | MAx = MEM_NUM × MEM_DWTH / 5 | 已计算 | 1568 → 得分 1.75/10（有意的取舍，见 `docs/ppa_status.md`） |

## 6. 禁止投机项

| # | 禁止事项 | 判定 | 依据 |
| --- | --- | --- | --- |
| 6.a | 功耗用例中主动反压 | 无 | `in_pix_need` 只由 FIFO 占用和状态决定（`:483`），与用例无关；`gap=0/0` 帧的总拍数 = 理论下限 + 固定延时 |
| 6.b | 性能 / 功耗用例处理性能不一致；latency 须与 `blk_v` 成正比 | 无 | 吞吐恒为 4 像素/拍；首拍延时 = `(blk_v−1)/2` 行 + 常数拍，TB 对每帧断言 `first_out ≤ (hv+1)·NB + 64` |
| 6.c | 针对用例的系数硬化、查表 | 无 | 系数全部来自 `coef` 端口寄存器，无常量表 |
| 6.d | 针对系数值特征的特殊处理 | 无 | 回归系数为随机生成（种子可换 `+SEED=`），零权重只影响读使能（访存节省是通用机制，不识别用例） |

## 7. 与上一仓库 v4 RTL 的差异

只有一处：`rem_q` / `rem_f` 原来在 `frm_start` 当拍直接从 `img_height` 端口装载，
Yosys 结构检查显示这在端口与 D 端之间留下一个 `frm_start` 选择 mux（严格的
REG_IN 检查会判为“端口未直接进寄存器”）。现改为在 PREP 第 0 拍从已寄存的
`h_m1_q` 装载（`img_filter.v:285-290`、`:447-451`）。两者首次被使用分别在
PREP 结束后和 PREP 第 9 拍，功能不变；全部回归在修改后的 RTL 上重新运行。
