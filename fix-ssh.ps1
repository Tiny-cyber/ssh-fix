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
# 策略: 绕开 Windows Servicing Stack (Add-WindowsCapability/DISM),
#        公司电脑上十台有八台卡在那个蓝色进度条 "Operation Running"
# ============================================================
Write-Host "[1/6] 检查 OpenSSH Server..." -ForegroundColor Yellow

$sshdInstalled = $false

# --- 检查 1: sshd 服务是否已存在 ---
$existingSshd = Get-Service sshd -ErrorAction SilentlyContinue
if ($existingSshd) {
    Write-Host "  sshd 服务已存在 (状态: $($existingSshd.Status))" -ForegroundColor Green
    $sshdInstalled = $true
}

# --- 检查 2: sshd.exe 是否已在磁盘上 (Win10/11 常有但没注册服务) ---
if (-not $sshdInstalled) {
    Write-Host "  搜索磁盘上的 sshd.exe..." -ForegroundColor Gray
    $searchPaths = @(
        "C:\Windows\System32\OpenSSH\sshd.exe",
        "C:\Program Files\OpenSSH\sshd.exe",
        "C:\Program Files\OpenSSH-Win64\sshd.exe",
        "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    )
    $sshdExe = $null
    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            $sshdExe = $p
            break
        }
    }
    if ($sshdExe) {
        Write-Host "  找到 sshd.exe: $sshdExe" -ForegroundColor Green
        $sshdDir = Split-Path $sshdExe -Parent
        $installScript = Join-Path $sshdDir "install-sshd.ps1"
        if (Test-Path $installScript) {
            Write-Host "  正在注册 sshd 服务..." -ForegroundColor Gray
            & powershell.exe -ExecutionPolicy Bypass -File $installScript 2>&1 | Out-Null
        } else {
            # 手动注册服务
            Write-Host "  手动注册 sshd 服务..." -ForegroundColor Gray
            & sc.exe create sshd binPath="$sshdExe" start=auto DisplayName="OpenSSH SSH Server" 2>&1 | Out-Null
        }
        $svc = Get-Service sshd -ErrorAction SilentlyContinue
        if ($svc) {
            Write-Host "  sshd 服务注册成功" -ForegroundColor Green
            $sshdInstalled = $true
        } else {
            Write-Host "  服务注册失败, 继续尝试其他方法..." -ForegroundColor Red
        }
    } else {
        Write-Host "  磁盘上未找到 sshd.exe" -ForegroundColor Gray
    }
}

# --- 方法 A: 用 curl.exe 从 GitHub 下载 (Win10 1803+ 自带, 和 PowerShell 用不同的网络栈) ---
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 A (curl.exe 下载)..." -ForegroundColor Yellow
    $curlExe = "$env:SystemRoot\System32\curl.exe"
    if (Test-Path $curlExe) {
        $arch = if ([Environment]::Is64BitOperatingSystem) { "Win64" } else { "Win32" }
        $zipPath = "$env:TEMP\OpenSSH-Download.zip"
        $extractPath = "$env:TEMP\OpenSSH-Extract"
        $installPath = "C:\Program Files\OpenSSH"
        $downloaded = $false

        $downloadUrls = @(
            "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-${arch}.zip"
        )

        foreach ($url in $downloadUrls) {
            if ($downloaded) { break }
            Write-Host "  正在下载 OpenSSH-${arch}.zip..." -ForegroundColor Gray
            try {
                # curl.exe: -L 跟随重定向, -k 跳过证书验证, --connect-timeout 连接超时, --max-time 总超时
                & $curlExe -L -k --connect-timeout 15 --max-time 120 -o $zipPath $url 2>&1 | Out-Null
                if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 100000) {
                    Write-Host "  下载成功" -ForegroundColor Green
                    $downloaded = $true
                }
            } catch {
                Write-Host "  curl 下载失败: $_" -ForegroundColor Gray
            }
        }

        if ($downloaded) {
            try {
                if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
                Write-Host "  正在解压..." -ForegroundColor Gray
                Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
                $sshFolder = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
                if (-not $sshFolder) { throw "解压后找不到 OpenSSH 文件夹" }

                Stop-Service sshd -Force -ErrorAction SilentlyContinue
                if (Test-Path $installPath) { Remove-Item $installPath -Recurse -Force }
                Copy-Item -Path $sshFolder.FullName -Destination $installPath -Recurse -Force

                $installScript = Join-Path $installPath "install-sshd.ps1"
                if (Test-Path $installScript) {
                    Write-Host "  正在注册 sshd 服务..." -ForegroundColor Gray
                    & powershell.exe -ExecutionPolicy Bypass -File $installScript
                }
                if (Get-Service sshd -ErrorAction SilentlyContinue) {
                    Write-Host "  OpenSSH 安装成功" -ForegroundColor Green
                    $sshdInstalled = $true
                }

                $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
                if ($machinePath -notlike "*$installPath*") {
                    [Environment]::SetEnvironmentVariable("Path", "$machinePath;$installPath", "Machine")
                    $env:Path = "$env:Path;$installPath"
                }
                Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
                Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                Write-Host "  解压/安装失败: $($_.Exception.Message)" -ForegroundColor Red
            }
        } else {
            Write-Host "  curl 下载失败 (网络不通)" -ForegroundColor Red
        }
    } else {
        Write-Host "  curl.exe 不存在, 跳过" -ForegroundColor Gray
    }
}

