# Run in an admin PowerShell:
#   irm <this file's url> | iex
# Asks for the repo and the AWS access key, sets up an office Windows machine (RDP + SSH,
# packages, power settings), then clones (or updates) the repo into ~ with the deploy key stored in AWS.

# Stop the script when a cmdlet fails
$ErrorActionPreference = 'Stop'
# Disable progress bars which can cause hanging in non-interactive contexts
$ProgressPreference = 'SilentlyContinue'
Set-ExecutionPolicy Bypass -Scope Process -Force

# Windows PowerShell doesn't stop when a native command (aws, git) fails, so check after each
function Assert-Success { if ($LASTEXITCODE -ne 0) { throw "last command failed with exit code $LASTEXITCODE" } }

# keep asking until there's an answer: a stray newline from pasting the command answers a prompt with nothing
$repoUrl = ''
while (-not $repoUrl) { $repoUrl = (Read-Host 'repo SSH url (e.g. git@github.com:org/repo.git)').Trim() }
$accessKeyId = ''
while (-not $accessKeyId) { $accessKeyId = (Read-Host 'AWS access key ID').Trim() }
$secretAccessKey = ''
while (-not $secretAccessKey) {
  $secretAccessKeySecure = Read-Host 'AWS secret access key' -AsSecureString
  $secretAccessKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretAccessKeySecure)).Trim()
}

$repoName = [IO.Path]::GetFileNameWithoutExtension($repoUrl)
$repoDir = "$HOME\$repoName"
$oldRepoDir = "C:\$repoName"
Write-Output "repo path: $repoDir"

# Joel's public key, for SSH (ansible) access
$adminSshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAIm7/77CZ8q2Z2sJWfVsq4eHw8hl4NIrKoQuO/yZu1i JOLLOF-MINTY-TANK'

Write-Output "Enabling remote desktop..."
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

Write-Output "Enabling remote desktop in firewall..."
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

Write-Output "Installing OpenSSH server..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

Write-Output "Start SSH service (to generate config file)..."
Restart-Service sshd

Write-Output "Setting SSH service to start automatically..."
Set-Service -Name sshd -StartupType 'Automatic'

# Backup sshd_config before making any changes
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backup_path = "C:\ProgramData\ssh\sshd_config.backup_$timestamp"
Write-Output "Creating backup of sshd_config at $backup_path"
Copy-Item "C:\ProgramData\ssh\sshd_config" -Destination $backup_path

# Configure PowerShell as default SSH shell
Write-Output "Setting PowerShell as default SSH shell..."
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

# Modify sshd_config file
Write-Output "Configuring sshd_config..."
$sshd_config = "C:\ProgramData\ssh\sshd_config"

# Check if sshd_config exists
if (-not (Test-Path $sshd_config)) {
  Write-Error "ERROR: sshd_config file not found at $sshd_config"
  Read-Host 'Press any key to continue...'
  exit 1
}

# Check if file is empty
if ((Get-Item $sshd_config).length -eq 0) {
  Write-Error "ERROR: sshd_config file exists but is empty"
  Read-Host 'Press any key to continue...'
  exit 1
}

(Get-Content $sshd_config) -replace '#PubkeyAuthentication', 'PubkeyAuthentication' | Out-File -encoding ASCII $sshd_config
(Get-Content $sshd_config) -replace '#Match Group administrators', 'Match Group administrators' | Out-File -encoding ASCII $sshd_config
(Get-Content $sshd_config) -replace '\s*#+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys', '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys' | Out-File -encoding ASCII $sshd_config

# Configure administrators_authorized_keys
Write-Output "Setting up administrators_authorized_keys..."
$filePath = "C:\ProgramData\ssh\administrators_authorized_keys"
Set-Content -Path $filePath -Value $adminSshKey

# Configure file permissions
Write-Output "Configuring file permissions..."
$acl = Get-Acl $filePath
$administratorsGroup = New-Object System.Security.Principal.NTAccount("Administrators")
$acl.SetOwner($administratorsGroup)
$acl.SetAccessRuleProtection($true, $false)
$administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule("Administrators", "FullControl", "Allow")
$systemRule = New-Object system.security.accesscontrol.filesystemaccessrule("SYSTEM", "FullControl", "Allow")
$acl.SetAccessRule($administratorsRule)
$acl.SetAccessRule($systemRule)
$acl | Set-Acl

# Configure firewall rules
Write-Output "Configuring firewall rules..."
# Remove any existing SSH firewall rules to avoid duplicates
Remove-NetFirewallRule -Name *SSH* -ErrorAction SilentlyContinue

# Create new firewall rule for all profiles
New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
  -DisplayName 'OpenSSH Server (sshd)' `
  -Enabled True `
  -Direction Inbound `
  -Protocol TCP `
  -Action Allow `
  -LocalPort 22 `
  -Profile Any

