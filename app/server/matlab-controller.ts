/**
* MATLAB Controller v5.2 - 通用化后端 MATLAB 控制器
* 
* 核心架构: 使用常驻 Python 桥接进程（--server 模式）
* - Python 进程保持运行，MATLAB Engine 持久化
* - 变量跨命令保持，图形窗口实时显示
* - 通过 stdin/stdout JSON 行协议通信
* 
* v5.2 变更（2026-04-14）:
* - 新增 ensureDataDirSync(): 启动时自动检测并迁移 app/data/ 下的配置到 data/，彻底解决双目录问题
* - 新增 LEGACY_DATA_DIR / LEGACY_CONFIG_FILE 常量标识冗余数据路径
* - 修复 bat 脚本: PowerShell -NoProfile + 2>nul 替代 >nul 2>&1（避免 cmd /c 输入重定向错误）
* 
* v5.1.1 变更（2026-04-14）:
* - 修复 loadConfigFromFile: 清理 DEBUG 日志 + 无效路径自动清理 + 损坏配置自动重建
* - 修复 restartBridge: stop 命令加 5 秒超时，避免卡住
* - 修复配置文件路径歧义: CONFIG_DIR 明确为 skills/matlab-agent/data/（非 app/data/）
* 
* v5.0 变更（2026-04-10）:
* - 修复 executeMATLABScript 相对路径解析（基于项目目录而非 CWD）
* - 添加项目目录缓存 getProjectDir()
* - 与 Python Bridge v5.0 diary 重构配合
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
let _rootSource: 'none' | 'env' | 'config' | 'api' = 'none';

// 配置文件路径 — 统一为 skills/matlab-agent/data/（__dirname 是 app/server/，向上两层到 skills/matlab-agent/）
const CONFIG_DIR = path.join(__dirname, '..', '..', 'data');
const CONFIG_FILE = path.join(CONFIG_DIR, 'matlab-config.json');

// 可能存在的冗余数据目录（旧版或手动创建），启动时自动迁移
const LEGACY_DATA_DIR = path.join(__dirname, '..', 'data');
const LEGACY_CONFIG_FILE = path.join(LEGACY_DATA_DIR, 'matlab-config.json');

/**
 * 启动时数据目录自检与自动迁移（v5.2 固化踩坑经验）
 * 
 * 踩坑背景:
 * - 存在两个 data/ 目录: skills/matlab-agent/data/ 和 app/data/
 * - Node 服务读写的正确路径是 skills/matlab-agent/data/（CONFIG_DIR）
 * - 但 app/data/ 可能被手动创建，里面也有 matlab-config.json 和 chat.db
 * - 两个目录不同步 → 改了这边那边不变 → 配置检测失灵
 * 
 * 解决方案:
 * - 启动时检测 app/data/ 下是否有 matlab-config.json
 * - 如果有，且 skills/matlab-agent/data/ 下没有，则自动迁移
 * - 迁移后删除旧文件的配置部分（保留 chat.db 不动，因为那是 index.ts 管理的）
 * - 确保唯一数据源: skills/matlab-agent/data/
 */
function ensureDataDirSync(): void {
  try {
    // 1. 确保主数据目录存在
    if (!fs.existsSync(CONFIG_DIR)) {
      fs.mkdirSync(CONFIG_DIR, { recursive: true });
      console.log(`[MATLAB Config] 已创建数据目录: ${CONFIG_DIR}`);
    }

    // 2. 检查冗余目录是否有需要迁移的配置
    if (fs.existsSync(LEGACY_CONFIG_FILE)) {
      try {
        const legacyContent = fs.readFileSync(LEGACY_CONFIG_FILE, 'utf-8').trim();
        const legacyConfig = JSON.parse(legacyContent);
        
        // 只有当 legacy 有有效配置且主目录没有时才迁移
        if (legacyConfig.matlab_root && typeof legacyConfig.matlab_root === 'string' && legacyConfig.matlab_root.trim()) {
          const mainContent = fs.existsSync(CONFIG_FILE) 
            ? fs.readFileSync(CONFIG_FILE, 'utf-8').trim() 
            : '{}';
          const mainConfig = JSON.parse(mainContent);
          
          if (!mainConfig.matlab_root) {
            // 主目录没有配置，从 legacy 迁移
            mainConfig.matlab_root = legacyConfig.matlab_root;
            if (legacyConfig.updated_at) mainConfig.updated_at = legacyConfig.updated_at;
            mainConfig.migrated_from = LEGACY_CONFIG_FILE;
            mainConfig.migrated_at = new Date().toISOString();
            fs.writeFileSync(CONFIG_FILE, JSON.stringify(mainConfig, null, 2), 'utf-8');
            console.log(`[MATLAB Config] ⚡ 已自动迁移配置: ${LEGACY_CONFIG_FILE} → ${CONFIG_FILE}`);
            console.log(`[MATLAB Config] 迁移的 MATLAB_ROOT: ${legacyConfig.matlab_root}`);
          }
        }
        
        // 无论是否迁移，都清除 legacy 配置文件避免后续混淆
        fs.writeFileSync(LEGACY_CONFIG_FILE, '{}', 'utf-8');
        console.log(`[MATLAB Config] 已清空冗余配置文件: ${LEGACY_CONFIG_FILE}`);
      } catch (err: any) {
        console.warn(`[MATLAB Config] 迁移冗余配置时出错: ${err.message}`);
      }
    }
  } catch (err: any) {
    console.warn(`[MATLAB Config] 数据目录自检失败: ${err.message}`);
  }
}

