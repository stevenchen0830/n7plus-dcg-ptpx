# 兜底分支 A/B：main 与 mac4 的逐级时序（ASAP7 慢角，综合级）

本机没有 N7+ 库，但可以用开源 ASAP7 库把 `main` 和 `mac4` 两份 RTL 走**完全相同**的
综合流程（OpenROAD-flow-scripts 的 yosys + abc，SS 0.63 V / 100 ℃ RVT），再用 OpenSTA
按题目的 DCG 条件（周期 900 ps，setup uncertainty 150 ps）逐级报路径延时。

**只能看相对差，不能看绝对值**：ASAP7 慢角远慢于 N7+ ssgnp；abc 把乘法器映射成行波
结构（最差路径里有 7 个全加器串联），DC 的 DesignWare 会用 Booth + Wallace 树，
乘法部分会浅得多，所以这份对比**高估**了 MAC 在 N7+ 上的占比。

脚本：`scripts/asap7_ab/`；原始报告：`docs/asap7_ab/`。

## 1. 结果

| 流水级（起点 → 终点） | main（ps） | mac4（ps） | 说明 |
| --- | --- | --- | --- |
| **MAC1**：`rdata_q` / `ce_d2` → `pair_q`（main）或 `pplo_q/pphi_q`（mac4） | **1,308** | **810** | main 最差路径起点是 `ce_d2`（读使能掩码）：前 330 ps 是它到 160 个 AND 的扇出树，其后是乘法 + 对加 |
| MAC1 → `pair_q`（mac4 新增：lo + hi≪4 两抽头四操作数加） | — | 767 | |
| `pair_q` → `part_q`（5 操作数加） | 860 | 891 | |
| `part_q` → 输出寄存器（5 操作数加 + 64 + 饱和 + 输出选择） | 932 | 910 | |
| 旋转器 A（行参数 → 掩码 → `rot49_lo`） | 976 | 983 | **mac4 的新瓶颈** |
| 旋转器 B（`rot49_hi` + 三路 8 bit 加） | 828 | 833 | |
| 控制 → 存储命令寄存器 | 557 | 616 | |
| 最差 slack（要求约 722 ps） | −586 | **−262** | |
| TNS | −2.64 µs | −1.61 µs | |
| 综合面积（µm²） | 43,172 | 53,477（**+24 %**） | |
| 触发器 | 22,090 | 44,891（+22.8 k） | |

## 2. 结论

1. **mac4 有效但有上限。** 最差路径 1,308 → 983 ps（−25 %），MAC1 降到 810 ps 后不再是
   瓶颈；新的限制是旋转器 A 级（983 ps），输出级（910）和 `pair_q → part_q`（891）
   紧随其后。也就是说，无论 MAC 再怎么拆，这个设计在当前流水划分下的收益到旋转器 A
   为止；再往下要同时拆旋转器 A、输出级和部分和级，代价成倍增加。
2. **代价是面积 +24 %。** 按评分公式 A0/Ax × 30：若 N7+ 面积同比例变化，面积项约从
   20.8 分降到 16.8 分（−4 分）；功耗也会随寄存器数上升。
3. **切换判据**（用例 A 9,383 拍）：DCG slack ≥ −100 ps 一分不扣，不切；−100～−200 ps
   损失 0～5 分，与 mac4 的面积损失相当，看 DCG 报的路径是否在 MAC1 上再决定；
   slack < −200 ps 或 < −272 ps（判零线）时切 mac4。切换前先试 `DCG_RETIME_MAC=1`
   （流程级重定时，零面积代价）。
4. **第一版 mac4（只把 18 bit 乘积寄存）无效**：裸乘法器本身与"乘加"一样深，Yosys 深度
   只从 28 级降到 27 级；改成把 8 bit 系数拆成两个 4 bit 半乘后才有上面的结果。
   Yosys 的通用门"层数"对乘法器不敏感，评估这类改动必须用带库的时序分析。

## 3. 顺带发现：`ce_d2` 扇出（main 的廉价优化点，未实施）

main 最差路径的前 330 ps 花在 `ce_d2[k]` 到该 bank 160 个数据 AND 门的缓冲树上，
从 `rdata_q` 出发的同一终点只有 1,159 ps。把 `ce_d2` 按 lane 复制成 16 份
（+735 个触发器，约 +3 %），每份只驱动 10 个 AND，可省掉大部分缓冲级。
DC 自己会做扇出缓冲，N7+ 上这一项估计在 100 ps 量级，但不是零。
因为完整回归正在当前 main RTL 上运行，这个改动没有做，留作下一步。

## 4. 复现

```sh
# 在有 OpenROAD-flow-scripts (ORFS) 的机器上，ORFS 根目录含 flow/platforms/asap7
sh scripts/asap7_ab/ab_synth.sh main /path/to/n7plus-dcg-ptpx        # ~7 min
sh scripts/asap7_ab/ab_synth.sh mac4 /path/to/n7plus-dcg-ptpx-mac4   # ~9 min
sh scripts/asap7_ab/ab_sta.sh main     # -> docs/asap7_ab/main_sta.log 的内容
sh scripts/asap7_ab/ab_sta.sh mac4
```

`ab_sta.tcl` 里的分级用寄存器名正则（OpenSTA 的 `-regexp` 要求全名匹配），
换 RTL 版本时按实际寄存器名调整。
