# matlab-agent 踩坑经验数据库

> 从 SKILL.md 分离，AI 按需读取。SKILL.md 中保留精简 Top 15 速查。

---

## ⚠️ 关键踩坑经验

### 0. Windows 启动踩坑大全

> **这是最关键的坑，因为启动不了就什么都干不了！**

- **坑0: 端口 3000 被旧进程占用** — 症状：EADDRINUSE。启动前 kill 残留进程，等 2-3s 端口释放
- **坑1: node_modules 缺失** — 症状：Cannot find module。`npm install --production`
- **坑2: npx 不是 exe** — Windows 下用 `cmd /c` 执行 npx
- **坑3: 阻塞式启动** — 必须后台启动 `start /B`，轮询 `/api/health`
- **坑5: 含中文/括号路径** — 用 `cmd /c` 包裹命令
- **坑5.5: PowerShell UTF8 编码** — `$bytes = [Text.Encoding]::UTF8.GetBytes($body)` 后传 Body
- **坑6: Python Bridge spawn 失败** — 确保 Python 在 PATH
- **坑7: 日志无处可查** — 重定向到 `%TEMP%\matlab-agent-out.log`

### 0.5 AI Agent 启动标准流程

```
0. 端口清理 (ensure-running.bat 自动处理)
1. 检查服务: curl localhost:3000/api/health
2. 如未运行: cmd /c "C:\Users\泰坦\.workbuddy\skills\matlab-agent\app\ensure-running.bat"
3. 使用 quickstart API: POST /api/matlab/quickstart
```

### 0.5 [CRITICAL] 四文件同步规则

新增 Simulink 模块时四个文件必须同时更新：
1. `block-param-registry.md` — 参数参考文档
2. `sl_block_registry.m` — 路径注册表
3. `matlab_bridge.py` — `_MATRIX_PARAM_PATTERNS` + `_PARAM_ENUM_VALUES`
4. `sl_toolbox_api_guide.md` — 已支持模块表格

### 1. diary 替代 evalc

使用 `diary()` + `eng.eval()` 替代 `evalc()`。代码直接执行无需引号转义，完美支持中文路径。**不要回退到 evalc！**

### 2-16. 基础编码/路径/配置类踩坑

- **2**: stdout 用 `sys.stdout.buffer.write(json.dumps(...).encode('utf-8'))` 解决中文乱码
- **3**: 中文路径用 `dir()+fullfile()` 间接操作
- **4**: 新建 SubSystem 用 `set_param` 重命名默认端口，不要 `delete_block`
- **4.5**: 构建完成后必须 `Simulink.BlockDiagram.arrangeSystem(modelName)` 排版！
- **14**: Position 格式 `[left, bottom, right, top]` 不是 `[x, y, w, h]`
- **13**: 函数名不能以 `_` 开头
- **16**: Python Engine 版本不兼容 → CLI 回退 + v11.4.1 自动检测

### 17. MATLAB 路径配置

- 优先级: 环境变量 MATLAB_ROOT > 配置文件 > 未配置
- 配置文件路径: `skills/matlab-agent/data/matlab-config.json`（不是 `app/data/`！）
- v5.2+ `ensureDataDirSync()` 自动迁移旧配置

### 22. Simulink 建模深坑

- **坑A**: 原生 SubSystem 有默认 In1→Out1 连线，需 `delete_line`。`sl_subsystem_create('empty')` 不需要
- **坑B**: 复杂模型用 From/Goto 传递信号，不是直接连线
- **坑D**: 多个 add_line 用 try-catch 逐个包裹
- **坑E**: 中文路径用 `dir()+fullfile()` 避开
- **坑F**: 完成后必须排版

### 23. 封装子系统解析

- 逐层用 `find_system(path, 'SearchDepth', 1)` 深入
- 不要用 `get_param(path, 'Children')` — 封装子系统无此属性

### 24. .m 文件编码与命名

- 禁止 4 字节 UTF-8 emoji（用 [CRITICAL]/[OK]/[FAIL] 替代）
- struct 字段名不能以 `_` 开头
- **所有 struct 构造必须分步赋值**: `s=struct(); s.field=val;`
- 修改 .m 后执行 `clear functions; rehash toolboxcache;`

### 25. 自我改进机制

- 自动记录错误 → `.learnings/ERRORS.md`
- 同一错误 >=3 次 → 自动提升到 SKILL.md
- `sl_self_improve` API 支持源码级修改

### 27. 强制验证循环

- 每个写操作后 Bridge 自动注入 `_verification` 字段
- AI 不可绕过，必须检查验证结果
- 有未连接端口时禁止声明建模完成

### 28. 标准化建模工作流

- 三层迭代：大框架 → 填充子系统 → 检查仿真
- 连续 3 次 add 后自动触发布局
- 每次操作返回 `_workflow` 字段引导下一步
- 排版由代码自动触发，AI 不需要主动调用