// 启动时立即执行数据目录自检
ensureDataDirSync();

/** 从配置文件读取 MATLAB_ROOT
 * v5.1.1: 清理 DEBUG 日志 + 增强空值/损坏配置自动修复
 * - 配置文件为空或 matlab_root 为空时，自动重置为 {} 避免歧义
 * - 文件损坏时备份并重建
 */
function loadConfigFromFile(): string | null {
  try {
    if (!fs.existsSync(CONFIG_FILE)) return null;
    const raw = fs.readFileSync(CONFIG_FILE, 'utf-8').trim();
    if (!raw || raw === '{}') return null;  // 空文件或空 JSON
    const config = JSON.parse(raw);
    const root = config.matlab_root;
    if (!root || typeof root !== 'string' || !root.trim()) return null;  // 空值
    if (fs.existsSync(root)) return root;
    // 路径不存在，清理无效配置
    console.warn(`[MATLAB Config] 配置的路径不存在: ${root}，将清除无效配置`);
    try {
      const bakFile = CONFIG_FILE + '.bak';
      fs.copyFileSync(CONFIG_FILE, bakFile);
      fs.writeFileSync(CONFIG_FILE, '{}', 'utf-8');
    } catch { /* 忽略清理失败 */ }
    return null;
  } catch (err: any) {
    // 配置文件损坏，备份并重建
    console.warn(`[MATLAB Config] 配置文件损坏，将重建: ${err.message}`);
    try {
      const bakFile = CONFIG_FILE + '.corrupt.bak';
      fs.copyFileSync(CONFIG_FILE, bakFile);
      fs.writeFileSync(CONFIG_FILE, '{}', 'utf-8');
    } catch { /* 忽略重建失败 */ }
    return null;
  }
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
    _rootSource = 'env';
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
    _rootSource = 'config';
    return fileRoot;
  }
  // 未配置，返回空字符串
  _rootSource = 'none';
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
  _rootSource = 'api';
  console.log(`[MATLAB Config] MATLAB_ROOT 已设置为: ${normalizedPath}`);
  return { success: true, message: `MATLAB_ROOT 已设置为 ${normalizedPath}` };
}

