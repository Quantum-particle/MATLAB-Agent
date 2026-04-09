/**
* MATLAB Controller v4.1 - 通用化后端 MATLAB 控制器
* 
* 核心架构: 使用常驻 Python 桥接进程（--server 模式）
* - Python 进程保持运行，MATLAB Engine 持久化
* - 变量跨命令保持，图形窗口实时显示
* - 通过 stdin/stdout JSON 行协议通信
* 
* v4.1 变更:
* - 移除自动检测逻辑，首次启动需用户手动输入 MATLAB 安装路径
* - MATLAB_ROOT 优先级: 环境变量 > 配置文件（持久化）> 未配置
* - 配置通过 POST /api/matlab/config 或环境变量 MATLAB_ROOT 设置
*/

import { spawn, ChildProcess } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { fileURLToPath } from "url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// ============= MATLAB 路径配置 =============

/**
 * MATLAB_ROOT 优先级:
 * 1. 环境变量 MATLAB_ROOT（最高优先级，用户显式设置）
 * 2. 本地配置文件 data/matlab-config.json（用户通过 API 配置，持久化）
 * 3. 无 → 返回空字符串，提示用户配置
 * 
 * 首次启动时需要用户手动输入 MATLAB 安装路径，不再自动扫描。
 */

let _configuredMatlabRoot: string | null = null;

// 配置文件路径
const CONFIG_DIR = path.join(__dirname, '..', '..', 'data');
const CONFIG_FILE = path.join(CONFIG_DIR, 'matlab-config.json');

/** 从配置文件读取 MATLAB_ROOT */
function loadConfigFromFile(): string | null {
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      const config = JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'));
      if (config.matlab_root && fs.existsSync(config.matlab_root)) {
        return config.matlab_root;
      }
    }
  } catch {
    // 配置文件损坏，忽略
  }
  return null;
}

/** 保存 MATLAB_ROOT 到配置文件 */
function saveConfigToFile(matlabRoot: string): void {
  try {
    if (!fs.existsSync(CONFIG_DIR)) {
      fs.mkdirSync(CONFIG_DIR, { recursive: true });
    }
    const config = fs.existsSync(CONFIG_FILE) 
      ? JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf-8'))
      : {};
    config.matlab_root = matlabRoot;
    config.updated_at = new Date().toISOString();
    fs.writeFileSync(CONFIG_FILE, JSON.stringify(config, null, 2), 'utf-8');
    console.log(`[MATLAB Config] 已保存 MATLAB_ROOT 到配置文件: ${matlabRoot}`);
  } catch (err: any) {
    console.error(`[MATLAB Config] 保存配置失败: ${err.message}`);
  }
}

/** 获取当前有效的 MATLAB_ROOT */
function getMATLABRoot(): string {
  // 1. 环境变量（最高优先级）
  const envRoot = process.env.MATLAB_ROOT;
  if (envRoot && fs.existsSync(envRoot)) {
    return envRoot;
  }
  // 2. API 动态设置（本次会话内存缓存）
  if (_configuredMatlabRoot && fs.existsSync(_configuredMatlabRoot)) {
    return _configuredMatlabRoot;
  }
  // 3. 配置文件（持久化）
  const fileRoot = loadConfigFromFile();
  if (fileRoot) {
    _configuredMatlabRoot = fileRoot;  // 缓存到内存
    return fileRoot;
  }
  // 未配置，返回空字符串
  return '';
}

/** 检查 MATLAB 是否可用（MATLAB_ROOT 有效且 matlab.exe 存在） */
export function isMATLABAvailable(): boolean {
  const root = getMATLABRoot();
  if (!root) return false;
  return fs.existsSync(path.join(root, 'bin', 'matlab.exe'));
}