### 34. 参数管理最佳实践 (v11.6.7)

**物理参数应定义为 workspace 变量**，在 Gain 块中引用变量名而非硬编码字面值:

```matlab
% ✅ DO: workspace 变量 + 块引用变量名
k_T = 1e-5;   k_Q = 1e-7;   tau_m = 0.1;
m = 1.5;      g = 9.81;
Jxx = 0.02;   Jyy = 0.02;   Jzz = 0.04;
set_param(gainBlock, 'Gain', 'k_T');  % 引用变量名

% ❌ DON'T: 硬编码字面值
set_param(gainBlock, 'Gain', num2str(1e-5));  % 调参需改 .slx
```

**原因**: workspace 变量方式允许通过修改变量值后重新仿真来快速调参，
无需重新编辑和保存 .slx 文件。

### 35. 安全清除顶层连线 (v11.6.7)

**DO**: 使用 `sl_clear_top_lines(modelName)`:
```matlab
result = sl_clear_top_lines('Quadrotor_FDM');
% → 仅清除顶层连线，子系统内部不受影响
```

**DON'T**: 使用 `find_system(mn, 'FindAll','on', 'type','line')` + `delete_line`:
```matlab
% ❌ 递归删除所有层级连线，包括子系统内部！
lines = find_system(mn, 'FindAll', 'on', 'type', 'line');
for i = 1:length(lines); delete_line(lines(i)); end
```

**替代方案**: 如果必须使用 find_system，加 `SearchDepth=1` 限制递归深度:
```matlab
lines = find_system(mn, 'SearchDepth', 1, 'FindAll', 'on', 'type', 'line');
```

---

> **详细版本**: 见 SKILL.md (已精简) 或 git 历史
> **结构版本**: `references/pitfall-database.md` (含 Pattern-Key + 出现次数)

---

## v11.9+ 新增反模式

### P-34: check_physics 不验证方程内容 — 空壳通过审查

`sl_framework_review.m` 的 `check_physics` 函数只检查子系统是否有 inputs/outputs 字段，**完全不检查** `physicsEquations` 是否存在或内容是否正确。AI 可以不提供任何物理方程而通过物理检查。

**触发**: AI 调用 `sl_framework_review`，但 macroFramework 中没有 physicsEquations

**结果**: `check_physics` 返回 `passed=true, confidence=0.9`

**正确做法**: 升级 `check_physics` 检查 physicsEquations 存在性、非空、变量自洽性

### P-35: micro_approve 不检查 review 结果 — 橡皮图章

`sl_micro_approve.m` 只做写入操作，**不检查** `sl_micro_review` 是否通过。AI 可以在 review 失败后直接 approve。

**触发**: AI 跳过 review 或 review 失败后直接调 micro_approve

**结果**: `sl_micro_approve` 返回 `status='ok'` 无论 review 是否通过

**正确做法**: approve 前强制检查 review 已调用且 `passed=true`

### P-36: 硬编码参数值 — 无变量引用检查

Constant/Gain 块可以使用硬编码数值（如 `'9.81'`）而非 MATLAB workspace 变量（如 `'g_accel'`）。`check_param_audit` 只检查参数是否为空，不检测硬编码 vs 变量引用。

**触发**: AI 调用 `set_param(gainBlock, 'Gain', '1.5')`

**结果**: 模型参数无法追踪、无法批量修改、不符合系统工程规范

**正确做法**: 使用 workspace 变量引用，参数统一在 `sl_param_registry` 中管理

### P-37: Gate_S0 workspace 变量可被伪造

场景锁依赖 `mS0SceneLocked_` workspace 变量。AI 可通过 `run_code` 执行 `evalin('base', 'mS0SceneLocked_=1')` 绕过用户确认。

**触发**: AI 直接操作 workspace 变量

**正确做法**: Gate_S0 使用 Bridge 内部 HMAC 签名令牌

### P-38: run_code 可绕过所有 Gate

`run_code` 函数（`/api/matlab/command`）注释明确声明 "Does NOT block execution — escape hatch"。除 `sim()` 外，所有 Simulink 结构操作（add_block, add_line, set_param）都可通过此路径绕过全部门控。

**触发**: AI 通过 `/api/matlab/command` 发送 add_block('simulink/...') 命令

**正确做法**: Gate_RAW_CMD 级别拦截所有建模关键字

### P-39: add_line_safe 验证假阳性

catch 分支中 `verification.srcPortConnected = true` — 如果验证因错误失败，默认认为成功。且只检查 src 端口，不检查 dst 端口。

**触发**: `sl_add_line_safe` 验证阶段抛出异常

**正确做法**: catch 分支设为 false，同时验证 dst 端口
