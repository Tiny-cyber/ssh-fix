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
# 第 1 步: 安装 OpenSSH Server (三重保险, 带超时)
# ============================================================
Write-Host "[1/6] 检查 OpenSSH Server..." -ForegroundColor Yellow

$sshdInstalled = $false
$installTimeout = 60

# 先检查 sshd 服务是否已存在 (可能已预装或上次部分安装成功)
$existingSshd = Get-Service sshd -ErrorAction SilentlyContinue
if ($existingSshd) {
    Write-Host "  OpenSSH Server 已安装 (服务状态: $($existingSshd.Status))" -ForegroundColor Green
    $sshdInstalled = $true
}

# 方法 A: 本地离线安装 (不走网络, Win10 1809+/Win11 组件商店通常自带)
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 A (本地离线安装, 不走网络)..." -ForegroundColor Yellow
    try {
        $result = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -LimitAccess -ErrorAction Stop
        if ($result.RestartNeeded) {
            Write-Host "  [警告] 安装完成, 但可能需要重启电脑后才能生效" -ForegroundColor Red
        } else {
            Write-Host "  已从本地组件商店安装 OpenSSH Server" -ForegroundColor Green
        }
        $sshdInstalled = $true
    } catch {
        Write-Host "  方法 A (本地离线) 失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 方法 A2: DISM 本地离线安装
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 A2 (DISM 本地离线)..." -ForegroundColor Yellow
    try {
        $dismOutput = & dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /LimitAccess 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  DISM 本地离线安装成功" -ForegroundColor Green
            $sshdInstalled = $true
        } else {
            Write-Host "  DISM 本地离线失败 (exit $LASTEXITCODE)" -ForegroundColor Red
        }
    } catch {
        Write-Host "  DISM 本地离线失败: $_" -ForegroundColor Red
    }
}