/** 通过 API 设置 MATLAB_ROOT（同时持久化到配置文件） */
export function setMATLABRoot(root: string): { success: boolean; message: string } {
  if (!root) {
    return { success: false, message: '路径不能为空' };
  }
  // 用户可能输入的是 bin 目录，自动取父目录
  let normalizedPath = path.normalize(root);
  if (normalizedPath.endsWith('bin') || normalizedPath.endsWith('bin\\') || normalizedPath.endsWith('bin/')) {
    normalizedPath = path.dirname(normalizedPath);
  }
  if (!fs.existsSync(normalizedPath)) {
    return { success: false, message: `路径不存在: ${normalizedPath}` };
  }
  // 验证是否像 MATLAB 安装目录
  if (!fs.existsSync(path.join(normalizedPath, 'bin', 'matlab.exe'))) {
    return { success: false, message: `未找到 matlab.exe: ${path.join(normalizedPath, 'bin', 'matlab.exe')}` };
  }
  _configuredMatlabRoot = normalizedPath;
  // 持久化到配置文件
  saveConfigToFile(normalizedPath);
  console.log(`[MATLAB Config] MATLAB_ROOT 已设置为: ${normalizedPath}`);
  return { success: true, message: `MATLAB_ROOT 已设置为 ${normalizedPath}` };
}

// ============= 动态路径常量 =============

/** 获取 MATLAB bin 路径 */
function getMATLABBin(): string {
  const root = getMATLABRoot();
  if (!root) return '';
  return path.join(root, 'bin', 'matlab.exe');
}

/** 获取 Python Bridge 脚本路径 */
const BRIDGE_SCRIPT = path.join(__dirname, '..', 'matlab-bridge', 'matlab_bridge.py');

/** 获取默认工作空间（当前工作区目录） */
function getDefaultWorkspace(): string {
  return process.env.MATLAB_WORKSPACE || process.cwd();
}

// 超时配置
const TIMEOUTS = {
  script: 120_000,
  simulinkCreate: 120_000,
  simulinkRun: 300_000,
  check: 60_000,
  projectScan: 30_000,
  fileRead: 60_000,
  runCode: 120_000,
  engineStart: 90_000,    // Engine 启动超时（含兼容性检测）
  engineCompatTest: 45_000, // Engine 兼容性测试超时
  default: 300_000,
};

// 命令执行进度检测间隔（毫秒）
const PROGRESS_CHECK_INTERVAL = 15_000;

export interface MATLABCommand {
  action: string;
  params: Record<string, any>;
}

export interface MATLABResult {
  status: 'ok' | 'error' | 'warning';
  message?: string;
  stdout?: string;
  variables?: Array<{ name: string; size: string; class: string; preview?: string }>;
  model_path?: string;
  open_figures?: number;
  files?: any;
  summary?: any;
  content?: string;
  [key: string]: any;
}

function getTimeout(command: MATLABCommand): number {
  switch (command.action) {
    case 'execute_script': return TIMEOUTS.script;
    case 'run_code': return TIMEOUTS.runCode;
    case 'create_simulink': return TIMEOUTS.simulinkCreate;
    case 'run_simulink': return TIMEOUTS.simulinkRun;
    case 'check': return TIMEOUTS.engineCompatTest;
    case 'start': return TIMEOUTS.engineStart;
    case 'scan_project': return TIMEOUTS.projectScan;
    case 'read_m_file':
    case 'read_mat_file':
    case 'read_simulink': return TIMEOUTS.fileRead;
    default: return TIMEOUTS.default;
  }
}

// ============= 常驻 Python 桥接进程管理 =============

let bridgeProcess: ChildProcess | null = null;
let responseBuffer = '';

// v4.1: 命令队列 — 替代全局 pendingResolve/pendingReject，支持并发安全
interface PendingCommand {
  resolve: (result: MATLABResult) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  progressTimer: NodeJS.Timeout | null;
  startTime: number;
  action: string;
}

const pendingCommands = new Map<string, PendingCommand>();
let commandCounter = 0;

// 串行命令队列 — 同一时刻只发一条命令给 Python Bridge
const commandQueue: Array<{ command: MATLABCommand; id: string }> = [];
let isProcessingCommand = false;

/**
 * 确保常驻 Python 桥接进程已启动
 */
