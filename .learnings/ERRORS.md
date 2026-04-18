# matlab-agent 错误记录

> 本文件记录 sl_* 命令执行失败、Bridge 异常、MATLAB 错误等。
> 由 matlab-agent 自我改进机制（Layer 2: 主动学习）自动维护。
> 
> 重复出现3次以上的错误会被分析并生成修复建议。
> 涉及 API 签名的错误会同步标注到 sl_toolbox_api_guide.md。

---

## [ERR-20260418-P8TEST] powershell_variable_expansion

**Logged**: 2026-04-18T15:30:00+08:00
**Priority**: medium
**Status**: resolved
**Area**: bridge

### Summary
PowerShell 测试脚本中 $variable 被 Shell 层解析导致变量名丢失，API 调用失败

### Error
PowerShell 单行命令中的 $b, $p 等变量被 Node.js 子进程 Shell 解析为空值，导致 ConvertTo-Json 和 GetBytes 调用失败

### Context
- 命令: execute_command (PowerShell)
- 参数: 所有含 $variable 的 PowerShell 命令
- MATLAB 版本: N/A
- Bridge 模式: N/A

### Suggested Fix
1. 对于简单的 API 测试，将 PowerShell 命令写成 .ps1 脚本文件，用 -File 参数执行
2. 避免在 execute_command 中直接写含 $ 变量的 PowerShell 单行命令
3. 或使用不含变量的简化写法（如直接硬编码 JSON body）

---

## [ERR-20260418-P9BUS] bus_create_elements_format

**Logged**: 2026-04-18T16:00:00+08:00
**Priority**: high
**Status**: fixed
**Area**: bridge

### Summary
sl_bus_create 的 elements 参数从 REST API 传入 JSON list of dicts，但 Bridge _python_to_matlab_value 将其转为 MATLAB cell 数组 `{{struct},{struct}}`，而 .m 函数需要 struct 数组 `[struct;struct]`

### Error
"elements must be a struct array with .name field"

### Context
- 命令: sl_bus_create
- 参数: elements=[{"name":"altitude","dataType":"double"},...]
- MATLAB 版本: R2023b
- Bridge 模式: engine

### Suggested Fix
Bridge _build_sl_args 中对 sl_bus_create 的 elements 参数做特殊处理：list of dicts → `[struct(...);struct(...)]` struct 数组构造代码，使用 `_pos_N_special` 标记绕过 _python_to_matlab_value

---

## [ERR-20260418-P9LAYOUT] arrangeSystem_corrupts_model

**Logged**: 2026-04-18T16:05:00+08:00
**Priority**: critical
**Status**: fixed
**Area**: matlab-api

### Summary
Simulink.BlockDiagram.arrangeSystem 在 MATLAB Engine 模式下可能清空模型内容（inspect 返回 0 blocks），导致后续仿真失败

### Error
"模块图 'xxx' 不包含任何模块，或所有模块均为虚拟模块"

### Context
- 命令: sl_auto_layout
- 参数: modelName (after simulation)
- MATLAB 版本: R2023b
- Bridge 模式: engine

### Suggested Fix
在 sl_auto_layout.m 中：1) arrangeSystem 前先 save_system 保存模型；2) arrangeSystem 后验证 find_system 返回的 blocks 数量；3) 若 blocks 丢失则 close_system+load_system 重新加载

---

## [ERR-20260418-P9SUBSYS] subsystem_create_mask_params

**Logged**: 2026-04-18T16:10:00+08:00
**Priority**: medium
**Status**: fixed
**Area**: bridge

### Summary
sl_subsystem_create 的 blocksToGroup 参数在 REST API 中用 'blocks' 名称传入，Bridge 未做别名映射；sl_subsystem_mask 的 maskParams 参数名与 .m 函数的 'parameters' 不一致

### Error
"blocksToGroup is required for group mode" / "Unknown parameter: maskParams"

### Context
- 命令: sl_subsystem_create, sl_subsystem_mask
- 参数: blocks=[...], maskParams=[...]
- MATLAB 版本: R2023b
- Bridge 模式: engine

### Suggested Fix
1. _build_sl_args 中 sl_subsystem_create 添加 params.get('blocksToGroup', params.get('blocks', [])) 别名映射
2. sl_subsystem_mask 添加 params.get('parameters', params.get('maskParams', [])) 别名映射
3. maskParams 的 list of dicts 需要转为 MATLAB cell{struct} 格式

---

## [ERR-20260418-P9REPLACE] replace_block_migrateParams_bool

**Logged**: 2026-04-18T16:12:00+08:00
**Priority**: medium
**Status**: fixed
**Area**: bridge

### Summary
sl_replace_block 的 migrateParams 默认值设为 Python True (bool)，传给 MATLAB 变成 'true'，但 .m 函数期望 struct 类型，导致 "'logical' 类型的输入参数无效"

### Error
"'logical' 类型的输入参数无效。输入必须为结构体"

### Context
- 命令: sl_replace_block
- 参数: migrateParams=True (default)
- MATLAB 版本: R2023b
- Bridge 模式: engine

### Suggested Fix
将 migrateParams 默认值从 True 改为 {} (空 struct)，如果是 bool 类型则转为空 dict

---

## [ERR-20260418-P9POS] block_position_missing_params

**Logged**: 2026-04-18T16:15:00+08:00
**Priority**: medium
**Status**: fixed
**Area**: bridge

### Summary
sl_block_position 的 _build_sl_args 缺少 blockPaths、alignDirection、spacing 参数，导致 action='align' 时 "blockPaths is required" 报错

### Error
"blockPaths is required for action='align'"

### Context
- 命令: sl_block_position
- 参数: action='align', blockPaths=[...], alignDirection='horizontal'
- MATLAB 版本: R2023b
- Bridge 模式: engine

### Suggested Fix
在 _build_sl_args 中 sl_block_position 条目添加 blockPaths、alignDirection、spacing 参数映射

---

## 记录模板

```markdown
## [ERR-YYYYMMDD-XXX] command_name

**Logged**: ISO-8601 timestamp
**Priority**: high
**Status**: pending | resolved | wont_fix
**Area**: matlab-api | bridge | encoding

### Summary
命令失败简述

### Error
实际错误信息（MATLAB 输出或 Python 异常）

### Context
- 命令: sl_xxx
- 参数: {modelName: '...', ...}
- MATLAB 版本: R2023b
- Bridge 模式: engine / cli

### Suggested Fix
如果可识别，建议修复方案

### Metadata
- Reproducible: yes | no | unknown
- Related Files: path/to/file.m
- See Also: ERR-XXXXXXXX-XXX
```

---

## 活跃记录

（暂无记录 — 将在命令执行失败时自动积累）

