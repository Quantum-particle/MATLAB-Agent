import { useState, useEffect } from 'react';
import { Tag, Tooltip, Dialog, Input, Button, MessagePlugin } from 'tdesign-react';
import { CheckCircleIcon, ErrorCircleIcon, LoadingIcon, SettingIcon } from 'tdesign-icons-react';

interface MATLABStatus {
  status: 'ok' | 'warning' | 'error';
  matlab_root_exists: boolean;
  matlab_exe_exists: boolean;
  bridge_script_exists: boolean;
  engine_importable?: boolean;
  detected_installations?: Array<{ version: string; release: string; root: string; exeExists: boolean }>;
  matlab_root?: string;
  engine_error?: string;
  message?: string;
  connection_mode?: string;
}

interface MATLABConfig {
  matlab_root: string;
  matlab_root_source: string;
  matlab_available: boolean;
  matlab_exe_exists: boolean;
  detected_installations?: Array<{ version: string; release: string; root: string; exeExists: boolean }>;
}

/** 从 MATLAB_ROOT 路径中提取版本号 */
function extractVersion(root: string | undefined): string {
  if (!root) return '';
  const m = root.match(/R\d{4}[ab]/i);
  if (m) return m[0];
  const m2 = root.match(/MATLAB\s*(\d{4})[ab]?/i);
  if (m2) return m2[0];
  return '';
}

