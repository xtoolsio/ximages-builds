# Provisions the Windows Server 2025 build VM before sysprep:
#   1. virtio-win guest tools (all virtio drivers into the driver
#      store + QEMU guest agent) so deployed VMs run on xCompute's
#      virtio devices even though the BUILD VM uses SATA/e1000.
#   2. Cloudbase-Init — the Windows cloud-init; handles hostname,
#      credentials, network, and user-data on first boot (M3.1).
# Sysprep itself runs as Packer's shutdown_command.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Write-Host '== virtio-win guest tools =='
$virtio = 'C:\Windows\Temp\virtio-win-guest-tools.exe'
Invoke-WebRequest -Uri 'https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win-guest-tools.exe' -OutFile $virtio
Start-Process -FilePath $virtio -ArgumentList '/install','/quiet','/norestart' -Wait
Write-Host 'virtio-win installed'

Write-Host '== Cloudbase-Init =='
$cbi = 'C:\Windows\Temp\CloudbaseInitSetup.msi'
Invoke-WebRequest -Uri 'https://cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi' -OutFile $cbi
Start-Process msiexec -ArgumentList '/i', $cbi, '/qn', '/norestart' -Wait
Write-Host 'Cloudbase-Init installed'

# Minimal runtime config: NoCloud/ConfigDrive metadata (what xCompute
# attaches), first boot handles hostname + password + ssh keys + userdata.
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
Set-Content -Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init.conf' -Value $conf -Encoding ascii
Set-Content -Path 'C:\Program Files\Cloudbase Solutions\Cloudbase-Init\conf\cloudbase-init-unattend.conf' -Value $conf -Encoding ascii

Write-Host '== cleanup =='
Remove-Item $virtio, $cbi -Force -ErrorAction SilentlyContinue
# Trim the pagefile + temp for a smaller compressed image.
Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -ErrorAction SilentlyContinue

Write-Host 'provisioning complete'