function ensureBridgeProcess(): void {
  if (bridgeProcess && !bridgeProcess.killed) {
    return; // 已有运行中的进程
  }
  
  const startTime = Date.now();
  const currentMatlabRoot = getMATLABRoot();
  console.log(`[MATLAB Bridge] Starting persistent bridge process...`);
  console.log(`[MATLAB Bridge] MATLAB_ROOT: ${currentMatlabRoot}`);
  
  bridgeProcess = spawn('python', [BRIDGE_SCRIPT, '--server'], {
    cwd: path.dirname(BRIDGE_SCRIPT),
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { 
      ...process.env, 
      PYTHONIOENCODING: 'utf-8', 
      PYTHONUNBUFFERED: '1',
      MATLAB_ROOT: currentMatlabRoot,  // 传递 MATLAB_ROOT 给 Python Bridge
    }
  });

  // 桥接进程启动后的就绪信号
  const readyTimeout = setTimeout(() => {
    const elapsed = Math.round((Date.now() - startTime) / 1000);
    console.log(`[MATLAB Bridge] Bridge process running (${elapsed}s)`);
  }, 1000);
  
  // 处理 stdout - JSON 行协议
  bridgeProcess.stdout!.on('data', (data: Buffer) => {
    responseBuffer += data.toString('utf-8');
    // 尝试解析完整的 JSON 行
    const lines = responseBuffer.split('\n');
    // 最后一行可能不完整，保留在 buffer 中
    responseBuffer = lines.pop() || '';
    
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const result = JSON.parse(line.trim()) as MATLABResult & { _requestId?: string };
        // v4.1: 使用请求 ID 匹配回调
        const requestId = result._requestId;
        if (requestId && pendingCommands.has(requestId)) {
          const pending = pendingCommands.get(requestId)!;
          clearTimeout(pending.timer);
          if (pending.progressTimer) clearInterval(pending.progressTimer);
          pendingCommands.delete(requestId);
          pending.resolve(result);
        } else if (!requestId && pendingCommands.size > 0) {
          // 兼容旧格式：没有 _requestId 时，取最早的一条
          const firstKey = pendingCommands.keys().next().value;
          if (firstKey) {
            const pending = pendingCommands.get(firstKey)!;
            clearTimeout(pending.timer);
            if (pending.progressTimer) clearInterval(pending.progressTimer);
            pendingCommands.delete(firstKey);
            pending.resolve(result);
          }
        }
      } catch {
        // 非 JSON 行，忽略
      }
    }
  });
  
  // stderr 只打印日志
  bridgeProcess.stderr!.on('data', (data: Buffer) => {
    const text = data.toString('utf-8');
    process.stdout.write(`[Bridge] ${text}`);
  });
  
  bridgeProcess.on('close', (code) => {
    console.log(`[MATLAB Bridge] Process exited with code ${code}`);
    bridgeProcess = null;
    // 清理所有待处理命令
    for (const [id, pending] of pendingCommands) {
      clearTimeout(pending.timer);
      if (pending.progressTimer) clearInterval(pending.progressTimer);
      pending.reject(new Error('Bridge process exited unexpectedly'));
    }
    pendingCommands.clear();
    commandQueue.length = 0;
    isProcessingCommand = false;
  });
  
  bridgeProcess.on('error', (err) => {
    console.error('[MATLAB Bridge] Process error:', err.message);
    bridgeProcess = null;
    // 清理所有待处理命令
    for (const [id, pending] of pendingCommands) {
      clearTimeout(pending.timer);
      if (pending.progressTimer) clearInterval(pending.progressTimer);
      pending.reject(err);
    }
    pendingCommands.clear();
    commandQueue.length = 0;
    isProcessingCommand = false;
  });
}

/**
 * 通过常驻桥接进程发送命令（v4.1: 串行队列 + 请求 ID）
 * 使用 JSON 行协议：发送一行 JSON，接收一行 JSON 响应
 * 命令串行执行（Python Bridge 是单线程的），但多个请求可以排队等待
 */
