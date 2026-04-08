/**
 * MATLAB Controller v3.0 - 后端 MATLAB 控制器
 * 
 * 核心架构: 使用常驻 Python 桥接进程（--server 模式）
 * - Python 进程保持运行，MATLAB Engine 持久化
 * - 变量跨命令保持，图形窗口实时显示
 * - 通过 stdin/stdout JSON 行协议通信
 */

import { execFile, spawn, ChildProcess } from "child_process";
import { promisify } from "util";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { fileURLToPath } from "url";

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const MATLAB_ROOT = 'D:\\Program Files(x86)\\MATLAB2023b';
const MATLAB_BIN = path.join(MATLAB_ROOT, 'bin', 'matlab.exe');
const BRIDGE_SCRIPT = path.join(__dirname, '..', 'matlab-bridge', 'matlab_bridge.py');
const DEFAULT_WORKSPACE = 'D:\\MATLAB_Workspace';

// 超时配置
const TIMEOUTS = {
  script: 120_000,
  simulinkCreate: 120_000,
  simulinkRun: 300_000,
  check: 60_000,
  projectScan: 30_000,
  fileRead: 60_000,
  runCode: 120_000,
  default: 300_000,
};

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
    case 'check': return TIMEOUTS.check;
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
let pendingResolve: ((result: MATLABResult) => void) | null = null;
let pendingReject: ((error: Error) => void) | null = null;
let pendingTimer: NodeJS.Timeout | null = null;

/**
 * 确保常驻 Python 桥接进程已启动
 */
function ensureBridgeProcess(): void {
  if (bridgeProcess && !bridgeProcess.killed) {
    return; // 已有运行中的进程
  }
  
  console.log('[MATLAB Bridge] Starting persistent bridge process...');
  
  bridgeProcess = spawn('python', [BRIDGE_SCRIPT, '--server'], {
    cwd: path.dirname(BRIDGE_SCRIPT),
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONUNBUFFERED: '1' }
  });
  
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
        const result = JSON.parse(line.trim()) as MATLABResult;
        if (pendingResolve) {
          if (pendingTimer) clearTimeout(pendingTimer);
          const resolve = pendingResolve;
          pendingResolve = null;
          pendingReject = null;
          pendingTimer = null;
          resolve(result);
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
    if (pendingReject) {
      pendingReject(new Error('Bridge process exited unexpectedly'));
      pendingResolve = null;
      pendingReject = null;
      pendingTimer = null;
    }
  });
  
  bridgeProcess.on('error', (err) => {
    console.error('[MATLAB Bridge] Process error:', err.message);
    bridgeProcess = null;
    if (pendingReject) {
      pendingReject(err);
      pendingResolve = null;
      pendingReject = null;
      pendingTimer = null;
    }
  });
}

/**
 * 通过常驻桥接进程发送命令
 * 使用 JSON 行协议：发送一行 JSON，接收一行 JSON 响应
 */
async function executeBridgeCommand(command: MATLABCommand): Promise<MATLABResult> {
  ensureBridgeProcess();
  
  if (!bridgeProcess || bridgeProcess.killed) {
    return { status: 'error', message: '桥接进程不可用' };
  }
  
  const timeout = getTimeout(command);
  const cmdLine = JSON.stringify(command) + '\n';
  
  return new Promise<MATLABResult>((resolve, reject) => {
    // 设置超时
    pendingTimer = setTimeout(() => {
      pendingResolve = null;
      pendingReject = null;
      pendingTimer = null;
      reject(new Error(`MATLAB 执行超时（${Math.round(timeout / 1000)}秒）`));
    }, timeout);
    
    pendingResolve = resolve;
    pendingReject = reject;
    
    // 发送命令
    bridgeProcess!.stdin!.write(cmdLine, 'utf-8');
  });
}

// ============= 基础操作 =============

export async function startMATLAB(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'start', params: {} });
}

export async function stopMATLAB(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'stop', params: {} });
}

export function checkMATLABFiles(): Record<string, any> {
  return {
    status: fs.existsSync(MATLAB_ROOT) ? 'installed' : 'not_found',
    matlab_root: MATLAB_ROOT,
    matlab_exe_exists: fs.existsSync(MATLAB_BIN),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
    workspace_exists: fs.existsSync(DEFAULT_WORKSPACE),
    default_workspace: DEFAULT_WORKSPACE
  };
}

export async function checkMATLABInstallation(): Promise<MATLABResult & Record<string, any>> {
  const checks = {
    matlab_root_exists: fs.existsSync(MATLAB_ROOT),
    matlab_exe_exists: fs.existsSync(MATLAB_BIN),
    bridge_script_exists: fs.existsSync(BRIDGE_SCRIPT),
    workspace_exists: fs.existsSync(DEFAULT_WORKSPACE),
    matlab_root: MATLAB_ROOT,
    default_workspace: DEFAULT_WORKSPACE
  };
  
  try {
    const bridgeResult = await executeBridgeCommand({ action: 'check', params: {} });
    return { ...checks, ...bridgeResult };
  } catch (error: any) {
    return { ...checks, status: 'warning', engine_importable: false, engine_error: error.message };
  }
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

// ============= 图形管理 =============

export async function listFigures(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'list_figures', params: {} });
}

export async function closeAllFigures(): Promise<MATLABResult> {
  return executeBridgeCommand({ action: 'close_figures', params: {} });
}

// ============= 辅助函数 =============

export function ensureWorkspace(workDir?: string): string {
  const dir = workDir || DEFAULT_WORKSPACE;
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
    dimension: ['使用 size() 检查矩阵维度', '考虑使用转置 或 reshape()'],
    args: ['使用 nargin 检查参数数量', '确认函数签名与调用方式一致'],
    simulink: ['检查模块参数设置', '确认信号维度在各模块间一致'],
  };
  
  if (errorType && suggestionMap[errorType]) suggestions.push(...suggestionMap[errorType]);
  
  return { hasError: !!errorMessage || output.includes('error') || output.includes('Error'), errorMessage, fileHint, lineHint, suggestions };
}
