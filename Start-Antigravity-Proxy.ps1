 ============================================================
#  Antigravity 代理启动器（检测 -> 确认 -> 启动 -> 验证）
#  环境变量只作用于本进程及其子进程，不影响 WorkBuddy 等其它程序
#  参数:
#    -Port 4088              手工指定代理端口（默认自动探测）
#    -Yes                    跳过确认，直接启动
#    -AppPath "路径\exe"     手工指定 Antigravity 位置（默认自动查找）
#  可移植：不绑定安装路径、不绑定端口，换电脑只需复制 cmd + ps1 两个文件
# ============================================================
param(
    [int]$Port = 0,
    [switch]$Yes,
    [string]$AppPath = ''
)

$ErrorActionPreference = 'SilentlyContinue'
$DryRun = ($env:AG_LAUNCH_DRYRUN -eq '1')

function Show-Line { Write-Host ('-' * 58) -ForegroundColor DarkGray }
function Stop-WithError {
    param([string]$Msg, [string]$Hint)
    Write-Host ''
    Write-Host "  FAIL  $Msg" -ForegroundColor Red
    if ($Hint) { Write-Host "        $Hint" -ForegroundColor DarkGray }
    Write-Host ''
    exit 1
}

# ---------- 查找 Antigravity 安装位置 ----------
function Find-App {
    param([string]$Hint)
    if ($Hint -and (Test-Path $Hint)) { return (Resolve-Path $Hint).Path }

    # 1) 正在运行的实例
    $run = Get-Process Antigravity -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($run -and $run.Path -and (Test-Path $run.Path)) { return $run.Path }

    # 2) 常见安装位置
    $cands = @(
        'D:\Antigravity\Antigravity.exe',
        'C:\Antigravity\Antigravity.exe',
        "$env:LOCALAPPDATA\Programs\Antigravity\Antigravity.exe",
        "$env:LOCALAPPDATA\Antigravity\Antigravity.exe",
        "$env:ProgramFiles\Antigravity\Antigravity.exe",
        "${env:ProgramFiles(x86)}\Antigravity\Antigravity.exe"
    )
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }

    # 3) 注册表卸载信息
    $roots = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($r in $roots) {
        $items = Get-ItemProperty $r -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'Antigravity' }
        foreach ($it in $items) {
            foreach ($p in @($it.InstallLocation, $it.DisplayIcon)) {
                if (-not $p) { continue }
                $p = $p.Trim('"').Trim()
                if (Test-Path $p -PathType Leaf) { return $p }
                if ($p) {
                    $try = Join-Path $p 'Antigravity.exe'
                    if (Test-Path $try) { return $try }
                }
            }
        }
    }

    # 4) 各盘根目录浅扫
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not $d.Root) { continue }
        $try = Join-Path $d.Root 'Antigravity\Antigravity.exe'
        if (Test-Path $try) { return $try }
    }
    return $null
}

Write-Host ' '
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host '        Antigravity 代理启动器' -ForegroundColor Cyan
Write-Host '  ============================================' -ForegroundColor Cyan
Write-Host ' '

# ---------- 0. 前置检查 ----------
$AppPath = Find-App -Hint $AppPath
if (-not $AppPath) {
    Stop-WithError '找不到 Antigravity.exe' '请用 -AppPath "完整路径\Antigravity.exe" 指定位置'
}
Write-Host "  程序: $AppPath" -ForegroundColor DarkGray
Write-Host ' '

# ---------- 1. 端口探测 ----------
$PortSource = ''
if ($Port -gt 0) {
    $PortSource = '命令行参数'
} else {
    $ie0 = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($ie0.ProxyEnable -eq 1 -and $ie0.ProxyServer -match '(?:127\.0\.0\.1|localhost):(\d+)') {
        $cand = [int]$Matches[1]
        if (Get-NetTCPConnection -LocalPort $cand -State Listen -ErrorAction SilentlyContinue) {
            $Port = $cand
            $PortSource = '系统代理设置'
        }
    }
}
if ($Port -le 0) {
    $known = 'rivo|mihomo|clash|verge|v2ray|xray|sing-box|nekoray|shadowsocks|trojan'
    foreach ($c in (Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
                    Where-Object { $_.LocalAddress -eq '0.0.0.0' -or $_.LocalAddress -eq '127.0.0.1' })) {
        $n = (Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue).ProcessName
        if ($n -and $n -match $known) { $Port = $c.LocalPort; $PortSource = "自动探测（$n）"; break }
    }
}
if ($Port -le 0) { $Port = 4088; $PortSource = '默认值' }
$ProxyUrl = "http://127.0.0.1:$Port"

