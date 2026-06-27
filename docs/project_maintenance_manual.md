# Project Documentation Maintenance Manual

本文档用于维护 `rv32i_int8_dsc_cnn_accelerator` 的文档体系，回答三个问题：

1. 哪些文档是必要的。
2. 哪些文档已经重复、可合并或可删除。
3. 每次更新 RTL、firmware、模型、仿真或综合结果时，应该同步维护哪些文档。

## 文档分层原则

本项目文档应分成四层：

| 层级 | 作用 | 维护原则 |
| --- | --- | --- |
| 入口层 | 让新读者快速理解项目状态和怎么运行 | 只保留当前事实，不堆历史细节 |
| 规格层 | 记录接口、模块契约、量化、ISA、验证标准 | 只要代码接口或行为变化就必须同步更新 |
| 证据层 | 记录仿真、综合、资源、性能结果 | 每次重新跑实验后更新摘要，不手写无法复现的数字 |
| 历史层 | 记录推进过程、问题定位和阶段性决策 | 追加为主，避免反复改写历史 |

生成物应优先放在 `build/` 下，由 `.gitignore` 忽略。`docs/` 下只放人工维护的说明、规格、报告摘要和少量必须长期保存的证据快照。

## 必要文档

这些文档建议长期保留，并作为项目文档的核心。

| 文档 | 定位 | 何时必须更新 |
| --- | --- | --- |
| `README.md` | 项目入口、当前状态、快速运行命令、最近验证快照 | 每次改变用户可见能力、运行方式、当前验证数字或下一步方向 |
| `docs/module_design_contracts.md` | RTL 模块接口、事务边界、延迟、backpressure、资源期望的主规格 | 任意 RTL 接口、握手、延迟、buffer 容量、读写语义变化 |
| `docs/verification_plan.md` | 分阶段验证计划和 regression 入口 | 新增/删除 testbench、修改验收标准、改变 regression 脚本参数 |
| `docs/known_limits_next_steps.md` | 当前限制和短版优化 backlog | 完成一个限制项、发现新阻塞、改变优化优先级 |
| `docs/development_log.md` | 追加式开发日志和问题定位记录 | 完成一个可验证阶段、定位重要 bug、获得重要实验结果 |
| `docs/project_next_optimization_bringup_guide.md` | 长版优化、综合、上板、报告建设路线图 | 综合状态、上板计划、优化策略发生大变化 |
| `docs/architecture_diagrams.md` | Mermaid 架构图、数据流图、验证闭环图源文件 | datapath/control path/verification flow 改变 |
| `docs/synthesis_vivado_summary.md` | Vivado 综合结果短版汇总 | 每次新的 Vivado OOC/full-top 结果产生后 |
| `docs/synthesis_verification_report.md` | 综合验证长报告，解释资源风险和阻塞点 | 新增 full-top synthesis、timing、post-route、关键资源结论 |

## 有条件保留文档

这些文档当前仍有价值，但应设置退出条件，避免永久堆积。

| 文档 | 当前价值 | 后续处理 |
| --- | --- | --- |
| `docs/dw_stream_engine_refactor.md` | 记录 streaming DW candidate 的数据流、握手和剩余集成工作 | 新路径接入 DSBlock 主路径后，将稳定接口合并进 `module_design_contracts.md`，本文改为历史设计记录 |
| `docs/dw_tile_buffer_bram.md` | 记录 BRAM tile buffer 的 layout、接口、Vivado 证据 | 接入主路径后仍可保留，作为 BRAM buffer 专题设计说明 |
| `docs/quantization.md` | 量化格式短规格 | 当前太短，建议扩写为完整量化规格；否则并入 README 和 module contracts |
| `docs/isa_custom.md` | custom instruction 和 NPC custom port 说明 | 若 ISA 稳定，可保留；若 README 已覆盖全部内容，可并入 README 的 CPU/Firmware 部分 |
| `docs/synthesis_initial.md` | Yosys 未安装的真实尝试记录 | 安装 Yosys 并产出真实报告后替换；否则可并入 `synthesis_verification_report.md` 的历史段落 |
| `docs/synthesis_vivado_initial.md` | full `cnn_top` Vivado 初次尝试快照 | 新 full-top 结果产生后归档或删除，由 `synthesis_vivado_summary.md` 取代 |