/** 重置 MATLAB 配置（清除内存缓存 + 删除配置文件） */
export function resetMATLABConfig(): { success: boolean; message: string } {
  _configuredMatlabRoot = null;
  _rootSource = 'none';
  try {
    if (fs.existsSync(CONFIG_FILE)) {
      // 备份当前配置
      const bakFile = CONFIG_FILE + '.bak';
      fs.copyFileSync(CONFIG_FILE, bakFile);
      fs.unlinkSync(CONFIG_FILE);
      console.log(`[MATLAB Config] 配置已重置（已备份到 ${bakFile}）`);
      return { success: true, message: 'MATLAB 配置已重置。请重新设置 MATLAB 安装路径。' };
    }
    return { success: true, message: '配置文件不存在，无需重置。' };
  } catch (err: any) {
    return { success: false, message: `重置配置失败: ${err.message}` };
  }
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

// 超时配置（毫秒）
// 注意：RL训练、仿真等任务可能需要很长时间，超时过短会导致Engine被锁死
const TIMEOUTS = {
  script: 1800_000,        // 30分钟 — 训练脚本等长时间任务
  simulinkCreate: 120_000,  // 2分钟
  simulinkRun: 1800_000,    // 30分钟 — Simulink仿真可能很长
  check: 60_000,            // 1分钟
  projectScan: 30_000,      // 30秒
  fileRead: 60_000,         // 1分钟
  runCode: 1800_000,        // 30分钟 — 代码执行可能包含训练/仿真
  engineStart: 90_000,      // Engine 启动超时（含兼容性检测）
  engineCompatTest: 45_000, // Engine 兼容性测试超时
  default: 1800_000,        // 30分钟
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

// v5.0: Node.js 侧缓存项目目录，用于相对路径解析
let _cachedProjectDir: string | null = null;

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
        // 超时后重启桥接进程，否则Engine被锁死会导致后续所有命令都无法执行
        console.log(`[MATLAB Bridge] ⚠️ 命令 ${command.action} 超时（${Math.round(timeout / 1000)}秒），重启桥接进程...`);
        restartBridge().catch(err => console.error('[MATLAB Bridge] 重启桥接失败:', err.message));
        reject(new Error(`MATLAB 执行超时（${Math.round(timeout / 1000)}秒），桥接进程已自动重启`));
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

/** 重启桥接进程（切换 MATLAB 版本时使用）
 * v5.1.1: stop 命令加 5 秒超时，避免卡住
 */
export async function restartBridge(): Promise<MATLABResult> {
  console.log('[MATLAB Bridge] Restarting bridge with new MATLAB_ROOT...');
  
  // 先停止现有进程（5 秒超时，避免 stop 命令卡住）
  if (bridgeProcess && !bridgeProcess.killed) {
    try {
      await Promise.race([
        executeBridgeCommand({ action: 'stop', params: {} }),
        new Promise<void>((_, reject) => setTimeout(() => reject(new Error('stop timeout')), 5000))
      ]);
    } catch {
      // 超时或错误，直接 kill
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
  return {
    matlab_root: root,
    matlab_root_source: _rootSource,
    matlab_available: isMATLABAvailable(),
    matlab_exe_exists: root ? fs.existsSync(path.join(root, 'bin', 'matlab.exe')) : false,
    default_workspace: getDefaultWorkspace(),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
  };
}

// ============= 项目管理 =============

export async function setProjectDir(dirPath: string): Promise<MATLABResult> {
  _cachedProjectDir = dirPath;  // v5.0: 缓存项目目录到 Node.js 侧
  return executeBridgeCommand({ action: 'set_project', params: { dir: dirPath } });
}

/** 获取当前项目目录（Node.js 侧缓存） */
export function getProjectDir(): string | null {
  return _cachedProjectDir;
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
  
  // v5.0: 修复相对路径问题 — 相对路径应基于项目目录解析，而非 Node.js CWD
  let resolvedPath = scriptPath;
  if (!path.isAbsolute(scriptPath)) {
    const projectDir = getProjectDir();
    if (projectDir) {
      resolvedPath = path.join(projectDir, scriptPath);
    }
  }
  
  if (!fs.existsSync(resolvedPath)) {
    return { status: 'error', message: `脚本文件不存在: ${resolvedPath}（原始路径: ${scriptPath}）` };
  }
  
  return executeBridgeCommand({
    action: 'execute_script',
    params: { script_path: resolvedPath, output_dir: options?.outputDir }
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

// ============= Quickstart API（v5.0 新增）=============

/**
 * 一键快速启动 MATLAB 开发环境
 * 
 * 合并以下步骤为一次调用：
 * 1. 检查/设置 MATLAB_ROOT
 * 2. 启动 MATLAB Engine（如未启动）
 * 3. 设置项目工作目录
 * 
 * 返回完整状态信息，让 AI 一步到位进入 MATLAB 开发状态。
 */
export async function quickstartMATLAB(options: {
  matlabRoot?: string;
  projectDir?: string;
}): Promise<MATLABResult & {
  matlab_root?: string;
  project_dir?: string;
  connection_mode?: string;
  steps?: string[];
}> {
  const steps: string[] = [];
  
  // Step 1: 检查/设置 MATLAB_ROOT
  let currentRoot = getMATLABRoot();
  if (options.matlabRoot && options.matlabRoot !== currentRoot) {
    const setResult = setMATLABRoot(options.matlabRoot);
    if (!setResult.success) {
      return { status: 'error', message: `MATLAB_ROOT 设置失败: ${setResult.message}`, steps };
    }
    currentRoot = options.matlabRoot;
    steps.push(`MATLAB_ROOT 已设置为: ${currentRoot}`);
  } else if (currentRoot) {
    steps.push(`MATLAB_ROOT 已配置: ${currentRoot}`);
  } else {
    return { status: 'error', message: 'MATLAB_ROOT 未配置。请提供 matlabRoot 参数或通过 /api/matlab/config 设置。', steps };
  }
  
  // Step 2: 启动 MATLAB Engine
  try {
    const startResult = await startMATLAB();
    steps.push(`MATLAB Engine: ${startResult.message || startResult.status}`);
    
    if (startResult.status === 'error') {
      return { status: 'warning', message: 'MATLAB 启动异常，但部分配置已就绪', 
               matlab_root: currentRoot, steps, connection_mode: startResult.connection_mode };
    }
  } catch (err: any) {
    steps.push(`MATLAB 启动异常: ${err.message}`);
  }
  
  // Step 3: 设置项目目录
  let projectDir = options.projectDir || _cachedProjectDir || getDefaultWorkspace();
  if (projectDir) {
    try {
      const setResult = await setProjectDir(projectDir);
      steps.push(`项目目录: ${setResult.project_dir || projectDir} (${setResult.connection_mode || 'unknown'})`);
      projectDir = setResult.project_dir || projectDir;
    } catch (err: any) {
      steps.push(`设置项目目录失败: ${err.message}`);
    }
  }
  
  return { 
    status: 'ok', 
    message: 'MATLAB 环境已就绪',
    matlab_root: currentRoot, 
    project_dir: projectDir,
    steps 
  };
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