export function MATLABStatusBar() {
  const [status, setStatus] = useState<MATLABStatus | null>(null);
  const [config, setConfig] = useState<MATLABConfig | null>(null);
  const [checking, setChecking] = useState(true);
  const [version, setVersion] = useState('');
  const [showConfig, setShowConfig] = useState(false);
  const [configPath, setConfigPath] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    checkStatus();
  }, []);

  const checkStatus = async () => {
    setChecking(true);
    try {
      // 并行获取状态和配置
      const [statusRes, configRes] = await Promise.all([
        fetch('/api/matlab/status'),
        fetch('/api/matlab/config'),
      ]);
      const statusData = await statusRes.json();
      const configData = await configRes.json();
      
      setStatus(statusData);
      setConfig(configData);
      setVersion(extractVersion(configData.matlab_root));
    } catch {
      setStatus({
        status: 'error',
        matlab_root_exists: false,
        matlab_exe_exists: false,
        bridge_script_exists: false,
      });
    } finally {
      setChecking(false);
    }
  };

  const handleSaveConfig = async () => {
    if (!configPath.trim()) {
      MessagePlugin.warning('请输入 MATLAB 安装目录');
      return;
    }
    setSaving(true);
    try {
      const res = await fetch('/api/matlab/config', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ matlab_root: configPath.trim() }),
      });
      const data = await res.json();
      if (data.success) {
        MessagePlugin.success('MATLAB 路径已保存！正在预热 Engine...');
        setShowConfig(false);
        // 刷新状态并触发重新预热
        await checkStatus();
        // 触发 MATLAB 启动
        try {
          await fetch('/api/matlab/start', { method: 'POST' });
        } catch {}
        // 5 秒后再次刷新状态
        setTimeout(checkStatus, 5000);
        setTimeout(checkStatus, 30000);
      } else {
        MessagePlugin.error(data.message || '保存失败');
      }
    } catch (err: any) {
      MessagePlugin.error('保存失败: ' + err.message);
    } finally {
      setSaving(false);
    }
  };

  const openConfig = () => {
    setConfigPath(config?.matlab_root || '');
    setShowConfig(true);
  };

  if (checking) {
    return (
      <Tag
        size="small"
        variant="light"
        icon={<LoadingIcon size="14px" />}
        style={{ cursor: 'pointer' }}
        onClick={checkStatus}
      >
        检查 MATLAB...
      </Tag>
    );
  }

  if (!status) return null;

  const isReady = status.matlab_exe_exists;
  const isNotConfigured = !config?.matlab_root;
  const versionLabel = version || 'MATLAB';
  
  return (
    <>
      <Tooltip
        content={
          <div style={{ fontSize: '12px', lineHeight: '1.6' }}>
            {isNotConfigured ? (
              <div style={{ color: '#e6a23c' }}>⚠️ 尚未配置 MATLAB 路径，点击设置</div>
            ) : (
              <>
                <div>MATLAB {version}: {status.matlab_root_exists ? '✓ 已找到' : '✗ 未找到'}</div>
                <div>matlab.exe: {status.matlab_exe_exists ? '✓ 正常' : '✗ 缺失'}</div>
                <div>Python 桥接: {status.bridge_script_exists ? '✓ 已部署' : '✗ 缺失'}</div>
                <div>Engine API: {status.engine_importable ? '✓ 可用' : '✗ 未安装（将使用 CLI 回退模式）'}</div>
                {status.connection_mode && (
                  <div>连接模式: {status.connection_mode}</div>
                )}
              </>
            )}
            {status.matlab_root && (
              <div style={{ marginTop: '4px', color: '#999', maxWidth: '300px', wordBreak: 'break-all' }}>
                路径: {status.matlab_root}
              </div>
            )}
            {config?.detected_installations && config.detected_installations.length > 1 && (
              <div style={{ marginTop: '4px', color: '#999' }}>
                其他版本: {config.detected_installations
                  .filter(i => i.root !== config.matlab_root)
                  .map(i => extractVersion(i.root) || i.version)
                  .join(', ')}
              </div>
            )}
            {status.engine_error && (
              <div style={{ marginTop: '4px', color: '#f56c6c', maxWidth: '300px', wordBreak: 'break-all' }}>
                {String(status.engine_error).slice(0, 200)}
              </div>
            )}
            <div style={{ marginTop: '6px', color: '#999' }}>
              {isNotConfigured ? '点击配置 MATLAB 路径' : '点击刷新状态 | 右键配置'}
            </div>
          </div>
        }
      >
        <Tag
          size="small"
          variant="light-outline"
          icon={isReady ? <CheckCircleIcon size="14px" /> : <ErrorCircleIcon size="14px" />}
          style={{
            cursor: 'pointer',
            borderColor: isNotConfigured ? '#e6a23c' : (isReady ? '#67c23a' : '#f56c6c'),
            color: isNotConfigured ? '#e6a23c' : (isReady ? '#67c23a' : '#f56c6c'),
          } as React.CSSProperties}
          onClick={isNotConfigured ? openConfig : checkStatus}
          {...{onContextMenu: (e: React.MouseEvent) => { e.preventDefault(); openConfig(); }} as any}
        >
          {isNotConfigured ? '⚠ 未配置' : `${versionLabel} ${isReady ? '就绪' : '未就绪'}`}
        </Tag>
      </Tooltip>

      {/* MATLAB 配置对话框 */}
      <Dialog
        visible={showConfig}
        onClose={() => setShowConfig(false)}
        header="配置 MATLAB 安装路径"
        width={520}
        footer={null}
        closeOnOverlayClick
      >
        <div style={{ padding: '8px 0' }}>
          <p style={{ color: 'var(--td-text-color-secondary)', marginBottom: '16px', fontSize: '14px' }}>
            请输入 MATLAB 安装目录（包含 bin/matlab.exe 的目录）。<br/>
            例如: <code style={{ background: 'var(--td-bg-color-secondarycontainer)', padding: '2px 6px', borderRadius: '4px' }}>
              C:\Program Files\MATLAB\R2023b
            </code>
          </p>

          <Input
            value={configPath}
            onChange={(v) => setConfigPath(v as string)}
            placeholder="请输入 MATLAB 安装目录路径..."
            style={{ width: '100%' }}
          />

          {/* 检测到的安装列表 */}
          {config?.detected_installations && config.detected_installations.length > 0 && (
            <div style={{ marginTop: '16px' }}>
              <p style={{ fontSize: '13px', color: 'var(--td-text-color-secondary)', marginBottom: '8px' }}>
                检测到的 MATLAB 安装:
              </p>
              <div style={{ display: 'flex', flexDirection: 'column', gap: '6px' }}>
                {config.detected_installations.map((inst, idx) => (
                  <div
                    key={idx}
                    style={{
                      display: 'flex',
                      alignItems: 'center',
                      justifyContent: 'space-between',
                      padding: '8px 12px',
                      background: 'var(--td-bg-color-secondarycontainer)',
                      borderRadius: '6px',
                      cursor: 'pointer',
                      border: configPath === inst.root ? '1px solid var(--td-brand-color)' : '1px solid transparent',
                    }}
                    onClick={() => setConfigPath(inst.root)}
                  >
                    <div>
                      <span style={{ fontWeight: 500 }}>
                        {extractVersion(inst.root) || inst.version}
                      </span>
                      <span style={{ color: 'var(--td-text-color-placeholder)', marginLeft: '8px', fontSize: '12px' }}>
                        {inst.root}
                      </span>
                    </div>
                    {inst.exeExists && (
                      <Tag size="small" theme="success" variant="light">可用</Tag>
                    )}
                  </div>
                ))}
              </div>
            </div>
          )}

          <div style={{ display: 'flex', justifyContent: 'flex-end', gap: '8px', marginTop: '20px' }}>
            <Button variant="outline" onClick={() => setShowConfig(false)}>取消</Button>
            <Button theme="primary" loading={saving} onClick={handleSaveConfig}>
              保存并启动
            </Button>
          </div>
        </div>
      </Dialog>
    </>
  );
}