Write-Host "[1/4] 检查代理客户端 ..." -ForegroundColor White
$listen = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if (-not $listen) {
    Stop-WithError "本地端口 $Port 没有监听，代理客户端没启动" "请先启动 rivo（或用其它客户端），然后重新运行本启动器"
}
$ownPid  = ($listen | Select-Object -First 1).OwningProcess
$ownName = (Get-Process -Id $ownPid -ErrorAction SilentlyContinue).ProcessName
Write-Host "      OK  端口 $Port 正在监听（$ownName，PID $ownPid）" -ForegroundColor Green
Write-Host "           端口来源: $PortSource" -ForegroundColor DarkGray

# ---------- 2. 出口检测 ----------
Write-Host '[2/4] 检查出口节点 ...' -ForegroundColor White
$egress = $null
if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
    foreach ($t in @(8, 15)) {
        $raw = & curl.exe -s -x $ProxyUrl --max-time $t 'https://ipinfo.io/json' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try { $egress = $raw | ConvertFrom-Json; break } catch { }
        }
    }
}
if ($null -eq $egress) {
    Stop-WithError '通过代理连不上外网，节点可能不可用' '检查客户端里是否选中了可用的线路，然后重试'
}
$loc = @($egress.city, $egress.country) | Where-Object { $_ }
Write-Host "      OK  出口 $($egress.ip)  ($($loc -join ', '))  $($egress.org)" -ForegroundColor Green

