# SSH One-Click Fix Script
# Run in Admin PowerShell: irm https://raw.githubusercontent.com/Tiny-cyber/ssh-fix/main/fix-ssh.ps1 | iex

Write-Host "=== SSH Fix Script ===" -ForegroundColor Cyan

# 1. Ensure OpenSSH Server is installed
$cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
if ($cap.State -ne "Installed") {
    Write-Host "[1/6] Installing OpenSSH Server..." -ForegroundColor Yellow
    Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
} else {
    Write-Host "[1/6] OpenSSH Server already installed" -ForegroundColor Green
}

# 2. Fix sshd_config
Write-Host "[2/6] Fixing sshd_config..." -ForegroundColor Yellow
$configPath = "C:\ProgramData\ssh\sshd_config"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw

    # Enable PubkeyAuthentication
    if ($config -match "#PubkeyAuthentication") {
        $config = $config -replace "#PubkeyAuthentication\s+yes", "PubkeyAuthentication yes"
        Write-Host "  - Enabled PubkeyAuthentication" -ForegroundColor Green
    }
    if ($config -notmatch "(?m)^PubkeyAuthentication\s+yes") {
        $config = "PubkeyAuthentication yes`r`n" + $config
        Write-Host "  - Added PubkeyAuthentication yes" -ForegroundColor Green
    }

    # CRITICAL: Comment out the Match Group administrators block that overrides AuthorizedKeysFile
    # This is the #1 reason admin users can't use ~/.ssh/authorized_keys
    $config = $config -replace "(?m)^(Match Group administrators)", "#`$1"
    $config = $config -replace "(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__)", "#`$1"
    Write-Host "  - Disabled Match Group administrators override" -ForegroundColor Green

    Set-Content -Path $configPath -Value $config -Force
    Write-Host "  - Config saved" -ForegroundColor Green
} else {
    Write-Host "  - sshd_config not found, will be created on first start" -ForegroundColor Yellow
}

# 3. Set up authorized_keys for current user
Write-Host "[3/6] Setting up SSH keys..." -ForegroundColor Yellow
$sshDir = "$env:USERPROFILE\.ssh"
$authKeys = "$sshDir\authorized_keys"
$pubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICmtCGpspbS4qb632U7cUlO0UJXqnZGJZMySVYtV1gPI tinypity@TinyPitydeMac-mini.local"

if (-not (Test-Path $sshDir)) { mkdir $sshDir -Force | Out-Null }
Set-Content -Path $authKeys -Value $pubKey -Force
Write-Host "  - Public key written to $authKeys" -ForegroundColor Green

# Also write to administrators_authorized_keys as fallback
$adminKeys = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $adminKeys -Value $pubKey -Force
icacls $adminKeys /inheritance:r /grant SYSTEM:F /grant Administrators:F | Out-Null
Write-Host "  - Public key also written to administrators_authorized_keys" -ForegroundColor Green

# 4. Fix permissions on user's authorized_keys
Write-Host "[4/6] Fixing file permissions..." -ForegroundColor Yellow
icacls $authKeys /inheritance:r /grant "$($env:USERNAME):(F)" /grant SYSTEM:F | Out-Null
Write-Host "  - Permissions set on authorized_keys" -ForegroundColor Green

# 5. Open firewall
Write-Host "[5/6] Checking firewall..." -ForegroundColor Yellow
$rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $rule) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Host "  - Firewall rule created" -ForegroundColor Green
} else {
    Write-Host "  - Firewall rule already exists" -ForegroundColor Green
}

# 6. Restart sshd
Write-Host "[6/6] Restarting sshd..." -ForegroundColor Yellow
Stop-Service sshd -Force -ErrorAction SilentlyContinue
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic
Write-Host "  - sshd restarted and set to auto-start" -ForegroundColor Green

Write-Host ""
Write-Host "=== DONE! SSH should be working now ===" -ForegroundColor Cyan
Write-Host "Remote user: $env:USERNAME" -ForegroundColor White
Write-Host "Test from Mac: ssh $env:USERNAME@$(hostname)" -ForegroundColor White