async function executeBridgeCommand(command: MATLABCommand): Promise<MATLABResult> {
  ensureBridgeProcess();
  
  if (!bridgeProcess || bridgeProcess.killed) {
    return { status: 'error', message: '桥接进程不可用' };
  }
  
  const timeout = getTimeout(command);
  const requestId = `cmd_${++commandCounter}_${Date.now()}`;
  const startTime = Date.now();
  
  return new Promise<MATLABResult>((resolve, reject) => {
    // 创建待处理命令
    const pending: PendingCommand = {
      resolve,
      reject,
      timer: setTimeout(() => {
        pendingCommands.delete(requestId);
        reject(new Error(`MATLAB 执行超时（${Math.round(timeout / 1000)}秒）`));
      }, timeout),
      progressTimer: setInterval(() => {
        const elapsed = Math.round((Date.now() - startTime) / 1000);
        const actionName = command.action === 'start' ? 'Engine 启动' : 
                            command.action === 'check' ? '兼容性检测' : command.action;
        console.log(`[MATLAB Bridge] ⏳ ${actionName} 执行中... 已等待 ${elapsed}秒`);
      }, PROGRESS_CHECK_INTERVAL),
      startTime,
      action: command.action,
    };
    
    pendingCommands.set(requestId, pending);
    
    // 加入串行队列
    commandQueue.push({ command, id: requestId });
    processQueue();
  });
}

/** 处理命令队列 — 串行发送命令给 Python Bridge */
function processQueue(): void {
  if (isProcessingCommand || commandQueue.length === 0) return;
  if (!bridgeProcess || bridgeProcess.killed) {
    // 桥接进程不可用，拒绝所有排队命令
    for (const item of commandQueue) {
      const pending = pendingCommands.get(item.id);
      if (pending) {
        clearTimeout(pending.timer);
        if (pending.progressTimer) clearInterval(pending.progressTimer);
        pendingCommands.delete(item.id);
        pending.resolve({ status: 'error', message: '桥接进程不可用' });
      }
    }
    commandQueue.length = 0;
    return;
  }
  
  isProcessingCommand = true;
  const { command, id } = commandQueue.shift()!;
  
  // 注入 _requestId 到命令中，以便 Python Bridge 回传时能匹配
  const commandWithId = { ...command, _requestId: id };
  const cmdLine = JSON.stringify(commandWithId) + '\n';
  
  bridgeProcess.stdin!.write(cmdLine, 'utf-8');
  
  // 监听该命令的完成（当 pendingCommands 中该 id 被 resolve 时触发）
  const checkDone = () => {
    if (!pendingCommands.has(id)) {
      // 命令已完成（被 resolve 或超时）
      isProcessingCommand = false;
      processQueue(); // 处理下一条
    } else {
      setTimeout(checkDone, 100); // 还在等
    }
  };
  setTimeout(checkDone, 200);
}

/** 重启桥接进程（切换 MATLAB 版本时使用） */
export async function restartBridge(): Promise<MATLABResult> {
  console.log('[MATLAB Bridge] Restarting bridge with new MATLAB_ROOT...');
  
  // 先停止现有进程
  if (bridgeProcess && !bridgeProcess.killed) {
    try {
      await executeBridgeCommand({ action: 'stop', params: {} });
    } catch {
      // 忽略停止错误
    }
    try {
      bridgeProcess.kill();
    } catch {
      // 忽略 kill 错误
    }
    bridgeProcess = null;
  }
  
  // 清理状态
  responseBuffer = '';
  for (const [id, pending] of pendingCommands) {
    clearTimeout(pending.timer);
    if (pending.progressTimer) clearInterval(pending.progressTimer);
    pending.reject(new Error('Bridge restarting'));
  }
  pendingCommands.clear();
  commandQueue.length = 0;
  isProcessingCommand = false;
  
  // 重新启动（ensureBridgeProcess 会自动启动新进程，并传递新的 MATLAB_ROOT）
  return startMATLAB();
}

// ============= 基础操作 =============

export async function startMATLAB(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'start', params: {} });
}

