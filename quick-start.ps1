# MATLAB Agent 快速启动脚本 (PowerShell)
# 用法: powershell -ExecutionPolicy Bypass -File quick-start.ps1

$ErrorActionPreference = "Continue"
$Host.UI.RawUI.WindowTitle = "MATLAB Agent Quick Start"

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MATLAB Agent - Quick Start (PowerShell)         ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# 检查端口是否已被占用
$portInUse = Get-NetTCPConnection -LocalPort 3000 -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Listen' }
if ($portInUse) {
    Write-Host "[!] 端口 3000 已被占用" -ForegroundColor Yellow
    try {
        $status = Invoke-RestMethod -Uri "http://localhost:3000/api/health" -TimeoutSec 3
        Write-Host "[✓] MATLAB Agent 已在运行" -ForegroundColor Green
        Write-Host "    预热状态: $($status.matlab.warmup)" -ForegroundColor Gray
        Write-Host "    就绪: $($status.matlab.ready)" -ForegroundColor Gray
    } catch {
        Write-Host "[?] 端口被占用但服务无响应" -ForegroundColor Yellow
    }
    Read-Host "按回车退出"
    exit 0
}

# 启动服务器
Write-Host "[*] 启动 MATLAB Agent 服务器..." -ForegroundColor White
$proc = Start-Process -FilePath "cmd.exe" -ArgumentList "/c npx tsx server/index.ts > server_startup.log 2>&1" -WindowStyle Hidden -PassThru

# 等待服务器启动
Write-Host "[*] 等待服务器启动..." -ForegroundColor White
$maxWait = 30
$waited = 0
$serverReady = $false

while ($waited -lt $maxWait) {
    Start-Sleep -Seconds 1
    $waited++
    try {
        $null = Invoke-RestMethod -Uri "http://localhost:3000/api/health" -TimeoutSec 2
        $serverReady = $true
        break
    } catch {
        Write-Host "    等待中... ($waited/${maxWait}s)" -ForegroundColor DarkGray
    }
}

if (-not $serverReady) {
    Write-Host "[!] 服务器启动超时 (${maxWait}s)" -ForegroundColor Red
    Write-Host "    请检查 server_startup.log" -ForegroundColor Yellow
    if (Test-Path "server_startup.log") { Get-Content "server_startup.log" -Tail 20 }
    Read-Host "按回车退出"
    exit 1
}

Write-Host "[✓] 服务器已启动 (${waited}s)" -ForegroundColor Green

# 等待 MATLAB Engine 预热
Write-Host "[*] 等待 MATLAB Engine 预热..." -ForegroundColor White
$maxWarmup = 120
$warmupWaited = 0

while ($warmupWaited -lt $maxWarmup) {
    Start-Sleep -Seconds 3
    $warmupWaited += 3
    
    try {
        $status = Invoke-RestMethod -Uri "http://localhost:3000/api/matlab/warmup-status" -TimeoutSec 3
        
        if ($status.ready) {
            Write-Host "[✓] MATLAB Engine 预热完成! (总计 ${warmupWaited}s)" -ForegroundColor Green
            break
        }
        
        if ($status.status -eq "failed") {
            Write-Host "[!] MATLAB Engine 预热失败: $($status.error)" -ForegroundColor Red
            Write-Host "    API 服务器仍然可用，但首次 MATLAB 操作会很慢" -ForegroundColor Yellow
            break
        }
        
        Write-Host "    预热中 [$($status.status)]... (${warmupWaited}/${maxWarmup}s)" -ForegroundColor DarkGray
    } catch {
        Write-Host "    检查状态失败... (${warmupWaited}/${maxWarmup}s)" -ForegroundColor DarkGray
    }
}

if ($warmupWaited -ge $maxWarmup) {
    Write-Host "[!] 预热超时 (${maxWarmup}s)" -ForegroundColor Yellow
    Write-Host "    API 服务器可用，MATLAB Engine 可能仍在启动中" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║   MATLAB Agent 已就绪!                            ║" -ForegroundColor Green
Write-Host "║                                                    ║" -ForegroundColor Green
Write-Host "║   API:    http://localhost:3000                    ║" -ForegroundColor Green
Write-Host "║   前端:   http://localhost:5173 (需另启动)         ║" -ForegroundColor Green
Write-Host "╚════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
Write-Host "服务器在后台运行 (PID: $($proc.Id))" -ForegroundColor Gray
Write-Host "关闭此窗口不会停止服务" -ForegroundColor Gray

Start-Sleep -Seconds 5
