# 一键 SSH 配置脚本 (Windows)
# 管理员 PowerShell 运行: irm https://raw.githubusercontent.com/Tiny-cyber/ssh-fix/main/fix-ssh.ps1 | iex
#
# 根因: Windows OpenSSH 的 sshd_config 末尾有一个 Match Group administrators 块,
# 会把管理员用户的 AuthorizedKeysFile 强制指向 C:\ProgramData\ssh\administrators_authorized_keys,
# 导致 ~/.ssh/authorized_keys 里的公钥被完全忽略. 大多数 Windows 用户都是管理员, 所以几乎人人中招.

$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host "   一键 SSH 配置 (Windows)" -ForegroundColor Cyan
Write-Host "=====================================" -ForegroundColor Cyan
Write-Host ""

# 检查是否以管理员权限运行
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "[错误] 请以管理员身份运行 PowerShell!" -ForegroundColor Red
    Write-Host "右键 PowerShell -> 以管理员身份运行" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

# ============================================================
# 第 1 步: 安装 OpenSSH Server
# ============================================================
Write-Host "[1/6] 检查 OpenSSH Server..." -ForegroundColor Yellow
try {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    if ($cap.State -ne "Installed") {
        Write-Host "  正在安装 OpenSSH Server (可能需要几分钟)..." -ForegroundColor Yellow
        $result = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
        if ($result.RestartNeeded) {
            Write-Host "  [警告] 安装完成, 但可能需要重启电脑后才能生效" -ForegroundColor Red
        } else {
            Write-Host "  已安装 OpenSSH Server" -ForegroundColor Green
        }
    } else {
        Write-Host "  OpenSSH Server 已安装" -ForegroundColor Green
    }
} catch {
    Write-Host "  [错误] 安装 OpenSSH Server 失败: $_" -ForegroundColor Red
    Write-Host "  尝试继续..." -ForegroundColor Yellow
}