# Restart the SSH service
Write-Output "Restarting SSH service..."
Restart-Service sshd

Write-Output "SSH Server setup completed successfully!"

Write-Output "Removing windows app execution aliases for python..."
Remove-Item $env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe -ErrorAction SilentlyContinue -WarningAction Continue
if (-not $?) { Write-Warning "Could not remove python.exe alias (may not exist)" }
Remove-Item $env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe -ErrorAction SilentlyContinue -WarningAction Continue
if (-not $?) { Write-Warning "Could not remove python3.exe alias (may not exist)" }

if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
  Write-Output "installing chocolatey..."
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
  Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Force non-interactive mode and confirm yes to all prompts
$env:ChocolateyAllowGlobalConfirmation = 'true'

Write-Output "installing packages..."
choco install -y git
choco install -y awscli --version 2.39.3
choco install -y scrcpy --version 2.4
# A box that already got nvm 2 needs it removed first: choco's own uninstall script for it fails,
# so use nvm 2's uninstaller.
$nvm2Uninstaller = "$env:LOCALAPPDATA\Author Software\nvm\unins000.exe"
if (Test-Path $nvm2Uninstaller) {
  Write-Output "removing nvm 2..."
  Start-Process $nvm2Uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
  choco uninstall -y nvm.install --skip-powershell
}
# nvm.install directly, not the `nvm` package: that one ignores its pin on nvm.install and pulls
# in nvm 2.x, which moves node out of C:\ProgramData\nvm and breaks npm. Remove `nvm` if an earlier
# run installed it. -x takes nvm.install with it - without -x choco stops to ask about it even with -y.
if (Test-Path "$env:ChocolateyInstall\lib\nvm") {
  choco uninstall -y nvm -x --skip-powershell
}
# remove nvm's node link (`nvm use` below recreates it): nvm 2 leaves it dead, and an existing one
# makes the nvm installer wait on a hidden "existing node" message box. Found via its parent folder
# because Test-Path says false for a dead link; rmdir removes only the link, never its target.
$nodeLink = Get-ChildItem 'C:\Program Files' -Filter nodejs -Force | Where-Object { $_.Attributes -match 'ReparsePoint' }
if ($nodeLink) {
  Write-Output "removing node link $($nodeLink.FullName)"
  cmd /c rmdir "$($nodeLink.FullName)"
}
# 1.1.11 not 1.1.12: 1.1.12 hangs forever when its output isn't a console window (ssh, git bash,
# redirected) - https://github.com/coreybutler/nvm-windows/issues/1068
# upgrade, not install: installs it if missing, skips if already 1.1.11, otherwise moves to 1.1.11
# (--allow-downgrade for the boxes already on 1.1.12)
choco upgrade -y nvm.install --version 1.1.11 --allow-downgrade
# the package starts nvm-setup.exe without waiting for it, so wait before `nvm install` below
Wait-Process -Name nvm-setup -ErrorAction SilentlyContinue
choco install -y scrcpy adb notepadplusplus
choco install -y ffmpeg --version=7.1.1
choco install -y googlechrome --ignore-checksums
choco install -y setdefaultbrowser
# the package's checksum for 1.26.9 doesn't match gstreamer's own download
choco install -y gstreamer --ignore-checksums
choco install -y python314
# required for gstreamer
choco install -y vcredist140

Write-Output "setting default browser to chrome"
SetDefaultBrowser.exe HKLM "Google Chrome"

# stolen from here, need to get chocolatey environment vars to use packages
# https://stackoverflow.com/questions/46758437/how-to-refresh-the-environment-of-a-powershell-session-after-a-chocolatey-instal
Write-Output "re-loading powershell environment variables"
$env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."
Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
refreshenv

Write-Output "installing nodejs"
nvm install 24.11.1
nvm use 24.11.1

# max performance commands stolen from [here](https://stackoverflow.com/questions/44921510/change-power-plan-to-high-performance)
Write-Output "Selecting high performance plan"
powercfg /setactive SCHEME_MIN

# disable USB selective suspend stolen from [here](https://thegeekpage.com/usb-selective-suspend/)
Write-Output "Disabling USB selective suspend..."
powercfg /SETDCVALUEINDEX SCHEME_MIN 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0

# Set "turn off monitor" to never stolen from [here](https://stackoverflow.com/questions/36263756/how-to-set-monitor-timeout-to-never-using-powershell)
Write-Output "Setting monitor timeout to never (0) when plugged in (AC power)"
powercfg -change -monitor-timeout-ac 0

Write-Output "Setting sleep timeout to never (0) when plugged in (AC power)"
powercfg -change -standby-timeout-ac 0