export async function stopMATLAB(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'stop', params: {} });
}

export function checkMATLABFiles(): Record<string, any> {
  const root = getMATLABRoot();
  const defaultWorkspace = getDefaultWorkspace();
  return {
    status: fs.existsSync(root) ? 'installed' : 'not_configured',
    matlab_root: root,
    matlab_exe_exists: fs.existsSync(path.join(root, 'bin', 'matlab.exe')),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
    workspace_exists: fs.existsSync(defaultWorkspace),
    default_workspace: defaultWorkspace,
  };
}

export async function checkMATLABInstallation(): Promise<MATLABResult & Record<string, any>> {
  const root = getMATLABRoot();
  const defaultWorkspace = getDefaultWorkspace();
  const checks = {
    matlab_root_exists: fs.existsSync(root),
    matlab_exe_exists: fs.existsSync(path.join(root, 'bin', 'matlab.exe')),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
    workspace_exists: fs.existsSync(defaultWorkspace),
    matlab_root: root,
    default_workspace: defaultWorkspace,
  };
  
  try {
    const bridgeResult = await executeBridgeCommand({ action: 'check', params: {} });
    return { ...checks, ...bridgeResult };
  } catch (error: any) {
    return { ...checks, status: 'warning', engine_importable: false, engine_error: error.message };
  }
}

/** 获取 MATLAB 配置信息 */
export function getMATLABConfig(): Record<string, any> {
  const root = getMATLABRoot();
  const rootSource = !root ? 'none' : 
    (process.env.MATLAB_ROOT && fs.existsSync(process.env.MATLAB_ROOT) ? 'env' : 
    (_configuredMatlabRoot ? 'config' : 'none'));
  return {
    matlab_root: root,
    matlab_root_source: rootSource,
    matlab_available: isMATLABAvailable(),
    matlab_exe_exists: root ? fs.existsSync(path.join(root, 'bin', 'matlab.exe')) : false,
    default_workspace: getDefaultWorkspace(),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
  };
}

// ============= 项目管理 =============

export async function setProjectDir(dirPath: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'set_project', params: { dir: dirPath } });
}

export async function scanProjectFiles(dirPath?: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'scan_project', params: { dir: dirPath } });
}

// ============= 文件操作 =============

export async function readMFile(filePath: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'read_m_file', params: { path: filePath } });
}

export async function readMatFile(filePath: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'read_mat_file', params: { path: filePath } });
}

export async function readSimulinkModel(modelPath: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'read_simulink', params: { path: modelPath } });
}

// ============= 脚本执行 =============

export async function executeMATLABScript(
  scriptPath: string,
  options?: { outputDir?: string }
): Promise<MATLABResult> {
  console.log(`[MATLAB] 执行脚本: ${scriptPath}`);
  
  if (!fs.existsSync(scriptPath)) {
    return { status: 'error', message: `脚本文件不存在: ${scriptPath}` };
  }
  
  return executeBridgeCommand({
    action: 'execute_script',
    params: { script_path: scriptPath, output_dir: options?.outputDir }
  });
}

/**
 * 在持久化工作区中直接运行 MATLAB 代码
 * v3.0 核心功能：变量和图形跨命令保持
 */
export async function runMATLABCode(code: string, showOutput: boolean = true): Promise<MATLABResult> {
  console.log(`[MATLAB] 运行代码: ${code.slice(0, 100)}...`);
  return executeBridgeCommand({
    action: 'run_code',
    params: { code, show_output: showOutput }
  });
}

export async function runMATLABCommand(command: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'run_code', params: { code: command, show_output: true } });
}

// ============= 工作区管理 =============

export async function getWorkspaceVariables(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'get_workspace', params: {} });
}

export async function saveWorkspace(filePath?: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'save_workspace', params: { path: filePath } });
}

export async function loadWorkspace(filePath: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'load_workspace', params: { path: filePath } });
}

export async function clearWorkspace(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'clear_workspace', params: {} });
}

// ============= Simulink =============

export async function createSimulinkModel(modelName: string, modelPath?: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'create_simulink', params: { model_name: modelName, model_path: modelPath } });
}

