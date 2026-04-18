import express from "express";
import { query, unstable_v2_createSession, unstable_v2_authenticate, PermissionResult, CanUseTool } from "@tencent-ai/agent-sdk";
import { v4 as uuidv4 } from "uuid";
import path from "path";
import { fileURLToPath } from "url";
import { exec } from "child_process";
import { promisify } from "util";
import * as db from "./db.js";
import * as matlab from "./matlab-controller.js";
import { MATLAB_SYSTEM_PROMPT, SIMULINK_SYSTEM_PROMPT, getMATLABSystemPrompt, getSimulinkSystemPrompt, getSimulinkReference, SUPPORTED_SCENARIOS, SUPPORTED_REFERENCE_TOPICS } from "./system-prompts.js";

const execAsync = promisify(exec);

// 待处理的权限请求
interface PendingPermission {
  resolve: (result: PermissionResult) => void;
  reject: (error: Error) => void;
  toolName: string;
  input: Record<string, unknown>;
  sessionId: string;
  timestamp: number;
}

const pendingPermissions = new Map<string, PendingPermission>();

// 权限请求超时时间（5分钟）
const PERMISSION_TIMEOUT = 5 * 60 * 1000;

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 3000;

// 全局异常保护 - 防止子进程崩溃导致服务器退出
process.on('uncaughtException', (err) => {
  console.error('[FATAL] Uncaught exception:', err.message);
});

process.on('unhandledRejection', (reason) => {
  console.error('[FATAL] Unhandled rejection:', reason);
});

// Middleware
app.use(express.json());

// 缓存可用模型列表
let cachedModels: Array<{ modelId: string; name: string; description?: string }> = [];
const defaultModel = "claude-sonnet-4";

// MATLAB Agent 默认 Agent ID
const MATLAB_AGENT_ID = "matlab-default";
const SIMULINK_AGENT_ID = "simulink-default";

// ============= 预热状态管理 =============
let warmupStatus: 'idle' | 'warming_bridge' | 'warming_engine' | 'ready' | 'failed' = 'idle';
let warmupError: string | null = null;
let warmupStartTime: number = 0;

function getWarmupInfo() {
  return {
    status: warmupStatus,
    error: warmupError,
    elapsed: warmupStartTime ? Math.round((Date.now() - warmupStartTime) / 1000) : 0,
  };
}

// 健康检查（含预热状态）
app.get("/api/health", (req, res) => {
  const info = getWarmupInfo();
  const matlabConfig = matlab.getMATLABConfig();
  res.json({
    status: "ok",
    timestamp: new Date().toISOString(),
    matlab: {
      warmup: info.status,
      ready: info.status === 'ready',
      error: info.error,
      elapsedSeconds: info.elapsed,
      root: matlabConfig.matlab_root,
      connectionMode: matlabConfig.matlab_root_source,
    }
  });
});

// 专门的预热状态端点
app.get("/api/matlab/warmup-status", (req, res) => {
  const info = getWarmupInfo();
  res.json({
    status: info.status,
    ready: info.status === 'ready',
    error: info.error,
    elapsedSeconds: info.elapsed,
  });
});

// ============= MATLAB 专用 API =============

// 检查 MATLAB 安装状态（快速版：仅检查文件系统，不启动 MATLAB Engine）
app.get("/api/matlab/status", async (req, res) => {
  try {
    const quick = req.query.quick !== 'false';  // 默认快速检查
    if (quick) {
      res.json(matlab.checkMATLABFiles());
    } else {
      // 完整检查（含 Engine API，可能需要 10+ 秒）
      const result = await matlab.checkMATLABInstallation();
      res.json(result);
    }
  } catch (error: any) {
    res.json({
      status: "error",
      message: error.message,
      matlab_root: matlab.getMATLABConfig().matlab_root,
    });
  }
});