## 可合并、归档或删除的文档

这些文件不是长期维护的好位置。

| 文档 | 判断 | 建议 |
| --- | --- | --- |
| `docs/architecture.md` | 内容很短，已经被 README 和 `architecture_diagrams.md` 覆盖 | 删除，或改成指向 README/architecture diagrams 的索引 |
| `docs/network_spec.md` | 只说明网络类型，具体 shape 已在 README | 删除，或扩写成真正的网络/descriptor 规格 |
| `Project/项目描述.txt` | 当前为空文件 | 删除 |
| `Project/改动说明以及一些问题.txt` | 临时问题单，内容已被 `development_log.md` 和 `module_design_contracts.md` 覆盖 | 删除；若仍有未解决问题，迁移到 `known_limits_next_steps.md` |
| `docs/rv32i_int8_cnn_project_ppt.pptx` | 二进制 PPT，不适合作为源文档；当前工作区中已被删除 | 若需要 PPT，保留生成脚本和可编辑源；否则从 git 删除 |
| `docs/synthesis_vivado_<module>.md` 单模块快照 | 多数是脚本生成模板，内容与 `build/reports/vivado_<module>/` 和 summary 重复 | 可迁移到 `build/` 作为生成物；`docs/` 下只保留 summary 和必要的特殊设计说明 |

## 当前单模块综合快照处理建议

`docs/synthesis_vivado_requant_activation_unit.md`、`docs/synthesis_vivado_pw_systolic_array_8x8.md`、`docs/synthesis_vivado_dw_mac_lanes.md`、`docs/synthesis_vivado_feature_sram_bank.md`、`docs/synthesis_vivado_dw_tile_buffer.md`、`docs/synthesis_vivado_dw_tile_fusion_engine.md`、`docs/synthesis_vivado_ds_block_tile_engine.md`、`docs/synthesis_vivado_dw_tile_buffer_bram.md` 均属于单模块 Vivado OOC 快照。

建议规则：

- 若这些文件由脚本自动生成，则不要长期人工维护，后续可移动到 `build/reports/`。
- `docs/synthesis_vivado_summary.md` 保留表格摘要和结论。
- 对有架构意义的结果，在专题设计文档中保留解释，例如 `dw_tile_buffer_bram.md` 中保留 BRAM 映射证据。
- 重新跑综合后，先更新 summary，再决定是否保留某个单模块快照。

## 更新文档的触发矩阵

| 改动类型 | 必改文档 | 视情况更新 |
| --- | --- | --- |
| RTL 模块接口、握手、延迟改变 | `module_design_contracts.md`, `verification_plan.md` | README、architecture diagrams、development log |
| 新增或替换主数据路径模块 | README, `module_design_contracts.md`, `verification_plan.md`, `development_log.md` | `known_limits_next_steps.md`, refactor 专题文档 |
| 修改 custom instruction、MMIO、firmware ABI | README, `isa_custom.md`, `module_design_contracts.md`, `verification_plan.md` | development log |
| 修改量化算法、scale/zero point、requant | README, `quantization.md`, `module_design_contracts.md`, Python golden 注释 | verification plan、development log |
| 新增 testbench 或 regression 参数 | `verification_plan.md`, README 快速开始或最近验证 | development log |
| 重新导出模型 checkpoint | README 的模型摘要、development log | `known_limits_next_steps.md`、accuracy/perf 报告 |
| 新增多样本 RTL/CPU 验证结果 | README 最近验证快照、development log | verification plan |
| 重新跑 Vivado/Yosys synthesis | `synthesis_vivado_summary.md`, `synthesis_verification_report.md`, README 资源/限制摘要 | `known_limits_next_steps.md`, bring-up guide |
| 发现新限制或完成优化项 | `known_limits_next_steps.md`, README 下一步 | bring-up guide、development log |
| 准备答辩/PPT | README、architecture diagrams、synthesis summary | PPT 生成脚本和结果页 |

## 推荐维护流程

每次做项目更新时按下面流程走：

1. 查看工作区状态。

```bash
git status --short --branch
```

2. 判断改动属于哪类：RTL、firmware、Python/model、仿真、综合、文档。

3. 运行最小验证。

常用命令：