# 方法 B: Get-WindowsCapability 联网安装 (60秒超时)
if (-not $sshdInstalled) {
    try {
        $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 2>$null
        if ($cap -and $cap.State -eq "Installed") {
            Write-Host "  OpenSSH Server 已安装" -ForegroundColor Green
            $sshdInstalled = $true
        } elseif ($cap) {
            Write-Host "  尝试方法 B (联网安装, ${installTimeout}秒超时)..." -ForegroundColor Yellow
            $job = Start-Job -ScriptBlock {
                Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
            }
            $finished = $job | Wait-Job -Timeout $installTimeout
            if ($finished) {
                $result = Receive-Job $job -ErrorAction Stop
                Remove-Job $job -Force
                if ($result.RestartNeeded) {
                    Write-Host "  [警告] 安装完成, 但可能需要重启电脑后才能生效" -ForegroundColor Red
                } else {
                    Write-Host "  已安装 OpenSSH Server" -ForegroundColor Green
                }
                $sshdInstalled = $true
            } else {
                Write-Host "  方法 B 超时 (${installTimeout}秒), 跳过..." -ForegroundColor Red
                Stop-Job $job -ErrorAction SilentlyContinue
                Remove-Job $job -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Host "  方法 B (联网安装) 失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 方法 B2: DISM 联网安装 (60秒超时)
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 B2 (DISM 联网, ${installTimeout}秒超时)..." -ForegroundColor Yellow
    try {
        $job = Start-Job -ScriptBlock {
            & dism /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 2>&1
            $LASTEXITCODE
        }
        $finished = $job | Wait-Job -Timeout $installTimeout
        if ($finished) {
            $output = Receive-Job $job
            Remove-Job $job -Force
            $exitCode = $output[-1]
            if ($exitCode -eq 0) {
                Write-Host "  DISM 联网安装成功" -ForegroundColor Green
                $sshdInstalled = $true
            } else {
                Write-Host "  DISM 联网失败 (exit $exitCode)" -ForegroundColor Red
            }
        } else {
            Write-Host "  方法 B2 超时 (${installTimeout}秒), 跳过..." -ForegroundColor Red
            Stop-Job $job -ErrorAction SilentlyContinue
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host "  DISM 联网失败: $_" -ForegroundColor Red
    }
}

# 方法 C: 从 GitHub 下载 Win32-OpenSSH 手动安装
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 C (GitHub 下载 Win32-OpenSSH)..." -ForegroundColor Yellow
    try {
        # 强制 TLS 1.2 + 跳过证书验证 (公司网络中间人代理常导致证书错误)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
        try {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        } catch {}

        $arch = if ([Environment]::Is64BitOperatingSystem) { "Win64" } else { "Win32" }
        $zipPath = "$env:TEMP\OpenSSH-Download.zip"
        $extractPath = "$env:TEMP\OpenSSH-Extract"
        $installPath = "C:\Program Files\OpenSSH"
        $downloaded = $false

        # 先尝试直接用已知 URL 下载 (跳过 API 查询, 减少一次网络请求)
        $directUrls = @(
            "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-${arch}.zip",
            "https://objects.githubusercontent.com/github-production-release-asset-2e65be/49609581/OpenSSH-${arch}.zip"
        )
        foreach ($url in $directUrls) {
            if ($downloaded) { break }
            try {
                Write-Host "  正在下载 OpenSSH-${arch}.zip..." -ForegroundColor Gray
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add("User-Agent", "PowerShell")
                $wc.DownloadFile($url, $zipPath)
                if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 100000) {
                    $downloaded = $true
                }
            } catch {
                Write-Host "  直接下载失败, 尝试其他方式..." -ForegroundColor Gray
            }
        }

        # 回退: 通过 API 查询最新版本再下载
        if (-not $downloaded) {
            $releasesUrl = "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest"
            Write-Host "  正在通过 API 查询最新版本..." -ForegroundColor Gray
            $release = Invoke-RestMethod -Uri $releasesUrl -TimeoutSec 30
            $asset = $release.assets | Where-Object { $_.name -like "OpenSSH-${arch}*.zip" -and $_.name -notlike "*debug*" } | Select-Object -First 1
            if (-not $asset) { throw "找不到匹配 $arch 的下载文件" }
            $zipUrl = $asset.browser_download_url
            Write-Host "  正在下载 $($asset.name)..." -ForegroundColor Gray
            Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
        }

        # 清理旧的解压目录
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }

        Write-Host "  正在解压..." -ForegroundColor Gray
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        # 找到解压后的目录 (通常是 OpenSSH-Win64 或 OpenSSH-Win32)
        $sshFolder = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
        if (-not $sshFolder) { throw "解压后找不到 OpenSSH 文件夹" }

        # 如果已有旧安装, 先停服务
        Stop-Service sshd -Force -ErrorAction SilentlyContinue

        # 复制到安装目录
        if (Test-Path $installPath) { Remove-Item $installPath -Recurse -Force }
        Copy-Item -Path $sshFolder.FullName -Destination $installPath -Recurse -Force

        # 运行安装脚本
        $installScript = Join-Path $installPath "install-sshd.ps1"
        if (Test-Path $installScript) {
            Write-Host "  正在注册 sshd 服务..." -ForegroundColor Gray
            & powershell.exe -ExecutionPolicy Bypass -File $installScript
            if ($LASTEXITCODE -eq 0 -or (Get-Service sshd -ErrorAction SilentlyContinue)) {
                Write-Host "  Win32-OpenSSH 安装成功" -ForegroundColor Green
                $sshdInstalled = $true
            } else {
                Write-Host "  install-sshd.ps1 执行失败" -ForegroundColor Red
            }
        } else {
            throw "找不到 install-sshd.ps1"
        }

        # 把安装目录加入 PATH
        $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
        if ($machinePath -notlike "*$installPath*") {
            [Environment]::SetEnvironmentVariable("Path", "$machinePath;$installPath", "Machine")
            $env:Path = "$env:Path;$installPath"
            Write-Host "  已添加到系统 PATH" -ForegroundColor Green
        }

        # 清理临时文件
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    } catch {
        Write-Host "  方法 C 失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 最终检查 sshd 服务是否存在
$sshdService = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshdService) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  [失败] OpenSSH Server 三种方法都装不上" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  可能原因:" -ForegroundColor Yellow
    Write-Host "    1. Windows 版本太旧 (需要 Win10 1809+ 或 Server 2019+)" -ForegroundColor Yellow
    Write-Host "    2. Windows Update 服务被禁用" -ForegroundColor Yellow
    Write-Host "    3. 网络无法连接 GitHub" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  当前 Windows 版本:" -ForegroundColor Gray
    Write-Host "  $([Environment]::OSVersion.VersionString)" -ForegroundColor White
    Write-Host "  $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)" -ForegroundColor White
    Write-Host ""
    Write-Host "  请把以上信息截图发回" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

# ============================================================
# 第 2 步: 修复 sshd_config
# ============================================================
Write-Host "[2/6] 修复 sshd_config..." -ForegroundColor Yellow

# 确保 C:\ProgramData\ssh 目录存在, 先启动一次 sshd 让它生成默认配置
$configPath = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $configPath)) {
    Write-Host "  sshd_config 不存在, 先启动 sshd 生成默认配置..." -ForegroundColor Gray
    Start-Service sshd -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
}

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
        Write-Host "  [警告] sshd_config 仍不存在, 跳过配置修复" -ForegroundColor Red
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
$authKeys = "$env:USERPROFILE\.ssh\authorized_keys"
try {
    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) { mkdir $sshDir -Force | Out-Null }
    Set-Content -Path $authKeys -Value $pubKeys -Force
    Write-Host "  已写入 $authKeys" -ForegroundColor Green
} catch {
    Write-Host "  [错误] 写入用户 authorized_keys 失败: $_" -ForegroundColor Red
}

# 同时写入 ProgramData (管理员覆盖路径, 作为后备)
$adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
try {
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
    Start-Service sshd -ErrorAction Stop
    Set-Service -Name sshd -StartupType Automatic
    $sshdStatus = (Get-Service sshd).Status
    if ($sshdStatus -eq "Running") {
        Write-Host "  sshd 已启动, 已设置开机自启" -ForegroundColor Green
    } else {
        Write-Host "  [警告] sshd 状态: $sshdStatus" -ForegroundColor Red
    }
} catch {
    Write-Host "  [错误] 启动 sshd 失败: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  [失败] sshd 服务无法启动" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  请把以上信息截图发回" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
}

# ============================================================
# 最终验证: 确认 sshd 真的在跑
# ============================================================
$finalCheck = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $finalCheck -or $finalCheck.Status -ne "Running") {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  [失败] sshd 没有在运行!" -ForegroundColor Red
    Write-Host "  状态: $(if ($finalCheck) { $finalCheck.Status } else { '服务不存在' })" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  请把以上信息截图发回" -ForegroundColor Yellow
    Write-Host ""
    pause
    exit 1
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
