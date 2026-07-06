# Provisions the Windows Server 2025 build VM before sysprep:
#   1. virtio-win guest tools (all virtio drivers into the driver
#      store + QEMU guest agent) so deployed VMs run on xCompute's
#      virtio devices even though the BUILD VM uses inbox IDE/e1000.
#   2. Cloudbase-Init — the Windows cloud-init; handles hostname,
#      credentials, network, and user-data on first boot (M3.1).
# Sysprep itself runs as Packer's shutdown_command.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Windows PowerShell 5.1 defaults to TLS 1.0/1.1 (rejected by most
# mirrors -> silent truncated download saved as the target file, which
# then fails Start-Process with "corrupted and unreadable"). Force 1.2.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Download with retry + basic-parsing (no IE engine) + integrity check:
# real installers start with the 'MZ' PE header and are megabytes, not
# an HTML error page.
function Get-Installer {
  param([string]$Uri, [string]$OutFile, [int]$MinBytes = 1000000)
  for ($i = 1; $i -le 4; $i++) {
    try {
      Write-Host "  download attempt $i : $Uri"
      Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec 300
      $len = (Get-Item $OutFile).Length
      if ($len -lt $MinBytes) { throw "file too small ($len bytes) — likely an error page" }
      $sig = [System.IO.File]::ReadAllBytes($OutFile)[0..1]
      if ($sig[0] -ne 0x4D -or $sig[1] -ne 0x5A) { throw "not a PE/MSI (no MZ header)" }
      Write-Host "  ok ($len bytes)"
      return
    } catch {
      Write-Host "  failed: $_"
      Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
      if ($i -eq 4) { throw "download failed after 4 attempts: $Uri" }
      Start-Sleep -Seconds ($i * 10)
    }
  }
}

Write-Host '== virtio-win guest tools =='
$virtio = 'C:\Windows\Temp\virtio-win-guest-tools.exe'
Get-Installer -Uri 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe' -OutFile $virtio
$p = Start-Process -FilePath $virtio -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru
# virtio-win installer returns 0 (ok) or 3010 (ok, reboot required).
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "virtio-win installer exited $($p.ExitCode)" }
Write-Host "virtio-win installed (exit $($p.ExitCode))"

Write-Host '== Cloudbase-Init =='
$cbi = 'C:\Windows\Temp\CloudbaseInitSetup.msi'
Get-Installer -Uri 'https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile $cbi
$p = Start-Process msiexec -ArgumentList '/i', "`"$cbi`"", '/qn', '/norestart' -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Cloudbase-Init installer exited $($p.ExitCode)" }
Write-Host "Cloudbase-Init installed (exit $($p.ExitCode))"

# Minimal runtime config: NoCloud/ConfigDrive metadata (what xCompute
# attaches), first boot handles hostname + password + ssh keys + userdata.
$confDir = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf'
if (-not (Test-Path $confDir)) { throw "Cloudbase-Init conf dir missing — install did not complete" }
$conf = @"
[DEFAULT]
username=Administrator
groups=Administrators
inject_user_password=true
first_logon_behaviour=no
config_drive_raw_hhd=true
config_drive_cdrom=true
config_drive_vfat=true
bsdtar_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\bsdtar.exe
mtools_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\bin\
verbose=true
debug=true
logdir=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\log\
logfile=cloudbase-init.log
default_log_levels=comtypes=INFO,suds=INFO,iso8601=WARN,requests=WARN
local_scripts_path=C:\Program Files\Cloudbase Solutions\Cloudbase-Init\LocalScripts\
metadata_services=cloudbaseinit.metadata.services.configdrive.ConfigDriveService,cloudbaseinit.metadata.services.nocloudservice.NoCloudConfigDriveService
"@
Set-Content -Path (Join-Path $confDir 'cloudbase-init.conf') -Value $conf -Encoding ascii
Set-Content -Path (Join-Path $confDir 'cloudbase-init-unattend.conf') -Value $conf -Encoding ascii

Write-Host '== cleanup =='
Remove-Item $virtio, $cbi -Force -ErrorAction SilentlyContinue
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue

# Sysprep /generalize here (in the provisioner, NOT as Packer's
# shutdown_command over WinRM) so a hang or error is VISIBLE with its
# log instead of a blind 30-minute shutdown timeout. No /shutdown: the
# box stays up and generalized; Packer's shutdown_command powers it off
# cleanly, preserving the generalized state for first-boot OOBE +
# Cloudbase-Init.
Write-Host '== sysprep /generalize =='
$unattend = 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\Unattend.xml'
if (-not (Test-Path $unattend)) { throw "sysprep unattend missing: $unattend" }
$panther = 'C:\Windows\System32\Sysprep\Panther\setupact.log'
Remove-Item $panther -Force -ErrorAction SilentlyContinue
$p = Start-Process -FilePath 'C:\Windows\System32\Sysprep\sysprep.exe' `
  -ArgumentList '/generalize','/oobe','/quiet','/unattend:"'+$unattend+'"' -Wait -PassThru
Write-Host "sysprep exit $($p.ExitCode)"
if ($p.ExitCode -ne 0) {
  Write-Host '== last 60 lines of sysprep setupact.log =='
  if (Test-Path $panther) { Get-Content $panther -Tail 60 | ForEach-Object { Write-Host $_ } }
  throw "sysprep failed with exit $($p.ExitCode)"
}
Write-Host 'sysprep complete — image generalized'

Write-Host 'provisioning complete'
