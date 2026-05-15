# pitfall-database.md — matlab-agent 踩坑数据库

> 本文件是 matlab-agent 踩坑经验的结构化数据库。
> 由自我改进机制（Layer 4: 系统进化）维护。
> 
> 分区说明：
> - ACTIVE: 当前仍然适用的踩坑条目
> - COLD: 已归档的过时踩坑（如旧版 API 问题已被新版本修复）

---

## 活跃踩坑 (ACTIVE)

### [PIT-001] struct() 构造时 cell 字段展开为空数组
- **Pattern-Key**: pitfall.struct_expand
- **优先级**: critical
- **首次发现**: 2026-04-16
- **最后发现**: 2026-04-18
- **出现次数**: 5
- **影响 API**: sl_bus_create, sl_profile_sim, sl_profile_solver, sl_baseline_test
- **症状**: `struct('field', cellVal)` 导致 1x0 struct
- **正确做法**: 分步赋值 `s=struct(); s.field=cellVal`
- **自动修复**: Bridge _auto_fix_args() 检测并提示
- **SKILL.md 条目**: #16, #23

### [PIT-002] .m 文件中 4 字节 UTF-8 emoji 导致解析失败
- **Pattern-Key**: pitfall.emoji
- **优先级**: high
- **首次发现**: 2026-04-18
- **最后发现**: 2026-04-18
- **出现次数**: 3
- **影响 API**: 所有 .m 文件编写场景
- **症状**: "文本字符无效" 错误
- **正确做法**: 用 ASCII 标记如 [OK][X][WARN] 代替 emoji
- **自动修复**: 提示词层拦截
- **SKILL.md 条目**: #21

### [PIT-003] sl_set_param_safe 的 params 必须是 struct 不是 Name-Value 对
- **Pattern-Key**: pitfall.params_not_struct
- **优先级**: critical
- **首次发现**: 2026-04-17
- **最后发现**: 2026-04-18
- **出现次数**: 4
- **影响 API**: sl_set_param_safe, sl_config_set
- **症状**: MATLAB 报错参数名不是有效模块路径
- **正确做法**: `sl_set_param_safe('path', struct('Gain','5'))`
- **自动修复**: Bridge _auto_fix_args() 自动转换
- **SKILL.md 条目**: #7

### [PIT-004] sl_block_registry 必须传 shortName 参数
- **Pattern-Key**: pitfall.registry_no_args
- **优先级**: high
- **首次发现**: 2026-04-16
- **最后发现**: 2026-04-18
- **出现次数**: 3
- **影响 API**: sl_block_registry
- **症状**: 无参调用报错
- **正确做法**: `sl_block_registry('Gain')`
- **自动修复**: Bridge _auto_fix_args() 自动设置 shortName=''
- **SKILL.md 条目**: #8

### [PIT-005] sl_add_line 5参数格式不支持 autorouting
- **Pattern-Key**: pitfall.addline_5arg
- **优先级**: high
- **首次发现**: 2026-04-17
- **最后发现**: 2026-04-18
- **出现次数**: 3
- **影响 API**: sl_add_line_safe
- **症状**: add_line 5参数格式连线不自动路由
- **正确做法**: 使用字符串格式 `add_line(sys,'Block/1','Block/1','autorouting','on')`
- **自动修复**: Bridge 使用格式2，自动合并 srcBlock+srcPort
- **SKILL.md 条目**: #19, #25

### [PIT-006] find_system SearchDepth 必须在 Simulink 参数名之前
- **Pattern-Key**: pitfall.find_system_depth
- **优先级**: high
- **首次发现**: 2026-04-16
- **最后发现**: 2026-04-16
- **出现次数**: 2
- **影响 API**: sl_inspect_model, sl_find_blocks, sl_validate_model
- **症状**: SearchDepth 参数不生效或报错
- **正确做法**: `find_system(model, 'SearchDepth', 1, 'BlockType', 'Gain')`
- **自动修复**: 无（需在 .m 函数中正确使用）
- **SKILL.md 条目**: #2