// 执行 MATLAB 脚本
app.post("/api/matlab/execute", async (req, res) => {
  const { scriptPath, outputDir } = req.body;
  
  if (!scriptPath) {
    return res.status(400).json({ error: "请提供脚本路径" });
  }
  
  try {
    const result = await matlab.executeMATLABScript(scriptPath, { outputDir });
    
    // 解析错误（v6.0: 统一用 parsedError 字段）
    if (result.status === 'error') {
      const parsed = matlab.parseMATLABError(result.stdout || result.message || '');
      res.json({ ...result, parsedError: parsed });
    } else {
      res.json(result);
    }
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 运行 MATLAB 命令
app.post("/api/matlab/command", async (req, res) => {
  const { command } = req.body;
  
  if (!command) {
    return res.status(400).json({ error: "请提供 MATLAB 命令" });
  }
  
  try {
    const result = await matlab.runMATLABCommand(command);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 创建 Simulink 模型
app.post("/api/matlab/simulink/create", async (req, res) => {
  const { modelName, modelPath } = req.body;
  
  if (!modelName) {
    return res.status(400).json({ error: "请提供模型名称" });
  }
  
  try {
    const result = await matlab.createSimulinkModel(modelName, modelPath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 运行 Simulink 仿真
app.post("/api/matlab/simulink/run", async (req, res) => {
  const { modelName, stopTime } = req.body;
  
  if (!modelName) {
    return res.status(400).json({ error: "请提供模型名称" });
  }
  
  try {
    const result = await matlab.runSimulinkSimulation(modelName, stopTime || '10');
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ============= v3.0 新增 API =============

// 设置项目工作目录
app.post("/api/matlab/project/set", async (req, res) => {
  const { dirPath } = req.body;
  if (!dirPath) return res.status(400).json({ error: "请提供项目目录路径" });
  try {
    const result = await matlab.setProjectDir(dirPath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 扫描项目文件
app.get("/api/matlab/project/scan", async (req, res) => {
  try {
    // 兼容 dirPath（推荐）和 dir（旧）两种查询参数名
    const dirPath = (req.query.dirPath || req.query.dir) as string | undefined;
    const result = await matlab.scanProjectFiles(dirPath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 读取 .m 文件内容
app.get("/api/matlab/file/m", async (req, res) => {
  const filePath = req.query.path as string;
  if (!filePath) return res.status(400).json({ error: "请提供文件路径" });
  try {
    const result = await matlab.readMFile(filePath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 读取 .mat 数据文件信息
app.get("/api/matlab/file/mat", async (req, res) => {
  const filePath = req.query.path as string;
  if (!filePath) return res.status(400).json({ error: "请提供文件路径" });
  try {
    const result = await matlab.readMatFile(filePath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 读取 Simulink 模型信息
app.get("/api/matlab/file/simulink", async (req, res) => {
  const modelPath = req.query.path as string;
  if (!modelPath) return res.status(400).json({ error: "请提供模型路径" });
  try {
    const result = await matlab.readSimulinkModel(modelPath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 在持久化工作区中运行 MATLAB 代码
app.post("/api/matlab/run", async (req, res) => {
  const { code, showOutput } = req.body;
  if (!code) return res.status(400).json({ error: "请提供 MATLAB 代码" });
  try {
    const result = await matlab.runMATLABCode(code, showOutput !== false);
    if (result && typeof result === 'object' && result.status === 'error') {
      const parsed = matlab.parseMATLABError(result.stdout || result.message || '');
      res.json({ ...result, parsedError: parsed });
    } else {
      res.json(result);
    }
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// v6.0: 智能执行 MATLAB 代码（AI 专属端点）
// 与 /run 的区别：自动 addpath sl_toolbox、检测代码类型、结构化错误解析
app.post("/api/matlab/exec-smart", async (req, res) => {
  const { code, autoAddpath, captureOutput } = req.body;
  if (!code) return res.status(400).json({ error: "请提供 MATLAB 代码" });
  try {
    const result = await matlab.execSmartMATLAB({ code, autoAddpath, captureOutput });
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 获取工作区变量
app.get("/api/matlab/workspace", async (req, res) => {
  try {
    const result = await matlab.getWorkspaceVariables();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 保存工作区
app.post("/api/matlab/workspace/save", async (req, res) => {
  try {
    const { path: filePath } = req.body;
    const result = await matlab.saveWorkspace(filePath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 加载工作区
app.post("/api/matlab/workspace/load", async (req, res) => {
  const { path: filePath } = req.body;
  if (!filePath) return res.status(400).json({ error: "请提供 .mat 文件路径" });
  try {
    const result = await matlab.loadWorkspace(filePath);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 清空工作区
app.post("/api/matlab/workspace/clear", async (req, res) => {
  try {
    const result = await matlab.clearWorkspace();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 打开 Simulink 模型
app.post("/api/matlab/simulink/open", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供模型名称" });
  try {
    const result = await matlab.openSimulinkModel(modelName);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ============= Simulink 模型工作区 API（v4.1 新增）=============

// 设置 Simulink 模型工作区变量
app.post("/api/matlab/simulink/workspace/set", async (req, res) => {
  const { modelName, varName, varValue } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供模型名称" });
  if (!varName) return res.status(400).json({ error: "请提供变量名" });
  if (varValue === undefined) return res.status(400).json({ error: "请提供变量值" });
  try {
    const result = await matlab.setSimulinkWorkspaceVar(modelName, varName, varValue);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 获取 Simulink 模型工作区变量列表
app.get("/api/matlab/simulink/workspace", async (req, res) => {
  const modelName = req.query.modelName as string;
  if (!modelName) return res.status(400).json({ error: "请提供模型名称" });
  try {
    const result = await matlab.getSimulinkWorkspaceVars(modelName);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 清空 Simulink 模型工作区
app.post("/api/matlab/simulink/workspace/clear", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供模型名称" });
  try {
    const result = await matlab.clearSimulinkWorkspace(modelName);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ============= v4.0 通用化 API =============

// 获取 MATLAB 配置
app.get("/api/matlab/config", (req, res) => {
  try {
    const config = matlab.getMATLABConfig();
    res.json(config);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// v5.1.1: 配置自检 API — 诊断配置文件和运行时状态是否同步
app.get("/api/matlab/config/diagnose", (req, res) => {
  try {
    const config = matlab.getMATLABConfig();
    const issues: string[] = [];
    
    // 检查1：配置来源为 none 但可能有残留文件
    if (config.matlab_root_source === 'none' && config.matlab_root === '') {
      // 这是正常的首次使用状态，不算问题
    }
    
    // 检查2：matlab_root 存在但 matlab.exe 不存在
    if (config.matlab_root && !config.matlab_exe_exists) {
      issues.push(`MATLAB_ROOT 已配置为 "${config.matlab_root}"，但 bin/matlab.exe 不存在。路径可能不正确。`);
    }
    
    // 检查3：配置来源为 none 但服务已尝试启动
    if (config.matlab_root_source === 'none' && warmupStatus !== 'idle') {
      issues.push('MATLAB_ROOT 未配置，但 Engine 已尝试启动。请先配置 MATLAB 路径。');
    }
    
    res.json({
      status: issues.length === 0 ? 'ok' : 'warning',
      config,
      issues,
      warmup_status: warmupStatus,
      recommendations: issues.length === 0 
        ? ['配置正常'] 
        : [
            '请通过 POST /api/matlab/config 设置正确的 MATLAB 安装路径',
            '路径应为包含 bin/matlab.exe 的根目录，如 D:\\Program Files\\MATLAB\\R2023b',
          ],
    });
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 设置 MATLAB 根目录
app.post("/api/matlab/config", async (req, res) => {
  // 兼容 matlab_root（下划线）和 matlabRoot（驼峰）两种命名
  const matlabRoot = req.body.matlab_root || req.body.matlabRoot;
  if (!matlabRoot) return res.status(400).json({ error: "请提供 MATLAB 根目录路径" });
  try {
    const result = matlab.setMATLABRoot(matlabRoot);
    if (result.success) {
      // 后台异步重启桥接进程，不阻塞响应
      matlab.restartBridge().catch((err: any) => {
        console.warn('[MATLAB Config] Bridge restart failed (will retry on next command):', err?.message || err);
      });
      res.json({ status: "success", message: result.message });
    } else {
      res.status(400).json({ status: "error", message: result.message });
    }
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 重置 MATLAB 配置（清除内存缓存 + 删除配置文件）
app.delete("/api/matlab/config", (req, res) => {
  try {
    const result = matlab.resetMATLABConfig();
    res.json({ status: "success", ...result });
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 列出图形窗口
app.get("/api/matlab/figures", async (req, res) => {
  try {
    const result = await matlab.listFigures();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 关闭所有图形窗口
app.post("/api/matlab/figures/close", async (req, res) => {
  try {
    const result = await matlab.closeAllFigures();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ============= Workspace Isolation（v5.4 新增）=============

// 初始化隔离子目录
app.post("/api/matlab/workspace/isolation/init", async (req, res) => {
  try {
    const result = await matlab.initAgentWorkspace();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 根据文件类型路由文件路径
app.post("/api/matlab/workspace/isolation/route", async (req, res) => {
  const { filename, forceWorkspace } = req.body;
  if (!filename) {
    return res.status(400).json({ error: "请提供文件名" });
  }
  try {
    const result = await matlab.routeFilePath(filename, forceWorkspace || false);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 清理隔离子目录中的中间文件
app.post("/api/matlab/workspace/isolation/cleanup", async (req, res) => {
  const { keepResults } = req.body;
  try {
    const result = await matlab.cleanupAgentWorkspace(keepResults !== false);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ============= v7.0: sl_* Simulink 工具箱 API（26 个端点） =============
// 这些端点通过 Python Bridge 调用 sl_toolbox 中的 .m 函数

// sl_inspect — 检查模型全景
app.post("/api/matlab/simulink/inspect", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkInspect(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_add_block — 安全添加模块
app.post("/api/matlab/simulink/add_block", async (req, res) => {
  const { modelName, sourceBlock } = req.body;
  if (!modelName || !sourceBlock) return res.status(400).json({ error: "请提供 modelName 和 sourceBlock" });
  try {
    const result = await matlab.simulinkAddBlock(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_add_line — 安全连线
app.post("/api/matlab/simulink/add_line", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkAddLine(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_set_param — 安全设置参数
app.post("/api/matlab/simulink/set_param", async (req, res) => {
  const { blockPath } = req.body;
  if (!blockPath) return res.status(400).json({ error: "请提供 blockPath" });
  try {
    const result = await matlab.simulinkSetParam(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_delete — 安全删除模块
app.post("/api/matlab/simulink/delete", async (req, res) => {
  const { blockPath } = req.body;
  if (!blockPath) return res.status(400).json({ error: "请提供 blockPath" });
  try {
    const result = await matlab.simulinkDelete(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_find_blocks — 高级查找模块
app.post("/api/matlab/simulink/find_blocks", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkFindBlocks(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_replace_block — 替换模块
app.post("/api/matlab/simulink/replace_block", async (req, res) => {
  const { modelName, blockPath, newBlockType } = req.body;
  if (!modelName || !blockPath || !newBlockType) return res.status(400).json({ error: "请提供 modelName, blockPath, newBlockType" });
  try {
    const result = await matlab.simulinkReplaceBlock(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_bus_create — 创建总线
app.post("/api/matlab/simulink/bus_create", async (req, res) => {
  const { busName, elements } = req.body;
  if (!busName || !elements) return res.status(400).json({ error: "请提供 busName 和 elements" });
  try {
    const result = await matlab.simulinkBusCreate(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_bus_inspect — 检查总线
app.post("/api/matlab/simulink/bus_inspect", async (req, res) => {
  const { busName } = req.body;
  if (!busName) return res.status(400).json({ error: "请提供 busName" });
  try {
    const result = await matlab.simulinkBusInspect(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_signal_config — 信号配置
app.post("/api/matlab/simulink/signal_config", async (req, res) => {
  const { modelName, blockPath } = req.body;
  if (!modelName || !blockPath) return res.status(400).json({ error: "请提供 modelName 和 blockPath" });
  try {
    const result = await matlab.simulinkSignalConfig(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_signal_logging — 信号记录
app.post("/api/matlab/simulink/signal_logging", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkSignalLogging(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_subsystem_create — 创建子系统
app.post("/api/matlab/simulink/subsystem_create", async (req, res) => {
  const { modelName, subsystemName } = req.body;
  if (!modelName || !subsystemName) return res.status(400).json({ error: "请提供 modelName 和 subsystemName" });
  try {
    const result = await matlab.simulinkSubsystemCreate(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_subsystem_mask — 子系统 Mask
app.post("/api/matlab/simulink/subsystem_mask", async (req, res) => {
  const { modelName, blockPath } = req.body;
  if (!modelName || !blockPath) return res.status(400).json({ error: "请提供 modelName 和 blockPath" });
  try {
    const result = await matlab.simulinkSubsystemMask(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_subsystem_expand — 展开子系统
app.post("/api/matlab/simulink/subsystem_expand", async (req, res) => {
  const { modelName, subsystemPath } = req.body;
  if (!modelName || !subsystemPath) return res.status(400).json({ error: "请提供 modelName 和 subsystemPath" });
  try {
    const result = await matlab.simulinkSubsystemExpand(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_config_get — 获取模型配置
app.post("/api/matlab/simulink/config_get", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkConfigGet(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_config_set — 设置模型配置
app.post("/api/matlab/simulink/config_set", async (req, res) => {
  const { modelName, config } = req.body;
  if (!modelName || !config) return res.status(400).json({ error: "请提供 modelName 和 config" });
  try {
    const result = await matlab.simulinkConfigSet(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_sim_run — 运行仿真
app.post("/api/matlab/simulink/sim_run", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkSimRun(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_sim_results — 获取仿真结果
app.post("/api/matlab/simulink/sim_results", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkSimResults(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_callback_set — 设置回调
app.post("/api/matlab/simulink/callback_set", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkCallbackSet(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_sim_batch — 批量仿真
app.post("/api/matlab/simulink/sim_batch", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkSimBatch(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_validate — 模型验证
app.post("/api/matlab/simulink/validate", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkValidate(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_parse_error — 错误解析
app.post("/api/matlab/simulink/parse_error", async (req, res) => {
  const { errorMessage } = req.body;
  if (!errorMessage) return res.status(400).json({ error: "请提供 errorMessage" });
  try {
    const result = await matlab.simulinkParseError(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_block_position — 模块位置
app.post("/api/matlab/simulink/block_position", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkBlockPosition(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_auto_layout — 自动排版
app.post("/api/matlab/simulink/auto_layout", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkAutoLayout(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_snapshot — 模型快照
app.post("/api/matlab/simulink/snapshot", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkSnapshot(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_baseline_test — 基线测试
app.post("/api/matlab/simulink/baseline_test", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkBaselineTest(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_profile_sim — 仿真性能分析
app.post("/api/matlab/simulink/profile_sim", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkProfileSim(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_profile_solver — 求解器性能分析
app.post("/api/matlab/simulink/profile_solver", async (req, res) => {
  const { modelName } = req.body;
  if (!modelName) return res.status(400).json({ error: "请提供 modelName" });
  try {
    const result = await matlab.simulinkProfileSolver(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// sl_best_practices — 最佳实践查询
app.post("/api/matlab/simulink/best_practices", async (req, res) => {
  try {
    const result = await matlab.simulinkBestPractices(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// v7.0: Layer 5 源码级自我改进 API
app.post("/api/matlab/simulink/self_improve", async (req, res) => {
  try {
    const result = await matlab.simulinkSelfImprove(req.body);
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// ========== Part 8: 提示词分层查询 API ==========

// 获取 Simulink 场景提示词（Layer 2）
app.get("/api/matlab/simulink/prompt/scenario", async (req, res) => {
  try {
    const scenario = req.query.scenario as string;
    if (!scenario) {
      return res.json({
        status: "ok",
        supportedScenarios: SUPPORTED_SCENARIOS,
        message: "Provide ?scenario= parameter to get scenario prompt"
      });
    }
    const prompt = getSimulinkSystemPrompt(scenario);
    res.json({ status: "ok", scenario, prompt });
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 获取 Simulink 参考层提示词（Layer 3）
app.get("/api/matlab/simulink/prompt/reference", async (req, res) => {
  try {
    const topic = req.query.topic as string;
    if (!topic) {
      return res.json({
        status: "ok",
        supportedTopics: SUPPORTED_REFERENCE_TOPICS,
        message: "Provide ?topic= parameter to get reference prompt"
      });
    }
    const reference = getSimulinkReference(topic);
    if (!reference) {
      return res.status(404).json({
        status: "error",
        message: `Unknown topic: ${topic}. Supported: ${SUPPORTED_REFERENCE_TOPICS.join(', ')}`
      });
    }
    res.json({ status: "ok", topic, reference });
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 列出所有可用的场景和参考主题
app.get("/api/matlab/simulink/prompt/list", async (req, res) => {
  try {
    res.json({
      status: "ok",
      scenarios: SUPPORTED_SCENARIOS,
      referenceTopics: SUPPORTED_REFERENCE_TOPICS,
      usage: {
        scenario: "GET /api/matlab/simulink/prompt/scenario?scenario=<name>",
        reference: "GET /api/matlab/simulink/prompt/reference?topic=<name>",
        fullPrompt: "GET /api/matlab/simulink/prompt/scenario?scenario=<name> returns core+scenario layers"
      }
    });
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 启动 MATLAB Engine（持久化）
app.post("/api/matlab/start", async (req, res) => {
  try {
    const result = await matlab.startMATLAB();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 一键快速启动（v5.0 新增）
app.post("/api/matlab/quickstart", async (req, res) => {
  const { matlabRoot, projectDir } = req.body;
  try {
    const result = await matlab.quickstartMATLAB({ matlabRoot, projectDir });
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 停止 MATLAB Engine
app.post("/api/matlab/stop", async (req, res) => {
  try {
    const result = await matlab.stopMATLAB();
    res.json(result);
  } catch (error: any) {
    res.status(500).json({ status: "error", message: error.message });
  }
});

// 登录方式类型
type LoginMethod = 'env' | 'cli' | 'none';

interface LoginStatusResponse {
  isLoggedIn: boolean;
  method?: LoginMethod;
  envConfigured?: boolean;
  cliConfigured?: boolean;
  error?: string;
  apiKey?: string;
  envVars?: {
    apiKey?: string;
    authToken?: string;
    internetEnv?: string;
    baseUrl?: string;
  };
}

// 检查 CodeBuddy CLI 登录状态
app.get("/api/check-login", async (req, res) => {
  const response: LoginStatusResponse = {
    isLoggedIn: false,
    envConfigured: false,
    cliConfigured: false,
    envVars: {},
  };
  
  const apiKey = process.env.CODEBUDDY_API_KEY;
  const authToken = process.env.CODEBUDDY_AUTH_TOKEN;
  const internetEnv = process.env.CODEBUDDY_INTERNET_ENVIRONMENT;
  const baseUrl = process.env.CODEBUDDY_BASE_URL;
  
  if (apiKey || authToken) {
    response.envConfigured = true;
    if (apiKey) {
      response.envVars!.apiKey = apiKey.slice(0, 8) + '****' + apiKey.slice(-4);
      response.apiKey = response.envVars!.apiKey;
    }
    if (authToken) {
      response.envVars!.authToken = authToken.slice(0, 8) + '****' + authToken.slice(-4);
    }
    if (internetEnv) response.envVars!.internetEnv = internetEnv;
    if (baseUrl) response.envVars!.baseUrl = baseUrl;
  }
  
  try {
    let needsLogin = false;
    const result = await unstable_v2_authenticate({
      environment: 'external',
      onAuthUrl: async (authState) => {
        needsLogin = true;
        response.error = '未登录，请先登录 CodeBuddy CLI';
      }
    });
    
    if (!needsLogin && result?.userinfo) {
      response.isLoggedIn = true;
      response.cliConfigured = true;
      response.method = response.envConfigured ? 'env' : 'cli';
    } else if (!needsLogin) {
      response.isLoggedIn = true;
      response.cliConfigured = true;
      response.method = response.envConfigured ? 'env' : 'cli';
    }
  } catch (error: any) {
    if (response.envConfigured) {
      response.isLoggedIn = true;
      response.method = 'env';
    } else {
      response.error = error?.message || String(error);
      response.method = 'none';
    }
  }
  
  res.json(response);
});

// 保存环境变量配置
app.post("/api/save-env-config", (req, res) => {
  const { apiKey, authToken, internetEnv, baseUrl } = req.body;
  
  if (!apiKey && !authToken) {
    return res.status(400).json({ error: '请至少配置 API Key 或 Auth Token' });
  }
  
  const configuredVars: string[] = [];
  
  if (apiKey) { process.env.CODEBUDDY_API_KEY = apiKey; configuredVars.push('CODEBUDDY_API_KEY'); }
  if (authToken) { process.env.CODEBUDDY_AUTH_TOKEN = authToken; configuredVars.push('CODEBUDDY_AUTH_TOKEN'); }
  if (internetEnv) { process.env.CODEBUDDY_INTERNET_ENVIRONMENT = internetEnv; configuredVars.push('CODEBUDDY_INTERNET_ENVIRONMENT'); }
  if (baseUrl) { process.env.CODEBUDDY_BASE_URL = baseUrl; configuredVars.push('CODEBUDDY_BASE_URL'); }
  
  cachedModels = [];
  
  res.json({ 
    success: true, 
    message: `已设置: ${configuredVars.join(', ')}`,
    note: '环境变量仅在当前服务器进程有效，重启后需要重新设置'
  });
});

// 获取可用模型列表
app.get("/api/models", async (req, res) => {
  try {
    if (cachedModels.length === 0) {
      const session = await unstable_v2_createSession({ cwd: process.cwd() });
      const models = await session.getAvailableModels();
      
      if (models && Array.isArray(models)) {
        cachedModels = models;
      }
    }
    
    res.json({ 
      models: cachedModels.length > 0 ? cachedModels : [
        { modelId: "claude-sonnet-4", name: "Claude Sonnet 4" }
      ],
      defaultModel 
    });
  } catch (error: any) {
    res.json({
      models: [
        { modelId: "claude-sonnet-4", name: "Claude Sonnet 4" },
        { modelId: "claude-opus-4", name: "Claude Opus 4" }
      ],
      defaultModel,
      error: error?.message || String(error)
    });
  }
});

// ============= 会话 API =============

app.get("/api/sessions", (req, res) => {
  try {
    const sessions = db.getAllSessions();
    const sessionsWithMessages = sessions.map(session => {
      const messages = db.getMessagesBySession(session.id);
      return { ...session, messageCount: messages.length };
    });
    res.json({ sessions: sessionsWithMessages });
  } catch (error: any) {
    res.status(500).json({ error: error?.message || "获取会话失败" });
  }
});

app.get("/api/sessions/:sessionId", (req, res) => {
  try {
    const { sessionId } = req.params;
    const session = db.getSession(sessionId);
    
    if (!session) return res.status(404).json({ error: "会话不存在" });
    
    const messages = db.getMessagesBySession(sessionId);
    const parsedMessages = messages.map(msg => ({
      ...msg,
      tool_calls: msg.tool_calls ? JSON.parse(msg.tool_calls) : null
    }));
    
    res.json({ session, messages: parsedMessages });
  } catch (error: any) {
    res.status(500).json({ error: error?.message || "获取会话失败" });
  }
});

app.post("/api/sessions", (req, res) => {
  try {
    const { model = defaultModel, title = "新对话" } = req.body;
    const now = new Date().toISOString();
    
    const session = db.createSession({
      id: uuidv4(),
      title,
      model,
      created_at: now,
      updated_at: now
    });
    
    res.json({ session });
  } catch (error: any) {
    res.status(500).json({ error: error?.message || "创建会话失败" });
  }
});

app.patch("/api/sessions/:sessionId", (req, res) => {
  try {
    const { sessionId } = req.params;
    const { title, model } = req.body;
    const success = db.updateSession(sessionId, { title, model });
    if (!success) return res.status(404).json({ error: "会话不存在" });
    res.json({ success: true });
  } catch (error: any) {
    res.status(500).json({ error: error?.message || "更新会话失败" });
  }
});

app.delete("/api/sessions/:sessionId", (req, res) => {
  try {
    const { sessionId } = req.params;
    const success = db.deleteSession(sessionId);
    if (!success) return res.status(404).json({ error: "会话不存在" });
    res.json({ success: true });
  } catch (error: any) {
    res.status(500).json({ error: error?.message || "删除会话失败" });
  }
});

// ============= 聊天 API =============

app.post("/api/permission-response", (req, res) => {
  const { requestId, behavior, message } = req.body;
  
  const pending = pendingPermissions.get(requestId);
  if (!pending) {
    return res.status(404).json({ error: "权限请求不存在或已超时" });
  }
  
  pendingPermissions.delete(requestId);
  
  if (behavior === 'allow') {
    pending.resolve({ behavior: 'allow', updatedInput: pending.input });
  } else {
    pending.resolve({ behavior: 'deny', message: message || '用户拒绝了此操作' });
  }
  
  res.json({ success: true });
});

// 发送消息并获取流式响应
app.post("/api/chat", async (req, res) => {
  const { sessionId, message, model, agentId, systemPrompt, cwd, permissionMode } = req.body;
  
  console.log(`\n[Chat] ========== 新请求 ==========`);
  console.log(`[Chat] SessionId: ${sessionId}`);
  console.log(`[Chat] Model: ${model}`);
  console.log(`[Chat] AgentId: ${agentId || 'default'}`);
  console.log(`[Chat] Message: ${message?.slice(0, 100)}${message?.length > 100 ? '...' : ''}`);

  if (!message) {
    return res.status(400).json({ error: "消息不能为空" });
  }

  let session = sessionId ? db.getSession(sessionId) : null;
  const now = new Date().toISOString();
  
  if (!session) {
    session = db.createSession({
      id: sessionId || uuidv4(),
      title: message.slice(0, 30) + (message.length > 30 ? '...' : ''),
      model: model || defaultModel,
      sdk_session_id: null,
      created_at: now,
      updated_at: now
    });
  }

  const selectedModel = model || session.model;
  const sdkSessionId = session.sdk_session_id;

  const userMessageId = uuidv4();
  const assistantMessageId = uuidv4();

  try {
    db.createMessage({
      id: userMessageId,
      session_id: session.id,
      role: 'user',
      content: message,
      model: null,
      created_at: now,
      tool_calls: null
    });
  } catch (dbError: any) {
    return res.status(500).json({ error: "保存消息失败", detail: dbError?.message });
  }

  res.setHeader("Content-Type", "text/event-stream");
  res.setHeader("Cache-Control", "no-cache");
  res.setHeader("Connection", "keep-alive");

  // 根据选择的 Agent 决定系统提示词
  const getSystemPrompt = () => {
    if (systemPrompt) return systemPrompt;
    if (agentId === SIMULINK_AGENT_ID) return getSimulinkSystemPrompt();
    // 使用动态提示词（含当前环境信息）
    return getMATLABSystemPrompt();
  };

  const workingDir = cwd || process.cwd();

  try {
    console.log(`[Chat] 调用 SDK query...`);
    console.log(`[Chat] - Model: ${selectedModel}`);
    console.log(`[Chat] - SystemPrompt: MATLAB Agent (${agentId || 'default'})`);
    console.log(`[Chat] - CWD: ${workingDir}`);
    console.log(`[Chat] - PermissionMode: ${permissionMode || 'bypassPermissions'}`);
    
    const canUseTool: CanUseTool = async (toolName, input, options) => {
      console.log(`[Permission] Tool request: ${toolName}`);
      
      // MATLAB Agent 默认使用 bypassPermissions 模式
      if (permissionMode === 'bypassPermissions') {
        return { behavior: 'allow', updatedInput: input };
      }
      
      const requestId = uuidv4();
      const permissionRequest = {
        requestId,
        toolUseId: options.toolUseID,
        toolName,
        input,
        sessionId: session.id,
        timestamp: Date.now()
      };
      
      res.write(`data: ${JSON.stringify({ 
        type: "permission_request", 
        ...permissionRequest
      })}\n\n`);
      
      return new Promise<PermissionResult>((resolve, reject) => {
        const pending: PendingPermission = {
          resolve, reject, toolName, input,
          sessionId: session.id,
          timestamp: Date.now()
        };
        
        pendingPermissions.set(requestId, pending);
        
        setTimeout(() => {
          if (pendingPermissions.has(requestId)) {
            pendingPermissions.delete(requestId);
            resolve({ behavior: 'deny', message: '权限请求超时' });
          }
        }, PERMISSION_TIMEOUT);
      });
    };
    
    const stream = query({
      prompt: message,
      options: {
        cwd: workingDir,
        model: selectedModel,
        maxTurns: 15,  // MATLAB 开发可能需要更多轮次
        systemPrompt: getSystemPrompt(),
        permissionMode: permissionMode || 'bypassPermissions',
        canUseTool,
        ...(sdkSessionId ? { resume: sdkSessionId } : {})
      }
    });

    let fullResponse = "";
    let toolCalls: Array<{ 
      id: string; name: string; input?: Record<string, unknown>;
      status: string; result?: string; isError?: boolean;
    }> = [];
    let newSdkSessionId: string | null = null;

    res.write(`data: ${JSON.stringify({ 
      type: "init", sessionId: session.id, userMessageId, 
      assistantMessageId, model: selectedModel 
    })}\n\n`);

    let currentToolId: string | null = null;

    for await (const msg of stream) {
      if (msg.type === "system" && (msg as any).subtype === "init") {
        newSdkSessionId = (msg as any).session_id;
        if (newSdkSessionId && newSdkSessionId !== sdkSessionId) {
          db.updateSession(session.id, { sdk_session_id: newSdkSessionId });
        }
      } else if (msg.type === "assistant") {
        const content = msg.message.content;

        if (typeof content === "string") {
          fullResponse += content;
          res.write(`data: ${JSON.stringify({ type: "text", content })}\n\n`);
        } else if (Array.isArray(content)) {
          for (const block of content) {
            if (block.type === "text") {
              fullResponse += block.text;
              res.write(`data: ${JSON.stringify({ type: "text", content: block.text })}\n\n`);
            } else if (block.type === "tool_use") {
              currentToolId = block.id || uuidv4();
              const toolInput = (block as any).input || {};
              console.log(`[Stream] Tool use: ${block.name}`);
              
              const toolCall = { 
                id: currentToolId, name: block.name, 
                input: toolInput, status: "running" 
              };
              toolCalls.push(toolCall);
              res.write(`data: ${JSON.stringify({ 
                type: "tool", id: toolCall.id, name: toolCall.name,
                input: toolCall.input, status: toolCall.status
              })}\n\n`);
            }
          }
        }
      } else if (msg.type === "tool_result") {
        const msgAny = msg as any;
        const toolId = msgAny.tool_use_id || currentToolId;
        const isError = msgAny.is_error || false;
        const content = msgAny.content;
        
        const tool = toolCalls.find(t => t.id === toolId) || toolCalls[toolCalls.length - 1];
        if (tool) {
          tool.status = isError ? "error" : "completed";
          tool.isError = isError;
          tool.result = typeof content === 'string' ? content : JSON.stringify(content);
          res.write(`data: ${JSON.stringify({ 
            type: "tool_result", toolId: tool.id, 
            content: tool.result, isError
          })}\n\n`);
        }
        currentToolId = null;
      } else if (msg.type === "result") {
        toolCalls.forEach(tool => {
          if (tool.status === "running") {
            tool.status = "completed";
            res.write(`data: ${JSON.stringify({ type: "tool_result", toolId: tool.id, content: tool.result || "已完成" })}\n\n`);
          }
        });
        res.write(`data: ${JSON.stringify({ type: "done", duration: msg.duration, cost: msg.cost })}\n\n`);
      }
    }

    db.createMessage({
      id: assistantMessageId,
      session_id: session.id,
      role: 'assistant',
      content: fullResponse,
      model: selectedModel,
      created_at: new Date().toISOString(),
      tool_calls: toolCalls.length > 0 ? JSON.stringify(toolCalls) : null
    });

    const messages = db.getMessagesBySession(session.id);
    if (messages.length <= 2) {
      db.updateSession(session.id, {
        title: message.slice(0, 30) + (message.length > 30 ? '...' : ''),
        model: selectedModel
      });
    }

    console.log(`[Chat] 请求完成 ✓`);
    res.end();
  } catch (error: any) {
    console.error(`[Chat] Error:`, error?.message);
    const errorMessage = error?.message || "处理请求时发生错误";
    res.write(`data: ${JSON.stringify({ type: "error", message: errorMessage })}\n\n`);
    res.end();
  }
});

// 启动服务器
app.listen(PORT, () => {
  const matlabConfig = matlab.getMATLABConfig();
  const configSource = matlabConfig.matlab_root_source;
  const matlabStatusDisplay = !matlabConfig.matlab_root
    ? '⚠️ 未配置 (首次使用请通过 POST /api/matlab/config 设置 MATLAB_ROOT)'
    : `${matlabConfig.matlab_root.substring(0, 45)}${matlabConfig.matlab_root.length > 45 ? '...' : ''}`;
  const isFirstTime = configSource === 'none' || !matlabConfig.matlab_root;

  console.log(`
╔════════════════════════════════════════════════════╗
║                                                    ║
║     ◉ MATLAB Agent v5.2 - API 服务器已启动         ║
║                                                    ║
║     地址: http://localhost:${PORT}                    ║
║     MATLAB: ${matlabStatusDisplay}║
║     配置来源: ${configSource}${isFirstTime ? ' (首次使用)' : ''}${' '.repeat(Math.max(0, 30 - configSource.length - (isFirstTime ? 10 : 0)))}║
║     数据库: SQLite (data/chat.db)                  ║
${isFirstTime ? '║  ⚠️  首次使用！AI Agent 将自动引导配置 MATLAB 路径      ║\n' : ''}║                                                    ║
╚════════════════════════════════════════════════════╝
  `);

  // ============= 后台预热 MATLAB Engine =============
  // 服务器已就绪，但 MATLAB Engine 还未启动。
  // 在后台异步预热，避免用户首次请求时等待 15~60 秒。
  // 带超时机制：如果预热超过 WARMUP_TIMEOUT 秒还没完成，标记为失败并停止等待。
  
  // 先检查 MATLAB 是否可用，不可用则跳过 warmup 并提示用户配置
  if (!matlab.isMATLABAvailable()) {
    warmupStatus = 'failed';
    warmupError = 'MATLAB 未配置。首次使用请通过 POST /api/matlab/config 设置 MATLAB_ROOT';
    console.warn('[Warmup] ✗ 跳过预热：MATLAB 未配置');
    console.warn('[Warmup] 提示：请通过 POST /api/matlab/config 设置 MATLAB 安装路径');
    console.warn('[Warmup] 示例：powershell -Command "Invoke-RestMethod -Method POST -Uri http://localhost:3000/api/matlab/config -ContentType \'application/json\' -Body \'{\"matlabRoot\":\"D:\\\\Program Files\\\\MATLAB\\\\R2023b\"}\'"');
    console.warn('[Warmup] 或设置环境变量：set MATLAB_ROOT=D:\\Program Files\\MATLAB\\R2023b');
  } else {
    const WARMUP_TIMEOUT = 90; // 预热总超时（秒），包含 Engine 兼容性检测 + Engine 启动
  warmupStartTime = Date.now();
  warmupStatus = 'warming_bridge';
  console.log(`[Warmup] 开始预热 MATLAB Engine（超时 ${WARMUP_TIMEOUT}秒）...`);

  const warmupTimeoutHandle = setTimeout(() => {
    if (warmupStatus === 'warming_bridge' || warmupStatus === 'warming_engine') {
      warmupStatus = 'failed';
      warmupError = `预热超时（${WARMUP_TIMEOUT}秒），MATLAB Engine 可能不兼容当前环境。将使用 CLI 回退模式。`;
      console.warn(`[Warmup] ✗ 预热超时（${WARMUP_TIMEOUT}秒），停止等待`);
    }
  }, WARMUP_TIMEOUT * 1000);

  matlab.startMATLAB()
    .then((result) => {
      clearTimeout(warmupTimeoutHandle);
      if (warmupStatus === 'failed') {
        // 已经超时了，忽略后续结果
        console.warn('[Warmup] Engine 启动结果返回，但已超时跳过');
        return;
      }
      if (result.status === 'ok') {
        warmupStatus = 'ready';
        const elapsed = Math.round((Date.now() - warmupStartTime) / 1000);
        console.log(`[Warmup] ✓ MATLAB Engine 预热完成 (${elapsed}秒)`);
      } else {
        warmupStatus = 'failed';
        warmupError = result.message || '预热失败';
        console.warn(`[Warmup] ✗ MATLAB Engine 预热失败: ${warmupError}`);
      }
    })
    .catch((err) => {
      clearTimeout(warmupTimeoutHandle);
      if (warmupStatus === 'failed') return; // 已超时
      warmupStatus = 'failed';
      warmupError = err.message || String(err);
      console.warn(`[Warmup] ✗ MATLAB Engine 预热异常: ${warmupError}`);
    });
  } // end of else (MATLAB available)
});