export async function runSimulinkSimulation(modelName: string, stopTime: string = '10'): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'run_simulink', params: { model_name: modelName, stop_time: stopTime } });
}

export async function openSimulinkModel(modelName: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'open_simulink', params: { model_name: modelName } });
}

// ============= Simulink 模型工作区（v4.1 新增）=============

export async function setSimulinkWorkspaceVar(modelName: string, varName: string, varValue: any): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'set_simulink_workspace', params: { model_name: modelName, var_name: varName, var_value: varValue } });
}

export async function getSimulinkWorkspaceVars(modelName: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'get_simulink_workspace', params: { model_name: modelName } });
}

export async function clearSimulinkWorkspace(modelName: string): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'clear_simulink_workspace', params: { model_name: modelName } });
}

// ============= 图形管理 =============

export async function listFigures(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'list_figures', params: {} });
}

export async function closeAllFigures(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'close_figures', params: {} });
}

// ============= 辅助函数 =============

export function ensureWorkspace(workDir?: string): string {
  const dir = workDir || getDefaultWorkspace();
  if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
  return dir;
}

export function createMFile(filePath: string, content: string): { success: boolean; message: string } {
  try {
    const dir = path.dirname(filePath);
    if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); }
    const bom = Buffer.from([0xEF, 0xBB, 0xBF]);
    const contentBuffer = Buffer.from(content, 'utf-8');
    fs.writeFileSync(filePath, Buffer.concat([bom, contentBuffer]));
    return { success: true, message: `M 文件已创建: ${filePath}` };
  } catch (error: any) {
    return { success: false, message: `创建 M 文件失败: ${error.message}` };
  }
}

export function parseMATLABError(output: string): {
  hasError: boolean; errorMessage: string; fileHint?: string; lineHint?: number; suggestions: string[];
} {
  if (!output) return { hasError: false, errorMessage: '', suggestions: [] };
  
  const patterns = [
    { regex: /Error using\s+(\w+).*?\n.*?line (\d+)/i, type: 'usage' },
    { regex: /Error in\s+(\S+).*?\(line (\d+)\)/i, type: 'runtime' },
    { regex: /Undefined (?:function|variable) ['"]?(\w+)/i, type: 'undefined' },
    { regex: /Index exceeds (?:matrix dimensions|array bounds)/i, type: 'index' },
    { regex: /Matrix dimensions must agree/i, type: 'dimension' },
    { regex: /Not enough input arguments/i, type: 'args' },
    { regex: /Too many input arguments/i, type: 'args' },
    { regex: /Unrecognized function or variable/i, type: 'undefined' },
    { regex: /Simulink error:/i, type: 'simulink' },
    { regex: /Block error/i, type: 'simulink' },
  ];
  
  let errorMessage = '', errorType = '';
  let fileHint: string | undefined, lineHint: number | undefined;
  const suggestions: string[] = [];
  
  for (const { regex, type } of patterns) {
    const match = output.match(regex);
    if (match) {
      errorMessage = match[0]; errorType = type;
      if (match[2]) { fileHint = match[1]; lineHint = parseInt(match[2]); }
      break;
    }
  }
  
  const suggestionMap: Record<string, string[]> = {
    undefined: ['检查函数名拼写', '确认 .m 文件已添加到 MATLAB 路径', '使用 addpath() 添加依赖目录'],
    index: ['检查数组索引是否超出范围', 'MATLAB 数组索引从 1 开始'],
    dimension: ['使用 size() 检查矩阵维度', '考虑使用转置或 reshape()'],
    args: ['使用 nargin 检查参数数量', '确认函数签名与调用方式一致'],
    simulink: ['检查模块参数设置', '确认信号维度在各模块间一致'],
  };
  
  if (errorType && suggestionMap[errorType]) suggestions.push(...suggestionMap[errorType]);
  
  return { hasError: !!errorMessage || output.includes('error') || output.includes('Error'), errorMessage, fileHint, lineHint, suggestions };
}
