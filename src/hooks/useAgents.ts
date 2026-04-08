import { useState, useEffect, useCallback } from 'react';
import { CustomAgent } from '../types';
import { v4 as uuidv4 } from 'uuid';
import { APP_CONFIG } from '../config';

const STORAGE_KEY = 'customAgents';

// MATLAB 开发助手（默认 Agent）
const MATLAB_AGENT: CustomAgent = {
  id: 'matlab-default',
  name: 'MATLAB 开发',
  description: '专业的 MATLAB M 语言开发助手，擅长信号处理、控制律设计、数据分析',
  systemPrompt: `你是「MATLAB Agent」—— 专业的 MATLAB 开发助手。你像一位资深 MATLAB 技术员一样工作：理解需求、编写代码、自动运行、分析错误、迭代修复。环境：MATLAB R2023b，路径：D:\\Program Files (x86)\\MATLAB2023b。编码规范：向量化优先、计算与绘图分离、UTF-8编码、输入验证。索引从1开始。`,
  icon: 'Cpu',
  color: '#0076a8',  // MATLAB 蓝
  permissionMode: 'bypassPermissions',
  createdAt: new Date(),
  updatedAt: new Date(),
};

// Simulink 建模助手
const SIMULINK_AGENT: CustomAgent = {
  id: 'simulink-default',
  name: 'Simulink 建模',
  description: 'Simulink 仿真建模专家，擅长动力学系统建模、控制律设计',
  systemPrompt: `你是「Simulink Agent」—— 专业的 Simulink 仿真建模助手。你擅长：动力学系统建模（刚体/柔性体）、传递函数与状态空间模型、PID/LQR控制器设计。使用 MATLAB API 构建模型（add_block, add_line, set_param）。仿真配置使用 sim() 命令。MATLAB R2023b，路径：D:\\Program Files (x86)\\MATLAB2023b。`,
  icon: 'Boxes',
  color: '#d4442a',  // Simulink 橙红
  permissionMode: 'bypassPermissions',
  createdAt: new Date(),
  updatedAt: new Date(),
};

// 通用助手（保留）
const DEFAULT_AGENT: CustomAgent = {
  id: 'default',
  name: '通用助手',
  description: '通用的 AI 助手，可以处理各种编程和技术问题',
  systemPrompt: '你是一个专业的AI助手，善于帮助用户解决各种编程和技术问题。',
  icon: 'Bot',
  color: '#333333',
  createdAt: new Date(),
  updatedAt: new Date(),
};

export function useAgents() {
  const [agents, setAgents] = useState<CustomAgent[]>(() => {
    try {
      const saved = localStorage.getItem(STORAGE_KEY);
      if (saved) {
        const parsed = JSON.parse(saved);
        return [MATLAB_AGENT, SIMULINK_AGENT, DEFAULT_AGENT, ...parsed.map((a: any) => ({
          ...a,
          createdAt: new Date(a.createdAt),
          updatedAt: new Date(a.updatedAt),
        }))];
      }
    } catch (e) {
      console.error('Failed to load agents:', e);
    }
    return [MATLAB_AGENT, SIMULINK_AGENT, DEFAULT_AGENT];
  });

  const saveAgents = useCallback((newAgents: CustomAgent[]) => {
    // 保存用户自定义的 Agent（排除系统预设的）
    const systemIds = ['matlab-default', 'simulink-default', 'default'];
    const toSave = newAgents.filter(a => !systemIds.includes(a.id));
    localStorage.setItem(STORAGE_KEY, JSON.stringify(toSave));
  }, []);

  const addAgent = useCallback((agent: Omit<CustomAgent, 'id' | 'createdAt' | 'updatedAt'>) => {
    const newAgent: CustomAgent = {
      ...agent,
      id: uuidv4(),
      createdAt: new Date(),
      updatedAt: new Date(),
    };
    setAgents(prev => {
      const updated = [...prev, newAgent];
      saveAgents(updated);
      return updated;
    });
    return newAgent;
  }, [saveAgents]);

  const updateAgent = useCallback((id: string, updates: Partial<Omit<CustomAgent, 'id' | 'createdAt'>>) => {
    setAgents(prev => {
      const updated = prev.map(a => 
        a.id === id ? { ...a, ...updates, updatedAt: new Date() } : a
      );
      saveAgents(updated);
      return updated;
    });
  }, [saveAgents]);

  const deleteAgent = useCallback((id: string) => {
    // 不能删除系统预设 Agent
    const systemIds = ['matlab-default', 'simulink-default', 'default'];
    if (systemIds.includes(id)) return;
    setAgents(prev => {
      const updated = prev.filter(a => a.id !== id);
      saveAgents(updated);
      return updated;
    });
  }, [saveAgents]);

  const getAgent = useCallback((id: string) => {
    return agents.find(a => a.id === id);
  }, [agents]);

  return {
    agents,
    addAgent,
    updateAgent,
    deleteAgent,
    getAgent,
    defaultAgent: MATLAB_AGENT,  // 默认使用 MATLAB Agent
    matlabAgent: MATLAB_AGENT,
    simulinkAgent: SIMULINK_AGENT,
  };
}