# --- 方法 B: PowerShell 下载 (和 curl 用不同的 TLS 栈, 作为互补) ---
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 B (PowerShell 下载)..." -ForegroundColor Yellow
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
        try { [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true } } catch {}

        $arch = if ([Environment]::Is64BitOperatingSystem) { "Win64" } else { "Win32" }
        $zipPath = "$env:TEMP\OpenSSH-Download.zip"
        $extractPath = "$env:TEMP\OpenSSH-Extract"
        $installPath = "C:\Program Files\OpenSSH"
        $downloaded = $false

        # 直接下载
        $url = "https://github.com/PowerShell/Win32-OpenSSH/releases/latest/download/OpenSSH-${arch}.zip"
        try {
            Write-Host "  正在下载 OpenSSH-${arch}.zip..." -ForegroundColor Gray
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add("User-Agent", "PowerShell")
            $wc.DownloadFile($url, $zipPath)
            if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 100000) {
                $downloaded = $true
            }
        } catch {
            Write-Host "  WebClient 下载失败: $($_.Exception.Message)" -ForegroundColor Gray
        }

        # 回退: API 查询
        if (-not $downloaded) {
            try {
                Write-Host "  尝试通过 API 查询..." -ForegroundColor Gray
                $release = Invoke-RestMethod -Uri "https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest" -TimeoutSec 15
                $asset = $release.assets | Where-Object { $_.name -like "OpenSSH-${arch}*.zip" -and $_.name -notlike "*debug*" } | Select-Object -First 1
                if ($asset) {
                    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing -TimeoutSec 120
                    if ((Test-Path $zipPath) -and (Get-Item $zipPath).Length -gt 100000) { $downloaded = $true }
                }
            } catch {
                Write-Host "  API 下载也失败: $($_.Exception.Message)" -ForegroundColor Gray
            }
        }

        if ($downloaded) {
            if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
            Write-Host "  正在解压..." -ForegroundColor Gray
            Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
            $sshFolder = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
            if (-not $sshFolder) { throw "解压后找不到 OpenSSH 文件夹" }

            Stop-Service sshd -Force -ErrorAction SilentlyContinue
            if (Test-Path $installPath) { Remove-Item $installPath -Recurse -Force }
            Copy-Item -Path $sshFolder.FullName -Destination $installPath -Recurse -Force

            $installScript = Join-Path $installPath "install-sshd.ps1"
            if (Test-Path $installScript) {
                Write-Host "  正在注册 sshd 服务..." -ForegroundColor Gray
                & powershell.exe -ExecutionPolicy Bypass -File $installScript
            }
            if (Get-Service sshd -ErrorAction SilentlyContinue) {
                Write-Host "  OpenSSH 安装成功" -ForegroundColor Green
                $sshdInstalled = $true
            }

            $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($machinePath -notlike "*$installPath*") {
                [Environment]::SetEnvironmentVariable("Path", "$machinePath;$installPath", "Machine")
                $env:Path = "$env:Path;$installPath"
            }
            Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
            Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  方法 B 失败 (网络不通)" -ForegroundColor Red
        }
    } catch {
        Write-Host "  方法 B 失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# --- 方法 C: Windows 组件安装 (最后手段, 30秒超时, 公司电脑大概率会卡) ---
if (-not $sshdInstalled) {
    Write-Host "  尝试方法 C (Windows 组件安装, 30秒超时)..." -ForegroundColor Yellow
    Write-Host "  [提示] 如果出现蓝色进度条, 请等待最多30秒会自动跳过" -ForegroundColor Gray
    $job = Start-Job -ScriptBlock {
        try {
            $r = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
            return @{ Success = $true; RestartNeeded = $r.RestartNeeded }
        } catch {
            return @{ Success = $false; Error = $_.Exception.Message }
        }
    }
    $finished = $job | Wait-Job -Timeout 30
    if ($finished) {
        $result = Receive-Job $job
        Remove-Job $job -Force
        if ($result.Success) {
            if ($result.RestartNeeded) {
                Write-Host "  [警告] 安装完成, 但可能需要重启" -ForegroundColor Red
            } else {
                Write-Host "  已安装 OpenSSH Server" -ForegroundColor Green
            }
            $sshdInstalled = $true
        } else {
            Write-Host "  方法 C 失败: $($result.Error)" -ForegroundColor Red
        }
    } else {
        Write-Host "  方法 C 超时 (30秒), 跳过" -ForegroundColor Red
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

# --- 最终检查 ---
$sshdService = Get-Service sshd -ErrorAction SilentlyContinue
if (-not $sshdService) {
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "  [失败] OpenSSH Server 安装不上" -ForegroundColor Red
    Write-Host "========================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "  所有方法都失败了, 可能原因:" -ForegroundColor Yellow
    Write-Host "    1. 公司网络封锁了 GitHub" -ForegroundColor Yellow
    Write-Host "    2. Windows 组件服务被公司 IT 锁死" -ForegroundColor Yellow
    Write-Host "    3. 需要让 IT 手动安装 OpenSSH Server" -ForegroundColor Yellow
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

$configPath = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $configPath)) {
    Write-Host "  sshd_config 不存在, 先启动 sshd 生成默认配置..." -ForegroundColor Gray
    Start-Service sshd -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
}

try {
    if (Test-Path $configPath) {
        $backupPath = "C:\ProgramData\ssh\sshd_config.bak.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Copy-Item $configPath $backupPath -Force
        Write-Host "  已备份原配置到 $backupPath" -ForegroundColor Gray

        $config = Get-Content $configPath -Raw

        if ($config -match "#\s*PubkeyAuthentication") {
            $config = $config -replace "#\s*PubkeyAuthentication\s+yes", "PubkeyAuthentication yes"
            Write-Host "  已启用 PubkeyAuthentication" -ForegroundColor Green
        } elseif ($config -notmatch "(?m)^PubkeyAuthentication\s+yes") {
            $config = "PubkeyAuthentication yes`r`n" + $config
            Write-Host "  已添加 PubkeyAuthentication yes" -ForegroundColor Green
        } else {
            Write-Host "  PubkeyAuthentication 已启用" -ForegroundColor Green
        }

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

$authKeys = "$env:USERPROFILE\.ssh\authorized_keys"
try {
    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) { mkdir $sshDir -Force | Out-Null }
    Set-Content -Path $authKeys -Value $pubKeys -Force
    Write-Host "  已写入 $authKeys" -ForegroundColor Green
} catch {
    Write-Host "  [错误] 写入用户 authorized_keys 失败: $_" -ForegroundColor Red
}

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
    if (Test-Path $authKeys) {
        icacls $authKeys /inheritance:r /grant "$($env:USERNAME):(F)" /grant "SYSTEM:(F)" | Out-Null
        Write-Host "  已设置 authorized_keys 权限" -ForegroundColor Green
    }
} catch {
    Write-Host "  [错误] 设置用户 authorized_keys 权限失败: $_" -ForegroundColor Red
}

try {
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
# 最终验证
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
if (-not $tailscaleIP) {
    try {
        $tailscaleIP = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "100.*" } | Select-Object -First 1).IPAddress
    } catch {}
}

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
