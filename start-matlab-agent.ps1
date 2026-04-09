# start-matlab-agent.ps1
# MATLAB Agent 一键启动脚本 — 后台启动 + 轮询健康检查
# 用法: & "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app\start-matlab-agent.ps1"

$ErrorActionPreference = "Continue"
$SkillDir = "$env:USERPROFILE\.workbuddy\skills\matlab-agent\app"
$Port = 3000
$MaxWaitSeconds = 120
$PollInterval = 5

Write-Host "[MATLAB Agent] Starting..." -ForegroundColor Cyan

# 1. 检查端口是否已被占用
$existing = netstat -ano 2>$null | Select-String ":$Port" | Select-String "LISTENING"
if ($existing) {
    $pidMatch = [regex]::Match($existing.ToString(), '\s+(\d+)\s*$')
    if ($pidMatch.Success) {
        $oldPid = $pidMatch.Groups[1].Value
        Write-Host "[MATLAB Agent] Port $Port already in use by PID $oldPid, killing..." -ForegroundColor Yellow
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# 2. 确保 node_modules 存在
if (-not (Test-Path "$SkillDir\node_modules")) {
    Write-Host "[MATLAB Agent] Installing dependencies..." -ForegroundColor Yellow
    Push-Location $SkillDir
    npm install --production 2>&1 | ForEach-Object { Write-Host $_ }
    Pop-Location
}

# 3. 后台启动服务器
Write-Host "[MATLAB Agent] Launching server in background..." -ForegroundColor Cyan
Push-Location $SkillDir
$logFile = "$env:TEMP\matlab-agent-out.log"
cmd /c "start /B npx tsx server/index.ts > `"$logFile`" 2>&1"
Pop-Location

# 4. 轮询健康检查
$elapsed = 0
$serverUp = $false
$engineReady = $false
$matlabNotConfigured = $false

while ($elapsed -lt $MaxWaitSeconds) {
    Start-Sleep -Seconds $PollInterval
    $elapsed += $PollInterval

    try {
        $r = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 5
        $j = $r.Content | ConvertFrom-Json
        $serverUp = $true

        # warmup 字段在 matlab 子对象下
        $warmupStatus = $j.matlab.warmup
        $isReady = $j.matlab.ready
        $matlabRoot = $j.matlab.root

        # 检查 MATLAB 是否已配置
        if (-not $matlabRoot) {
            $matlabNotConfigured = $true
            Write-Host "[MATLAB Agent] ⚠️ MATLAB 未配置！服务器已启动，但需要设置 MATLAB 安装路径。" -ForegroundColor Yellow
            break
        }

        if ($isReady -eq $true -or $warmupStatus -eq "ready") {
            Write-Host "[MATLAB Agent] ✅ Ready! (took ${elapsed}s) — root: $matlabRoot" -ForegroundColor Green
            $engineReady = $true
            break
        }

        Write-Host "[MATLAB Agent] Warmup: $warmupStatus (${elapsed}s / ${MaxWaitSeconds}s)" -ForegroundColor Yellow
    }
    catch {
        if (-not $serverUp) {
            Write-Host "[MATLAB Agent] Waiting for server... (${elapsed}s / ${MaxWaitSeconds}s)" -ForegroundColor DarkGray
        }
        else {
            Write-Host "[MATLAB Agent] Health check error: $_" -ForegroundColor Red
        }
    }
}

# 5. 如果 MATLAB 未配置，交互式引导用户输入路径
if ($matlabNotConfigured) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║  🔧 首次使用：请配置 MATLAB 安装路径                     ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  MATLAB 安装路径示例：" -ForegroundColor Cyan
    Write-Host "    D:\Program Files\MATLAB\R2023b" -ForegroundColor White
    Write-Host "    D:\Program Files(x86)\MATLAB 2016a" -ForegroundColor White
    Write-Host "    C:\Program Files\MATLAB\R2024a" -ForegroundColor White
    Write-Host ""

    $maxRetries = 3
    $retryCount = 0
    $configured = $false

    while ($retryCount -lt $maxRetries -and -not $configured) {
        $matlabPath = Read-Host "  请输入 MATLAB 安装路径（或输入 q 退出）"

        if ($matlabPath -eq 'q' -or $matlabPath -eq 'Q') {
            Write-Host "[MATLAB Agent] 已退出配置。服务器仍在运行，可稍后通过 API 配置。" -ForegroundColor Yellow
            break
        }

        if (-not $matlabPath) {
            $retryCount++
            Write-Host "  ❌ 路径不能为空" -ForegroundColor Red
            continue
        }

        # 验证路径
        $exePath = Join-Path $matlabPath "bin\matlab.exe"
        if (-not (Test-Path $exePath)) {
            $retryCount++
            Write-Host "  ❌ 未找到 matlab.exe: $exePath" -ForegroundColor Red
            Write-Host "  请确认路径正确（应指向 MATLAB 根目录，包含 bin\matlab.exe）" -ForegroundColor DarkGray
            continue
        }

        # 通过 API 设置
        try {
            $body = @{ matlabRoot = $matlabPath } | ConvertTo-Json -Compress
            $result = Invoke-RestMethod -Uri "http://localhost:$Port/api/matlab/config" -Method Post -ContentType "application/json" -Body ([System.Text.Encoding]::UTF8.GetBytes($body))
            if ($result.success) {
                Write-Host "  ✅ $($result.message)" -ForegroundColor Green
                $configured = $true
            } else {
                $retryCount++
                Write-Host "  ❌ $($result.message)" -ForegroundColor Red
            }
        }
        catch {
            $retryCount++
            Write-Host "  ❌ API 调用失败: $_" -ForegroundColor Red
        }
    }

    if (-not $configured -and $matlabPath -ne 'q' -and $matlabPath -ne 'Q') {
        Write-Host ""
        Write-Host "  ⚠️ 配置失败。服务器仍在运行，可稍后通过以下方式配置：" -ForegroundColor Yellow
        Write-Host "    API: curl -X POST http://localhost:$Port/api/matlab/config -H `"Content-Type: application/json`" -d '{`"matlabRoot`":`"D:\\Program Files\\MATLAB\\R2023b`"}'" -ForegroundColor DarkGray
    }

    if ($configured) {
        Write-Host ""
        Write-Host "[MATLAB Agent] MATLAB 已配置，等待 Engine 预热..." -ForegroundColor Cyan
        # 等待 Engine 预热
        $warmElapsed = 0
        $warmMax = 90
        while ($warmElapsed -lt $warmMax) {
            Start-Sleep -Seconds 5
            $warmElapsed += 5
            try {
                $wr = Invoke-WebRequest -Uri "http://localhost:$Port/api/health" -UseBasicParsing -TimeoutSec 5
                $wj = $wr.Content | ConvertFrom-Json
                if ($wj.matlab.ready -eq $true) {
                    Write-Host "[MATLAB Agent] ✅ MATLAB Engine 预热完成！(${warmElapsed}s)" -ForegroundColor Green
                    $engineReady = $true
                    break
                }
                Write-Host "[MATLAB Agent] Warmup: $($wj.matlab.warmup) (${warmElapsed}s / ${warmMax}s)" -ForegroundColor Yellow
            }
            catch {
                Write-Host "[MATLAB Agent] Health check error..." -ForegroundColor DarkGray
            }
        }
        if (-not $engineReady) {
            Write-Host "[MATLAB Agent] ⚠️ Engine 预热超时，但配置已保存，服务可用" -ForegroundColor Yellow
        }
    }
}

if (-not $engineReady -and -not $matlabNotConfigured) {
    Write-Host "[MATLAB Agent] ⚠️ Warmup timeout after ${MaxWaitSeconds}s, but server is running and functional." -ForegroundColor Yellow
    Write-Host "[MATLAB Agent] MATLAB Engine may still be starting in the background." -ForegroundColor Yellow
    Write-Host "[MATLAB Agent] Check log: $logFile" -ForegroundColor DarkGray
    Write-Host "[MATLAB Agent] Status: Invoke-WebRequest http://localhost:$Port/api/health" -ForegroundColor DarkGray
    # 不 exit 1 — 预热超时不影响服务器正常功能，功能请求会触发延迟初始化
}

# 5. 输出连接信息
Write-Host ""
Write-Host "[MATLAB Agent] Server: http://localhost:$Port" -ForegroundColor Cyan
Write-Host "[MATLAB Agent] Health:  http://localhost:$Port/api/health" -ForegroundColor Cyan
Write-Host "[MATLAB Agent] Config:  http://localhost:$Port/api/matlab/config" -ForegroundColor Cyan
Write-Host "[MATLAB Agent] Log:     $logFile" -ForegroundColor DarkGray
exit 0