Write-Output "Setting AC close lid to no action"
powercfg /SETACVALUEINDEX SCHEME_MIN SUB_BUTTONS LIDACTION 0

Write-Output "Setting DC close lid to no action"
powercfg /SETDCVALUEINDEX SCHEME_MIN SUB_BUTTONS LIDACTION 0

Write-Output "re-activating changes in high performance power plan"
powercfg /setactive SCHEME_MIN

Write-Output "power configuration list (should show high performance)"
powercfg /list

Write-Output "disabling hibernate"
powercfg -h off

Write-Output "adding registry entry to disable windows defender"
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -PropertyType DWORD -Force

Write-Output "adding registry entry to disable real-time protection"
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Force
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -Value 1 -PropertyType DWORD -Force

Write-Output "logging in to AWS..."
aws configure set aws_access_key_id $accessKeyId --profile automation-bot; Assert-Success
aws configure set aws_secret_access_key $secretAccessKey --profile automation-bot; Assert-Success
aws configure set region eu-west-2 --profile automation-bot; Assert-Success

Write-Output "getting the GitHub deploy key from AWS..."
$keyPath = "$HOME\.ssh\${repoName}_deploy_key"
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
$keyLines = aws secretsmanager get-secret-value --profile automation-bot --secret-id automation/bot-github-deploy-key --query SecretString --output text; Assert-Success
# ssh rejects a key with \r\n line endings ("invalid format"), so write \n
[IO.File]::WriteAllText($keyPath, ($keyLines -join "`n") + "`n")

# git runs this through its own bash, which needs / not \ in the path
$sshCommand = "ssh -i $($keyPath -replace '\\', '/') -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
if (Test-Path "$repoDir\.git") {
  Write-Output "repo found, pointing it at $repoUrl and updating..."
  git -C $repoDir remote set-url origin $repoUrl; Assert-Success
  git -C $repoDir config core.sshCommand $sshCommand; Assert-Success
  git -C $repoDir stash --include-untracked; Assert-Success
  git -C $repoDir fetch --tags; Assert-Success
  git -C $repoDir checkout master; Assert-Success
  git -C $repoDir pull; Assert-Success
  # makes the launcher reinstall packages and rebuild
  New-Item -ItemType File -Force "$repoDir\.builderror" | Out-Null
} else {
  Write-Output "cloning $repoUrl..."
  git clone -c "core.sshCommand=$sshCommand" $repoUrl $repoDir; Assert-Success
}

$shell = New-Object -ComObject WScript.Shell
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LAUNCH.lnk'

# older installs lived in C:\
if (Test-Path $oldRepoDir) {
  Write-Output "removing old install $oldRepoDir"
  # an open terminal sitting in the folder locks it; warn rather than stop the install
  Remove-Item -Recurse -Force $oldRepoDir -ErrorAction Continue
  if (Test-Path $oldRepoDir) { Write-Warning "could not fully remove $oldRepoDir (close any terminal open in it), delete it by hand" }
}
# any desktop shortcut into the old install, whatever it's called (e.g. a hand-made "LAUNCH - Shortcut")
foreach ($desktop in @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('CommonDesktopDirectory'))) {
  foreach ($link in Get-ChildItem $desktop -Filter *.lnk) {
    if ($shell.CreateShortcut($link.FullName).TargetPath -like "$oldRepoDir\*") {
      Write-Output "removing old desktop shortcut $($link.FullName)"
      Remove-Item $link.FullName
    }
  }
}

Write-Output "writing desktop shortcut $shortcutPath"
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = "$repoDir\LAUNCH.sh"
# LAUNCH.sh writes its logs relative to where it starts
$shortcut.WorkingDirectory = $repoDir
$shortcut.Save()

Write-Output "creating bin directory"
New-Item -ItemType Directory -Force -Path "$repoDir\bin"

Write-Output "downloading scrcpy-server-v2.4"
Invoke-WebRequest -Uri "https://github.com/Genymobile/scrcpy/releases/download/v2.4/scrcpy-server-v2.4" -OutFile "$repoDir\bin\scrcpy-server-v2.4"

# this script runs as admin, so hand the repo back to the normal user (else git complains about ownership)
Write-Output "Setting ownership of $repoDir to $env:USERNAME..."
icacls "$repoDir" /setowner "$env:USERNAME" /T /C

Write-Output "done - start the bot with the LAUNCH shortcut on the desktop"

$donePage = "$env:TEMP\installation-completed.html"
Set-Content -Path $donePage -Value @'
<!doctype html>
<html>
<body>
<h1>installation completed</h1>
<img src="https://c.tenor.com/yqyHqTYHnBkAAAAC/tenor.gif">
</body>
</html>
'@
Start-Process $donePage