# ---------- 3. 检查是否已在运行 ----------
Write-Host '[3/4] 检查 Antigravity 状态 ...' -ForegroundColor White
$agAll     = @(Get-Process Antigravity -ErrorAction SilentlyContinue)
$agWin     = @($agAll | Where-Object { $_.MainWindowHandle -ne 0 })
$lsAlive   = @(Get-Process language_server -ErrorAction SilentlyContinue)
$isRunning = ($agWin.Count -gt 0) -or ($lsAlive.Count -gt 0)
$needRestart = $false
if ($isRunning) {
    $proxied = 0
    foreach ($p in $lsAlive) {
        $cs = Get-NetTCPConnection -OwningProcess $p.Id -State Established -ErrorAction SilentlyContinue
        $proxied += @($cs | Where-Object { $_.RemotePort -eq $Port -and $_.RemoteAddress -match '^(127\.|::1)' }).Count
    }
    if ($proxied -gt 0) {
        Write-Host "      OK  已在运行，且正在走代理（$proxied 条连接）" -ForegroundColor Green
        Write-Host '           无需重复启动。要重新启动请先手动退出 Antigravity。' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
    Write-Host '      注意 已经在运行，但没有走代理' -ForegroundColor Yellow
    Write-Host '           重复启动只会激活旧实例，代理不会生效。' -ForegroundColor DarkGray
    $needRestart = $true
} else {
    Write-Host '      OK  当前未运行' -ForegroundColor Green
    if ($agAll.Count -gt 0) {
        Write-Host "           检测到 $($agAll.Count) 个无窗口的后台进程（sidecar），不影响启动" -ForegroundColor DarkGray
    }
}

# ---------- 4. 确认 ----------
Write-Host '[4/4] 准备启动 ...' -ForegroundColor White
Write-Host "      代理地址: $ProxyUrl" -ForegroundColor White
Write-Host '           环境变量仅注入本次进程，其它程序不受影响' -ForegroundColor DarkGray
Write-Host ''

$answer = 'y'
if ($needRestart) {
    Write-Host '  需要先关闭当前实例。关闭前请确认已保存工作。' -ForegroundColor Yellow
    if (-not $DryRun -and -not $Yes) {
        $answer = Read-Host '  现在自动关闭并重启 Antigravity？(Y/N)'
        if ($answer -notmatch '^[Yy]') {
            Write-Host '  已取消，未做任何修改。' -ForegroundColor DarkGray
            Write-Host ''
            exit 0
        }
    }
    Write-Host '  正在关闭旧实例 ...' -ForegroundColor DarkGray
    if (-not $DryRun) {
        $agWin | ForEach-Object { $_.CloseMainWindow() | Out-Null }
        $deadline = (Get-Date).AddSeconds(15)
        while ((@(Get-Process Antigravity -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (@(Get-Process Antigravity -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count -gt 0) {
            if ($Yes) {
                Get-Process Antigravity -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false
            } else {
                $k = Read-Host '  旧实例没有响应关闭，强制结束？(Y/N)'
                if ($k -notmatch '^[Yy]') {
                    Write-Host '  已取消，未做任何修改。' -ForegroundColor DarkGray
                    Write-Host ''
                    exit 1
                }
                Get-Process Antigravity -ErrorAction SilentlyContinue | Stop-Process -Force -Confirm:$false
            }
        }
        Start-Sleep -Seconds 1
    }
} elseif (-not $DryRun -and -not $Yes) {
    $answer = Read-Host '  按 Y 回车启动，直接回车取消'
    if ($answer -notmatch '^[Yy]') {
        Write-Host '  已取消。' -ForegroundColor DarkGray
        Write-Host ''
        exit 0
    }
}

if ($DryRun) {
    Write-Host '  [DRY RUN] 检测全部通过，此处会启动 Antigravity（本次未实际启动）' -ForegroundColor Magenta
    Write-Host ''
    exit 0
}

# ---------- 启动 ----------
# 兜底：清除可能干扰 Electron 的变量（某些环境会设置它，导致应用静默退出）
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
$env:HTTP_PROXY  = $ProxyUrl
$env:HTTPS_PROXY = $ProxyUrl
$env:NO_PROXY    = '127.0.0.1,localhost,::1'

Write-Host '  正在启动 ...' -ForegroundColor DarkGray
$proc = Start-Process -FilePath $AppPath -ArgumentList '--remote-debugging-port=0' -WorkingDirectory (Split-Path $AppPath) -PassThru
Start-Sleep -Seconds 2
if ($proc.HasExited) {
    Stop-WithError "Antigravity 启动后立即退出（退出码 $($proc.ExitCode)）" "查看日志: $env:APPDATA\Antigravity\logs\main.log"
}
Write-Host "      OK  已启动（PID $($proc.Id)）" -ForegroundColor Green

# ---------- 启动后验证 ----------
Write-Host '  正在验证代理是否生效 ...' -ForegroundColor DarkGray
$ok  = $false
$cnt = 0
for ($i = 0; $i -lt 25; $i++) {
    Start-Sleep -Seconds 1
    $lsP = Get-Process language_server -ErrorAction SilentlyContinue
    if (-not $lsP) { continue }
    foreach ($p in $lsP) {
        $cs = Get-NetTCPConnection -OwningProcess $p.Id -State Established -ErrorAction SilentlyContinue
        $c = @($cs | Where-Object { $_.RemotePort -eq $Port -and $_.RemoteAddress -match '^(127\.|::1)' }).Count
        if ($c -gt 0) { $ok = $true; $cnt = $c; break }
    }
    if ($ok) { break }
}

Show-Line
if ($ok) {
    Write-Host "  OK    language_server 已连上代理（$cnt 条连接）" -ForegroundColor Green
    Write-Host "        出口: $($egress.ip)  ($($loc -join ', '))" -ForegroundColor Green
    Write-Host '        可以正常使用了，本窗口 3 秒后自动关闭' -ForegroundColor DarkGray
    Write-Host ''
    Start-Sleep -Seconds 3
    exit 0
} else {
    Write-Host '  注意  启动成功，但还没检测到 language_server 的代理连接' -ForegroundColor Yellow
    Write-Host '        可能仍在初始化。请在 Antigravity 里发一条消息，然后运行 check-node.cmd 复查。' -ForegroundColor DarkGray
    Write-Host ''
    Read-Host '  按回车关闭'
    exit 1
}
