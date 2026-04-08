import { useState, useEffect } from 'react';
import { Tag, Tooltip } from 'tdesign-react';
import { CheckCircleIcon, ErrorCircleIcon, LoadingIcon } from 'tdesign-icons-react';

interface MATLABStatus {
  status: 'ok' | 'warning' | 'error';
  matlab_root_exists: boolean;
  matlab_exe_exists: boolean;
  bridge_script_exists: boolean;
  engine_importable?: boolean;
}

export function MATLABStatusBar() {
  const [status, setStatus] = useState<MATLABStatus | null>(null);
  const [checking, setChecking] = useState(true);

  useEffect(() => {
    checkStatus();
  }, []);

  const checkStatus = async () => {
    setChecking(true);
    try {
      const res = await fetch('/api/matlab/status');
      const data = await res.json();
      setStatus(data);
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
  
  return (
    <Tooltip
      content={
        <div style={{ fontSize: '12px', lineHeight: '1.6' }}>
          <div>MATLAB R2023b: {status.matlab_root_exists ? '✓ 已找到' : '✗ 未找到'}</div>
          <div>matlab.exe: {status.matlab_exe_exists ? '✓ 正常' : '✗ 缺失'}</div>
          <div>Python 桥接: {status.bridge_script_exists ? '✓ 已部署' : '✗ 缺失'}</div>
          <div>Engine API: {status.engine_importable ? '✓ 可用' : '✗ 未安装'}</div>
          {status.engine_error && (
            <div style={{ marginTop: '4px', color: '#f56c6c', maxWidth: '300px', wordBreak: 'break-all' }}>
              {String(status.engine_error).slice(0, 200)}
            </div>
          )}
          <div style={{ marginTop: '6px', color: '#999' }}>点击刷新状态</div>
        </div>
      }
    >
      <Tag
        size="small"
        variant="light-outline"
        icon={isReady ? <CheckCircleIcon size="14px" /> : <ErrorCircleIcon size="14px" />}
        style={{
          cursor: 'pointer',
          borderColor: isReady ? '#67c23a' : '#f56c6c',
          color: isReady ? '#67c23a' : '#f56c6c',
        }}
        onClick={checkStatus}
      >
        MATLAB {isReady ? 'R2023b 就绪' : '未就绪'}
      </Tag>
    </Tooltip>
  );
}