# ============================================================
# 第 2 步: 修复 sshd_config
# ============================================================
Write-Host "[2/6] 修复 sshd_config..." -ForegroundColor Yellow
$configPath = "C:\ProgramData\ssh\sshd_config"
try {
    if (Test-Path $configPath) {
        # 备份原始配置
        $backupPath = "C:\ProgramData\ssh\sshd_config.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $configPath $backupPath -Force
        Write-Host "  已备份原配置到 $backupPath" -ForegroundColor Gray

        $config = Get-Content $configPath -Raw

        # 启用 PubkeyAuthentication
        if ($config -match "#\s*PubkeyAuthentication") {
            $config = $config -replace "#\s*PubkeyAuthentication\s+yes", "PubkeyAuthentication yes"
            Write-Host "  已启用 PubkeyAuthentication" -ForegroundColor Green
        } elseif ($config -notmatch "(?m)^PubkeyAuthentication\s+yes") {
            $config = "PubkeyAuthentication yes`r`n" + $config
            Write-Host "  已添加 PubkeyAuthentication yes" -ForegroundColor Green
        } else {
            Write-Host "  PubkeyAuthentication 已启用" -ForegroundColor Green
        }

        # [关键] 注释掉 Match Group administrators 块
        # 这是 Windows SSH 密钥认证失败的头号原因
        $matchChanged = $false
        if ($config -match "(?m)^Match\s+Group\s+administrators") {
            $config = $config -replace "(?m)^(Match\s+Group\s+administrators)", "# `$1 (commented out by ssh-fix)"
            $matchChanged = $true
        }
        if ($config -match "(?m)^\s+AuthorizedKeysFile\s+__PROGRAMDATA__") {
            $config = $config -replace "(?m)^(\s+AuthorizedKeysFile\s+__PROGRAMDATA__)", "# `$1 (commented out by ssh-fix)"
            $matchChanged = $true
        }
        if ($matchChanged) {
            Write-Host "  [关键] 已注释掉 Match Group administrators 覆盖块" -ForegroundColor Green
            Write-Host "         这是管理员用户 SSH 密钥认证失败的根本原因!" -ForegroundColor Cyan
        } else {
            Write-Host "  Match Group administrators 块已处理或不存在" -ForegroundColor Green
        }

        Set-Content -Path $configPath -Value $config -Force -NoNewline
        Write-Host "  配置已保存" -ForegroundColor Green
    } else {
        Write-Host "  sshd_config 尚不存在, 首次启动 sshd 后会自动创建" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  [错误] 修复 sshd_config 失败: $_" -ForegroundColor Red
}

# ============================================================
# 第 3 步: 从 GitHub 下载公钥并写入
# ============================================================
Write-Host "[3/6] 配置 SSH 公钥..." -ForegroundColor Yellow
$keysUrl = "https://raw.githubusercontent.com/Tiny-cyber/ssh-fix/main/keys.txt"
$pubKeys = $null

try {
    Write-Host "  正在从 GitHub 下载公钥..." -ForegroundColor Gray
    $pubKeys = (Invoke-WebRequest -Uri $keysUrl -UseBasicParsing -TimeoutSec 15).Content.Trim()
    Write-Host "  已下载公钥 ($((($pubKeys -split "`n").Count)) 个)" -ForegroundColor Green
} catch {
    Write-Host "  [警告] 无法从 GitHub 下载公钥: $_" -ForegroundColor Red
    Write-Host "  使用内置公钥..." -ForegroundColor Yellow
    $pubKeys = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmtCGpspbS4qb632U7cUlO0UJXqnZGJZMySVYtV1gPI tinypity@TinyPitydeMac-mini.local"
}

# 写入用户目录 ~/.ssh/authorized_keys
try {
    $sshDir = "$env:USERPROFILE\.ssh"
    $authKeys = "$sshDir\authorized_keys"
    if (-not (Test-Path $sshDir)) { mkdir $sshDir -Force | Out-Null }
    Set-Content -Path $authKeys -Value $pubKeys -Force
    Write-Host "  已写入 $authKeys" -ForegroundColor Green
} catch {
    Write-Host "  [错误] 写入用户 authorized_keys 失败: $_" -ForegroundColor Red
}

# 同时写入 ProgramData (管理员覆盖路径, 作为后备)
try {
    $adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
    $sshProgramData = "C:\ProgramData\ssh"
    if (-not (Test-Path $sshProgramData)) { mkdir $sshProgramData -Force | Out-Null }
    Set-Content -Path $adminKeys -Value $pubKeys -Force
    Write-Host "  已写入 $adminKeys (后备)" -ForegroundColor Green
} catch {
    Write-Host "  [错误] 写入 administrators_authorized_keys 失败: $_" -ForegroundColor Red
}

# ============================================================
# 第 4 步: 修复文件权限
# ============================================================
Write-Host "[4/6] 修复文件权限..." -ForegroundColor Yellow
try {
    # 用户 authorized_keys 权限
    if (Test-Path $authKeys) {
        icacls $authKeys /inheritance:r /grant "$($env:USERNAME):(F)" /grant "SYSTEM:(F)" | Out-Null
        Write-Host "  已设置 authorized_keys 权限" -ForegroundColor Green
    }
} catch {
    Write-Host "  [错误] 设置用户 authorized_keys 权限失败: $_" -ForegroundColor Red
}

try {
    # administrators_authorized_keys 权限 (只允许 SYSTEM 和 Administrators)
    if (Test-Path $adminKeys) {
        icacls $adminKeys /inheritance:r /grant "SYSTEM:(F)" /grant "Administrators:(F)" | Out-Null
        Write-Host "  已设置 administrators_authorized_keys 权限" -ForegroundColor Green
    }
} catch {
    Write-Host "  [错误] 设置 administrators_authorized_keys 权限失败: $_" -ForegroundColor Red
}

# ============================================================
# 第 5 步: 配置防火墙
# ============================================================
Write-Host "[5/6] 检查防火墙..." -ForegroundColor Yellow
try {
    $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $rule) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
        Write-Host "  已创建防火墙放行规则 (TCP 22)" -ForegroundColor Green
    } else {
        # 确保规则是启用状态
        if ($rule.Enabled -ne "True") {
            Enable-NetFirewallRule -Name "OpenSSH-Server-In-TCP"
            Write-Host "  已启用防火墙放行规则" -ForegroundColor Green
        } else {
            Write-Host "  防火墙规则已存在且已启用" -ForegroundColor Green
        }
    }
} catch {
    Write-Host "  [错误] 防火墙配置失败: $_" -ForegroundColor Red
}

# ============================================================
# 第 6 步: 重启 sshd 服务
# ============================================================
Write-Host "[6/6] 重启 sshd 服务..." -ForegroundColor Yellow
try {
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Start-Service sshd
    Set-Service -Name sshd -StartupType Automatic
    $sshdStatus = (Get-Service sshd).Status
    if ($sshdStatus -eq "Running") {
        Write-Host "  sshd 已启动, 已设置开机自启" -ForegroundColor Green
    } else {
        Write-Host "  [警告] sshd 状态: $sshdStatus" -ForegroundColor Red
    }
} catch {
    Write-Host "  [错误] 重启 sshd 失败: $_" -ForegroundColor Red
    Write-Host "  尝试手动启动: Start-Service sshd" -ForegroundColor Yellow
}

# ============================================================
# 输出连接信息
# ============================================================
Write-Host ""
Write-Host ""

# 获取 Tailscale IP
$tailscaleIP = $null
$tailscalePaths = @(
    "C:\Program Files\Tailscale\tailscale.exe",
    "C:\Program Files (x86)\Tailscale\tailscale.exe",
    "$env:LOCALAPPDATA\Tailscale\tailscale.exe"
)
foreach ($tsPath in $tailscalePaths) {
    if (Test-Path $tsPath) {
        try {
            $tailscaleIP = (& $tsPath ip -4 2>$null).Trim()
            if ($tailscaleIP) { break }
        } catch {}
    }
}
# 如果 CLI 没找到, 从网卡找 100.x.x.x
if (-not $tailscaleIP) {
    try {
        $tailscaleIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "100.*" } | Select-Object -First 1).IPAddress
    } catch {}
}

# 获取局域网 IP (排除 loopback、Tailscale、虚拟网卡)
$lanIP = $null
try {
    $lanIP = (Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object {
            $_.IPAddress -ne "127.0.0.1" -and
            $_.IPAddress -notlike "100.*" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.PrefixOrigin -ne "WellKnown"
        } |
        Sort-Object -Property InterfaceIndex |
        Select-Object -First 1).IPAddress
} catch {}

$hostname = $env:COMPUTERNAME
$username = $env:USERNAME

Write-Host "========================================" -ForegroundColor Green
Write-Host "         SSH 配置完成!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  主机名:      $hostname" -ForegroundColor White
Write-Host "  用户名:      $username" -ForegroundColor White
if ($tailscaleIP) {
    Write-Host "  Tailscale:   $tailscaleIP" -ForegroundColor White
    Write-Host "  连接命令:    ssh $username@$tailscaleIP" -ForegroundColor Cyan
} else {
    Write-Host "  Tailscale:   (未检测到)" -ForegroundColor Gray
}
if ($lanIP) {
    Write-Host "  局域网 IP:   $lanIP" -ForegroundColor White
    if (-not $tailscaleIP) {
        Write-Host "  连接命令:    ssh $username@$lanIP" -ForegroundColor Cyan
    }
} else {
    Write-Host "  局域网 IP:   (未检测到)" -ForegroundColor Gray
}
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " 请把以上信息截图发给对方即可" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