```bash
./scripts/run_sim.sh tb_requant_activation_unit
./scripts/run_sim.sh tb_cnn_top_fullnet_sram_datapath
./scripts/run_sim.sh tb_npc_rv_core_cnn_top_fullnet
SIM_ONLY="tb_npc_cnn_custom_bridge tb_npc_bridge_cnn_top_fullnet" ./scripts/run_all_sims.sh
SAMPLES=3 START_INDEX=0 ./scripts/run_multi_sample_rtl.sh
./scripts/run_resource_report.sh
```

4. 按触发矩阵更新文档。

5. 搜索旧数字和旧结论，避免 README 与历史报告混用。

```bash
rg -n "1085562|1033722|10907a82|0fc5fa82|3501306|356cfa82" README.md docs
rg -n "word-per-int8|packed NHWC|BRAM|full top|argmax|checkpoint_eval_acc" README.md docs
```

6. 检查 markdown 和 diff。

```bash
git diff --check -- README.md docs
git diff -- README.md docs
```

7. 只提交相关文件，不把无关删除、未跟踪 RTL 或 build 生成物混进提交。

```bash
git add README.md docs/<changed-doc>.md
git commit -m "Update documentation for <topic>"
```

## 文档去重计划

建议分两轮清理，避免一次删太多影响追溯。

第一轮：低风险清理。

1. 删除空文件 `项目描述.txt`。
2. 删除或迁移 `改动说明以及一些问题.txt`。
3. 删除或改成索引的 `docs/architecture.md`、`docs/network_spec.md`。
4. 确认是否需要恢复或正式删除 `docs/rv32i_int8_cnn_project_ppt.pptx`。

第二轮：综合报告归档。

1. 保留 `docs/synthesis_vivado_summary.md` 和 `docs/synthesis_verification_report.md`。
2. 把单模块 `docs/synthesis_vivado_<module>.md` 迁移到 `build/reports/` 或 `docs/archive/synthesis/`。
3. 若要保留可复现实验证据，确保脚本能重新生成这些快照。
4. README 只引用 summary，不逐个引用单模块快照。

## README 更新规则

README 只写当前事实：

- 当前项目能做什么。
- 当前怎么运行。
- 当前最近一次验证快照是什么。
- 当前主要限制是什么。
- 下一步最重要的工作是什么。

不要在 README 中堆：

- 过多历史过程。
- 多套过期 cycle/status/argmax 数字。
- 自动生成报告全文。
- 不可复现的资源估计。

如果新结果和旧结果并存，README 只保留最新可信结果；旧结果进入 `development_log.md`。

## Development Log 规则

`development_log.md` 是追加式历史账本，不是当前状态页。

每次追加建议包含：

```text
## YYYY-MM-DD: 标题

目标:
- ...

实现:
- ...

验证:
- 命令
- PASS/FAIL
- 关键数字

结论:
- ...

保留问题:
- ...
```

不要在 development log 里反复修改旧段落，除非旧段落明显错误并会误导后续开发。

## Module Contract 规则

修改 RTL 后，如果以下任一项变化，就必须更新 `module_design_contracts.md`：

- port 名称或宽度。
- start/done/valid/ready 语义。
- 固定延迟或可变延迟。
- memory 容量、读延迟、read-during-write 语义。
- backpressure 支持方式。
- 测试向量来源。
- 资源期望或综合证据。

## 综合报告规则

综合结果要区分三种口径：

1. 静态估算：来自 `resource_estimate.md`，不是工具结果。
2. OOC synthesis：代表模块综合结果，不等价于 full top。
3. implementation/timing：place/route 后结果，当前尚未完成。

文档里必须写清楚：

- 工具版本。
- part。
- clock constraint。
- top module。
- 是否 OOC。
- 是否有 timing-capable part。
- 是否 post-route。
- 报告来源路径。

## 当前建议的最终文档布局

```text
README.md
docs/
  architecture_diagrams.md
  module_design_contracts.md
  verification_plan.md
  quantization.md
  isa_custom.md
  known_limits_next_steps.md
  development_log.md
  project_next_optimization_bringup_guide.md
  project_maintenance_manual.md
  synthesis_verification_report.md
  synthesis_vivado_summary.md
  dw_stream_engine_refactor.md
  dw_tile_buffer_bram.md
```

其余文档应逐步删除、合并、归档，或改成由脚本生成的 `build/` 产物。
