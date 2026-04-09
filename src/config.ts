/**
 * MATLAB Agent 应用配置
 * 
 * v4.0 通用化: matlabVersion 和 matlabRoot 不再硬编码，
 * 运行时从后端 /api/matlab/config 动态获取。
 */

export const APP_CONFIG = {
  /** 应用名称 */
  name: 'MATLAB Agent',
  
  /** 应用名称首字母（用于 Logo） */
  nameInitial: 'M',
  
  /** 应用描述 */
  description: 'AI 驱动的 MATLAB/Simulink 开发助手',
  
  /** 版本号 */
  version: '4.0.0',

  /** MATLAB 版本（运行时动态获取，此处为默认值） */
  matlabVersion: '',

  /** MATLAB 安装路径（运行时动态获取，此处为默认值） */
  matlabRoot: '',

  /** 默认工作目录 */
  defaultWorkspace: '',

  /** API 基础地址 */
  apiBase: '/api',
};

/** 动态获取 MATLAB 配置 */
export async function fetchMATLABConfig(): Promise<{
  matlabVersion: string;
  matlabRoot: string;
  connectionMode: string;
  detectedInstallations: Array<{ version: string; release: string; root: string }>;
}> {
  try {
    const res = await fetch('/api/matlab/config');
    const data = await res.json();
    
    // 从安装路径中提取版本
    let version = '';
    const root = data.matlab_root || '';
    const m = root.match(/R\d{4}[ab]/i) || root.match(/MATLAB\s*(\d{4})/i);
    if (m) version = m[0];
    
    APP_CONFIG.matlabVersion = version;
    APP_CONFIG.matlabRoot = root;
    APP_CONFIG.defaultWorkspace = data.default_workspace || '';
    
    return {
      matlabVersion: version,
      matlabRoot: root,
      connectionMode: data.matlab_root_source || 'unknown',
      detectedInstallations: data.detected_installations || [],
    };
  } catch {
    return {
      matlabVersion: '',
      matlabRoot: '',
      connectionMode: 'unknown',
      detectedInstallations: [],
    };
  }
}

export default APP_CONFIG;
