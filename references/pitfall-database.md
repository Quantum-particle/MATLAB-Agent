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

