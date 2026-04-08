import express from "express";
import { query, unstable_v2_createSession, unstable_v2_authenticate, PermissionResult, CanUseTool } from "@tencent-ai/agent-sdk";
import { v4 as uuidv4 } from "uuid";
import path from "path";
import { fileURLToPath } from "url";
import { exec } from "child_process";
import { promisify } from "util";
import * as db from "./db.js";
import * as matlab from "./matlab-controller.js";
import { MATLAB_SYSTEM_PROMPT, SIMULINK_SYSTEM_PROMPT } from "./system-prompts.js";

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

// 健康检查
app.get("/api/health", (req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString() });
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
      matlab_root: 'D:\\Program Files(x86)\\MATLAB2023b'
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
    
    // 解析错误
    if (result.status === 'error') {
      const parsed = matlab.parseMATLABError(result.stdout || result.message || '');
      res.json({ ...result, ...parsed });
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
    const dirPath = req.query.dir as string | undefined;
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
    if (result.status === 'error') {
      const parsed = matlab.parseMATLABError(result.stdout || result.message || '');
      res.json({ ...result, ...parsed });
    } else {
      res.json(result);
    }
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

// 启动 MATLAB Engine（持久化）
app.post("/api/matlab/start", async (req, res) => {
  try {
    const result = await matlab.startMATLAB();
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
    if (agentId === SIMULINK_AGENT_ID) return SIMULINK_SYSTEM_PROMPT;
    return MATLAB_SYSTEM_PROMPT; // 默认使用 MATLAB 提示词
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
  console.log(`
╔════════════════════════════════════════════════════╗
║                                                    ║
║     ◉ MATLAB Agent - API 服务器已启动              ║
║                                                    ║
║     地址: http://localhost:${PORT}                    ║
║     MATLAB: R2023b                                  ║
║     数据库: SQLite (data/chat.db)                  ║
║                                                    ║
╚════════════════════════════════════════════════════╝
  `);
});