### [PIT-007] Simulink.Mask.delete(blockPath) 不存在
- **Pattern-Key**: pitfall.mask_delete
- **优先级**: high
- **首次发现**: 2026-04-17
- **最后发现**: 2026-04-17
- **出现次数**: 2
- **影响 API**: sl_subsystem_mask
- **症状**: 调用 Mask.delete(blockPath) 报错
- **正确做法**: `maskObj=Simulink.Mask.get(path); maskObj.delete()`
- **自动修复**: 无（已在 .m 函数中正确实现）
- **SKILL.md 条目**: #17

### [PIT-008] MATLAB struct 字段名不能以下划线开头
- **Pattern-Key**: pitfall.underscore_field
- **优先级**: high
- **首次发现**: 2026-04-18
- **最后发现**: 2026-04-18
- **出现次数**: 2
- **影响 API**: 所有返回 struct 的 .m 函数
- **症状**: "文本字符无效" 错误
- **正确做法**: 用 `warningInfo` 等合法命名代替 `_warning`
- **自动修复**: PITFALL-UNDERSCORE 模式检测
- **SKILL.md 条目**: #22

### [PIT-009] _build_sl_args 位置参数必须用 _pos_N 标记
- **Pattern-Key**: pitfall.pos_arg_mark
- **优先级**: critical
- **首次发现**: 2026-04-18
- **最后发现**: 2026-04-18
- **出现次数**: 2
- **影响 API**: 所有 sl_* Bridge 命令
- **症状**: MATLAB 把参数名当成值（如 'srcBlock' 被当成模块路径）
- **正确做法**: 位置参数必须用 `_pos_N` 标记
- **自动修复**: 无（需在 _build_sl_args 中正确标记）
- **SKILL.md 条目**: #24

### [PIT-010] _handle_sl_command 必须加 try-catch
- **Pattern-Key**: pitfall.bridge_exception
- **优先级**: critical
- **首次发现**: 2026-04-18
- **最后发现**: 2026-04-18
- **出现次数**: 1
- **影响 API**: Python Bridge 进程
- **症状**: 单条命令异常导致 Bridge 进程崩溃，后续所有命令无法执行
- **正确做法**: _handle_sl_command + server_mode 双层 try-catch
- **自动修复**: 已实现
- **SKILL.md 条目**: #28, #29

---

## 归档踩坑 (COLD)

### [PIT-ARCH-001] evalc 引号双写问题
- **归档日期**: 2026-04-18
- **归档原因**: v5.0 已用 diary 替代 evalc，此踩坑不再适用
- **原始内容**: evalc() 要求所有单引号双写，Name-Value 参数如 'LowerLimit' 被双写为 ''LowerLimit''，导致语法错误

### [PIT-ARCH-002] Python stdout GBK 编码乱码
- **归档日期**: 2026-04-18
- **归档原因**: v5.0 已使用 sys.stdout.buffer.write() + UTF-8 编码，此踩坑不再适用
- **原始内容**: Python sys.stdout.write() 在 Windows 下使用 GBK 编码，中文 JSON 乱码

## v11.8 全递归工作流陷阱

### [PIT-REC-001] 深度超限未拦截
- **日期**: 2026-05-09
- **现象**: AI 在深度 5 的叶层创建子子系统，未被门控拦截
- **根因**: Gate_3 未实现深度检查
- **修复**: v11.8 Gate_3 硬编码 depth>=5→gate_blocked；四重门控 (Gate_2/3/5/4)
- **教训**: 深度限制必须硬编码在 Bridge 中，不可依赖提示词

### [PIT-REC-002] 子系统树不完整
- **日期**: 2026-05-09
- **现象**: framework_approve 后 hierarchy tree 为空，build_order 返回 []
- **根因**: sl_framework_approve 未正确设置 mHierarchyTree_ 变量
- **修复**: validate_hierarchy 递归遍历子系统树并写入 workspace
- **教训**: 树持久化需要 MATLAB workspace + Python Bridge 双写

