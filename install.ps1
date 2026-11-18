$ErrorActionPreference = 'Stop'

$ProgressPreference = 'SilentlyContinue'
Set-ExecutionPolicy Bypass -Scope Process -Force

function Assert-Success { if ($LASTEXITCODE -ne 0) { throw "last command failed with exit code $LASTEXITCODE" } }

try {
  if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Write-Output "installing chocolatey..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
    Invoke-Expression ((New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
  }

  $env:ChocolateyAllowGlobalConfirmation = 'true'

  Write-Output "installing aws cli and git..."
  choco install -y awscli --version 2.39.3; Assert-Success
  choco install -y git; Assert-Success

  $env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."
  Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
  refreshenv

  $awsV2Path = "$env:ProgramFiles\Amazon\AWSCLIV2\aws.exe"
  foreach ($awsCommand in Get-Command aws -All -CommandType Application) {
    if ($awsCommand.Source -ne $awsV2Path) {
      $oldAwsFiles = Join-Path (Split-Path $awsCommand.Source) 'aws*'
      Write-Output "removing old aws $oldAwsFiles"
      Remove-Item $oldAwsFiles
    }
  }

  $botCaArn = 'arn:aws:acm-pca:eu-west-2:975050149745:certificate-authority/6d8cf8b7-b8c7-4fba-b02a-bbd8551a624b'
  $botTrustAnchorArn = 'arn:aws:rolesanywhere:eu-west-2:975050149745:trust-anchor/cb170dd7-770f-44a4-b801-dc374add559c'
  $botProfileArn = 'arn:aws:rolesanywhere:eu-west-2:975050149745:profile/00e3b90b-3412-4b06-9cb7-1a7aadb43d0c'
  $botRoleArn = 'arn:aws:iam::975050149745:role/automation-bot-device'
  $ssoStartUrl = 'https://d-9c67b72d79.awsapps.com/start'
  $awsAccountId = '975050149745'

  $botCertificateDir = "$HOME\.aws\bot-certificate"
  $botCert = "$botCertificateDir\aws-bot.crt"
  $botKey = "$botCertificateDir\aws-bot.key"
  $signingHelper = "$botCertificateDir\aws_signing_helper.exe"
  New-Item -ItemType Directory -Force $botCertificateDir | Out-Null

  if (-not (Test-Path $signingHelper)) {
    Write-Output "downloading aws_signing_helper..."
    Invoke-WebRequest -Uri 'https://rolesanywhere.amazonaws.com/releases/1.8.6/X86_64/Windows/Server2022/aws_signing_helper.exe' -OutFile $signingHelper
  }

  $certificateHasTenDaysLeft = $false
  if (Test-Path $botCert) {
    $certificateEnds = (New-Object Security.Cryptography.X509Certificates.X509Certificate2 $botCert).NotAfter
    $certificateHasTenDaysLeft = $certificateEnds -gt (Get-Date).AddDays(10)
  }

  if ($certificateHasTenDaysLeft) {
    Write-Output "AWS certificate has at least 10 days left"
  } else {
    Write-Output "getting this machine an AWS certificate: a browser will open, log in with YOUR OWN SSO account"
    aws configure set profile.bot-certificate-issuer.sso_start_url $ssoStartUrl; Assert-Success
    aws configure set profile.bot-certificate-issuer.sso_region eu-west-2; Assert-Success
    aws configure set profile.bot-certificate-issuer.sso_account_id $awsAccountId; Assert-Success
    aws configure set profile.bot-certificate-issuer.sso_role_name BotCertificateIssuer; Assert-Success
    aws configure set profile.bot-certificate-issuer.region eu-west-2; Assert-Success
    aws sso login --profile bot-certificate-issuer; Assert-Success

    $openssl = "$env:ProgramFiles\Git\mingw64\bin\openssl.exe"
    $csrPath = "$botCertificateDir\aws-bot.csr"
    & $openssl req -new -newkey rsa:2048 -nodes -keyout "$botKey.new" -out $csrPath -subj "/CN=$(hostname)"; Assert-Success

    $certificateArn = aws acm-pca issue-certificate --profile bot-certificate-issuer `
      --certificate-authority-arn $botCaArn `
      --csr "fileb://$csrPath" `
      --signing-algorithm SHA256WITHRSA `
      --template-arn 'arn:aws:acm-pca:::template/EndEntityClientAuthCertificate/V1' `
      --validity 'Value=90,Type=DAYS' `
      --query CertificateArn --output text; Assert-Success
    aws acm-pca wait certificate-issued --profile bot-certificate-issuer `
      --certificate-authority-arn $botCaArn --certificate-arn $certificateArn; Assert-Success
    $certificateLines = aws acm-pca get-certificate --profile bot-certificate-issuer `
      --certificate-authority-arn $botCaArn --certificate-arn $certificateArn `
      --query Certificate --output text; Assert-Success
    [IO.File]::WriteAllText("$botCert.new", ($certificateLines -join "`n") + "`n")

    Move-Item -Force "$botKey.new" $botKey
    Move-Item -Force "$botCert.new" $botCert
    Remove-Item $csrPath

    aws sso logout --profile bot-certificate-issuer; Assert-Success
  }

  Write-Output "getting the repo url and GitHub deploy key from AWS..."
  if ($HOME.Contains(' ')) {
    throw "the AWS profile can't point at files under '$HOME' because of the space in it - use a Windows user without a space in its name"
  }
  aws configure set profile.bot-certificate.region eu-west-2; Assert-Success
  aws configure set profile.bot-certificate.credential_process "$signingHelper credential-process --certificate $botCert --private-key $botKey --trust-anchor-arn $botTrustAnchorArn --profile-arn $botProfileArn --role-arn $botRoleArn"; Assert-Success
  $repoUrl = aws ssm get-parameter --profile bot-certificate --name /automation/bot-repo-url --query Parameter.Value --output text; Assert-Success
  $keyLines = aws secretsmanager get-secret-value --profile bot-certificate --secret-id automation/bot-github-deploy-key --query SecretString --output text; Assert-Success

  $repoName = [IO.Path]::GetFileNameWithoutExtension($repoUrl)
  $repoDir = "$HOME\$repoName"
  $oldRepoDir = "C:\$repoName"
  Write-Output "repo path: $repoDir"

  $keyPath = "$HOME\.ssh\${repoName}_deploy_key"
  New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null

  [IO.File]::WriteAllText($keyPath, ($keyLines -join "`n") + "`n")

  $adminSshKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAIm7/77CZ8q2Z2sJWfVsq4eHw8hl4NIrKoQuO/yZu1i JOLLOF-MINTY-TANK'

  Write-Output "Enabling remote desktop..."
  Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0

  Write-Output "Enabling remote desktop in firewall..."
  Enable-NetFirewallRule -DisplayGroup "Remote Desktop"

  if (Get-Service sshd -ErrorAction SilentlyContinue) {
    Write-Output "OpenSSH server already installed"
  } else {
    Write-Output "Installing OpenSSH server..."
    $opensshMsi = "$env:TEMP\OpenSSH-Win64-v10.0.0.0.msi"
    Invoke-WebRequest -Uri 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/10.0.0.0p2-Preview/OpenSSH-Win64-v10.0.0.0.msi' -OutFile $opensshMsi
    if ((Get-FileHash $opensshMsi -Algorithm SHA256).Hash -ne 'DDEC9C53864280759CF9F74791CEFD387100E3946AA849A1C138A4ED1B96B7D9') {
      throw "OpenSSH msi download doesn't match its known checksum"
    }
    $opensshLog = "$env:TEMP\openssh-install.log"
    $msiexec = Start-Process msiexec.exe -ArgumentList '/i', $opensshMsi, 'ADDLOCAL=Server', '/quiet', '/norestart', '/L*V', $opensshLog -Wait -PassThru
    if ($msiexec.ExitCode -ne 0 -and $msiexec.ExitCode -ne 3010) {
      throw "OpenSSH server install failed with exit code $($msiexec.ExitCode), log: $opensshLog"
    }
  }

  Write-Output "Start SSH service (to generate config file)..."
  Restart-Service sshd

  Write-Output "Setting SSH service to start automatically..."
  Set-Service -Name sshd -StartupType 'Automatic'

  $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $backup_path = "C:\ProgramData\ssh\sshd_config.backup_$timestamp"
  Write-Output "Creating backup of sshd_config at $backup_path"
  Copy-Item "C:\ProgramData\ssh\sshd_config" -Destination $backup_path

  Write-Output "Setting PowerShell as default SSH shell..."
  New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force

  Write-Output "Configuring sshd_config..."
  $sshd_config = "C:\ProgramData\ssh\sshd_config"

  if (-not (Test-Path $sshd_config)) {
    throw "sshd_config file not found at $sshd_config"
  }

  if ((Get-Item $sshd_config).length -eq 0) {
    throw "sshd_config file exists but is empty"
  }

  (Get-Content $sshd_config) -replace '#PubkeyAuthentication', 'PubkeyAuthentication' | Out-File -encoding ASCII $sshd_config
  (Get-Content $sshd_config) -replace '#Match Group administrators', 'Match Group administrators' | Out-File -encoding ASCII $sshd_config
  (Get-Content $sshd_config) -replace '\s*#+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys', '       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys' | Out-File -encoding ASCII $sshd_config

  Write-Output "Setting up administrators_authorized_keys..."
  $filePath = "C:\ProgramData\ssh\administrators_authorized_keys"
  Set-Content -Path $filePath -Value $adminSshKey

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

  Write-Output "Configuring firewall rules..."

  Remove-NetFirewallRule -Name *SSH* -ErrorAction SilentlyContinue

  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
    -DisplayName 'OpenSSH Server (sshd)' `
    -Enabled True `
    -Direction Inbound `
    -Protocol TCP `
    -Action Allow `
    -LocalPort 22 `
    -Profile Any

  Write-Output "Restarting SSH service..."
  Restart-Service sshd

  Write-Output "SSH Server setup completed successfully!"

  Write-Output "Removing windows app execution aliases for python..."
  Remove-Item $env:LOCALAPPDATA\Microsoft\WindowsApps\python.exe -ErrorAction SilentlyContinue -WarningAction Continue
  if (-not $?) { Write-Warning "Could not remove python.exe alias (may not exist)" }
  Remove-Item $env:LOCALAPPDATA\Microsoft\WindowsApps\python3.exe -ErrorAction SilentlyContinue -WarningAction Continue
  if (-not $?) { Write-Warning "Could not remove python3.exe alias (may not exist)" }

  Write-Output "installing packages..."
  choco install -y scrcpy --version 2.4

  $nvm2Uninstaller = "$env:LOCALAPPDATA\Author Software\nvm\unins000.exe"
  if (Test-Path $nvm2Uninstaller) {
    Write-Output "removing nvm 2..."
    Start-Process $nvm2Uninstaller -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait
    choco uninstall -y nvm.install --skip-powershell
  }

  if (Test-Path "$env:ChocolateyInstall\lib\nvm") {
    choco uninstall -y nvm -x --skip-powershell
  }

  $nodeLink = Get-ChildItem 'C:\Program Files' -Filter nodejs -Force | Where-Object { $_.Attributes -match 'ReparsePoint' }
  if ($nodeLink) {
    Write-Output "removing node link $($nodeLink.FullName)"
    cmd /c rmdir "$($nodeLink.FullName)"
  }

  Write-Output "installing nvm 1.1.11..."
  $nvmZip = "$env:TEMP\nvm-setup-1.1.11.zip"
  Invoke-WebRequest -Uri "https://github.com/coreybutler/nvm-windows/releases/download/1.1.11/nvm-setup.zip" -OutFile $nvmZip

  if ((Get-FileHash $nvmZip -Algorithm SHA256).Hash -ne '71DF09235FF5085DEE44E451F7D365DA144A5BB3A3E8C809136374D24B3F8250') {
    throw "nvm-setup.zip download doesn't match its known checksum"
  }
  Expand-Archive -Force $nvmZip "$env:TEMP\nvm-setup-1.1.11"
  Start-Process "$env:TEMP\nvm-setup-1.1.11\nvm-setup.exe" -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOICONS', '/DIR=C:\ProgramData\nvm' -Wait
  choco install -y scrcpy adb notepadplusplus
  choco install -y ffmpeg --version=7.1.1
  choco install -y googlechrome --ignore-checksums
  choco install -y setdefaultbrowser

  choco install -y gstreamer --ignore-checksums
  choco install -y python314

  choco install -y vcredist140

  Write-Output "setting default browser to chrome"

  try {
    SetDefaultBrowser.exe HKLM "Google Chrome"
  } catch {
    Write-Warning "could not set chrome as the default browser ($_) - set it by hand in Settings > Apps > Default apps"
  }

  Write-Output "re-loading powershell environment variables"
  $env:ChocolateyInstall = Convert-Path "$((Get-Command choco).Path)\..\.."
  Import-Module "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
  refreshenv

  Write-Output "installing nodejs"
  nvm install 24.11.1
  nvm use 24.11.1

  Write-Output "Selecting high performance plan"
  powercfg /setactive SCHEME_MIN

  Write-Output "Disabling USB selective suspend..."
  powercfg /SETACVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0
  powercfg /SETDCVALUEINDEX SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0

  Write-Output "Setting monitor timeout to never (0) when plugged in (AC power)"
  powercfg -change -monitor-timeout-ac 0

  Write-Output "Setting sleep timeout to never (0) when plugged in (AC power)"
  powercfg -change -standby-timeout-ac 0

  Write-Output "Setting AC close lid to no action"
  powercfg /SETACVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0

  Write-Output "Setting DC close lid to no action"
  powercfg /SETDCVALUEINDEX SCHEME_CURRENT SUB_BUTTONS LIDACTION 0

  Write-Output "re-activating changes in the power plan"
  powercfg /setactive SCHEME_CURRENT

  Write-Output "power configuration list (should show high performance)"
  powercfg /list

  Write-Output "disabling hibernate"
  powercfg -h off

  Write-Output "adding registry entry to disable windows defender"
  New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender" -Name "DisableAntiSpyware" -Value 1 -PropertyType DWORD -Force

  Write-Output "adding registry entry to disable real-time protection"
  New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Force
  New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" -Name "DisableRealtimeMonitoring" -Value 1 -PropertyType DWORD -Force

  # Windows 11 Smart App Control blocks unsigned programs such as chocolatey's ffmpeg/adb/scrcpy
  # launchers ("An Application Control policy has blocked this file"), so the bot can't record.
  # It switches itself on some time after a fresh install. 0 = off, 1 = on, 2 = evaluating.
  # https://support.microsoft.com/en-us/topic/what-is-smart-app-control-285ea03d-fa88-4d56-882e-6698afdb7003
  $smartAppControlKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy'
  if (Test-Path $smartAppControlKey) {
    Write-Output "turning off Smart App Control"
    Set-ItemProperty -Path $smartAppControlKey -Name VerifiedAndReputablePolicyState -Value 0
    # applies the change now instead of at the next restart
    CiTool.exe --refresh --json; Assert-Success
  } else {
    Write-Output "no Smart App Control on this Windows version"
  }

  $sshCommand = "ssh -i $($keyPath -replace '\\', '/') -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
  if (Test-Path "$repoDir\.git") {
    Write-Output "repo found, pointing it at $repoUrl and updating..."
    git -C $repoDir remote set-url origin $repoUrl; Assert-Success
    git -C $repoDir config core.sshCommand $sshCommand; Assert-Success
    git -C $repoDir stash --include-untracked; Assert-Success
    git -C $repoDir fetch --tags; Assert-Success
    git -C $repoDir checkout master; Assert-Success
    git -C $repoDir pull; Assert-Success

    New-Item -ItemType File -Force "$repoDir\.builderror" | Out-Null
  } else {
    Write-Output "cloning $repoUrl..."
    git clone -c "core.sshCommand=$sshCommand" $repoUrl $repoDir; Assert-Success
  }

  $shell = New-Object -ComObject WScript.Shell
  $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'LAUNCH.lnk'

  if (Test-Path $oldRepoDir) {
    Write-Output "removing old install $oldRepoDir"

    Remove-Item -Recurse -Force $oldRepoDir -ErrorAction Continue
    if (Test-Path $oldRepoDir) { Write-Warning "could not fully remove $oldRepoDir (close any terminal open in it), delete it by hand" }
  }

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

  $shortcut.WorkingDirectory = $repoDir
  $shortcut.Save()

  Write-Output "creating bin directory"
  New-Item -ItemType Directory -Force -Path "$repoDir\bin"

  Write-Output "downloading scrcpy-server-v2.4"
  Invoke-WebRequest -Uri "https://github.com/Genymobile/scrcpy/releases/download/v2.4/scrcpy-server-v2.4" -OutFile "$repoDir\bin\scrcpy-server-v2.4"

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
} catch {
  $errorPage = "$env:TEMP\installation-failed.html"
  $errorText = [System.Net.WebUtility]::HtmlEncode("$($_.Exception.Message)`n`n$($_.InvocationInfo.PositionMessage)`n`n$($_.ScriptStackTrace)")
  Set-Content -Path $errorPage -Value @"
<!doctype html>
<html>
<head><title>Installation failed</title></head>
<body style='font-family:monospace;padding:20px;background:black;color:white'>
<h2 style='color:crimson'>Installation failed</h2>
<img src="https://i.kym-cdn.com/entries/icons/original/000/030/659/ben.jpg">
<pre style='background:darkslategray;padding:10px;white-space:pre-wrap'>$errorText</pre>
</body>
</html>
"@
  Start-Process $errorPage
  throw
}