### [PIT-REC-003] micro_design 深度感知缺失
- **日期**: 2026-05-09
- **现象**: AI 在深度 4 子系统仍设计嵌套结构，不知已达深度限制
- **根因**: micro_design prompt 未包含深度信息
- **修复**: v11.8 注入 depth/depthAwareGuidance/childSubsystems/buildOrderPosition
- **教训**: 层级上下文必须在每个 micro_design 调用时显式传递给 AI

### [PIT-REC-004] Engine 重启后树丢失
- **日期**: 2026-05-09
- **现象**: MATLAB Engine 重启后 Python 侧 subsystem_tree 为 None
- **根因**: Python _WorkflowState 在内存中，Engine 重启后丢失
- **修复**: _reconstruct_tree_from_workspace() + _matlab_tree_to_python_dict()
- **教训**: 树结构必须持久化到 MATLAB workspace 并支持恢复

### [PIT-REC-005] 构建失败无恢复策略
- **日期**: 2026-05-09
- **现象**: 子系统构建失败（unconnected>0）后整个递归构建卡死
- **根因**: 无 failed 状态标记机制
- **修复**: _get_next_build_target 跳过 failed 节点，汇总 failedSubsystems 列表
- **教训**: 递归构建需要容错机制，失败不应阻塞同级其他子系统

---

## 2026-05-15 — v12 审查新增

### PF-034: `check_physics` 空壳 — 不验证方程内容
- **严重度**: P0
- **领域**: framework-review, gate-5
- **现象**: `sl_framework_review` 的 physics 检查只验证子系统是否有 inputs/outputs，不检查 physicsEquations
- **根因**: `check_physics` 函数 (sl_framework_review.m:162-183) 实现与函数名不符
- **修复**: 升级为检查 physicsEquations 存在性、非空、变量自洽性
- **教训**: 验证函数名与实际功能必须一致，不能以"结构检查"冒充"内容检查"

### PF-035: `micro_approve` 橡皮图章 — 不检查 review 结果
- **严重度**: P0
- **领域**: micro-approve, gate-skip
- **现象**: review 失败后仍可 approve
- **根因**: `sl_micro_approve.m` 只做写入，缺少前置条件检查
- **修复**: approve 前强制检查 review 状态
- **教训**: approve 类操作必须有前置守卫

### PF-036: 硬编码参数值 — 无变量引用机制
- **严重度**: P0
- **领域**: parameter, standardization
- **现象**: Constant/Gain 块使用硬编码数值，无法追踪和批量修改
- **根因**: 无参数标准化基础设施
- **修复**: 新增 `sl_param_registry.m`，扩展 `check_param_audit` 检测硬编码值
- **教训**: 系统工程的基础是参数管理

### PF-037: Gate_S0 workspace 变量可伪造
- **严重度**: P0
- **领域**: gate-s0, security
- **现象**: AI 可通过 evalin 直接设置 mS0SceneLocked_ 绕过场景确认
- **根因**: 场景锁依赖 workspace 变量而非 Bridge 内部签名
- **修复**: 改用 HMAC 签名令牌
- **教训**: 安全令牌不应存储在 AI 可写的命名空间

### PF-038: `run_code` 可绕过全部 Gate
- **严重度**: P0
- **领域**: gate-raw-cmd, security
- **现象**: /api/matlab/command 可执行 add_block/add_line/set_param，绕过所有 Gate
- **根因**: 代码注释 "Does NOT block execution — escape hatch"
- **修复**: Gate_RAW_CMD 级别拦截建模关键字
- **教训**: escape hatch 与安全机制不可共存

### PF-039: `add_line_safe` 验证假阳性
- **严重度**: P1
- **领域**: add-line, verification
- **现象**: catch 分支默认 connected=true，只检查 src 不检查 dst
- **根因**: sl_add_line_safe.m:271-289 验证逻辑不严谨
- **修复**: catch 设为 false + 增加 dst 端口验证
- **教训**: 验证失败的默认行为应该是"不信任"而非"信任"

