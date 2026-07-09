# Windows 11 Enterprise (Evaluation) image build (Track A3, approach A).
#
# Real Windows 11 hardware requirements are satisfied, not bypassed:
#   UEFI          — OVMF firmware, efi_boot
#   Secure Boot   — q35 + smm=on + OVMF_CODE_4M.secboot.fd +
#                   OVMF_VARS_4M.ms.fd (Microsoft keys enrolled) +
#                   -global cfi.pflash01 secure=on
#   TPM 2.0       — vtpm=true (plugin runs swtpm) + tpm-tis device
# so the published image boots on a compliant Win11 xCompute VM.
#
# Build VM uses SATA (inbox AHCI) + e1000 (inbox) so Setup needs no
# third-party drivers; virtio + guest agent + Cloudbase-Init are added
# by the provisioner, then sysprep /generalize.

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = ">= 1.1.0"
    }
  }
}

variable "iso_url" {
  type    = string
  # Windows 11 Enterprise Evaluation (24H2, en-us, x64) — go.microsoft.com fwlink.
  default = "https://go.microsoft.com/fwlink/?linkid=2289031"
}

# TODO: pin after the first successful run logs the real hash.
variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "output_dir" {
  type    = string
  default = "output"
}

# Absolute path to the virtio-win ISO, attached as an extra CD so
# Windows Setup can load the virtio-blk (viostor) boot driver.
variable "virtio_iso" {
  type    = string
  default = ""
}

# Absolute path to the Windows install ISO — attached on its own AHCI
# controller with bootindex=0 so OVMF boots it. The Packer QEMU builder
# in EFI mode gives the install ISO no boot priority, so OVMF otherwise
# falls through to PXE/floppy and reports "no bootable device".
variable "boot_iso" {
  type    = string
  default = ""
}

# Absolute path to a WRITABLE per-build copy of OVMF_VARS_4M.ms.fd
# (Microsoft Secure Boot keys enrolled). Because qemuargs below fully
# override the plugin's firmware handling, the OVMF pflash pair is passed
# by hand and the vars store must be writable, so the workflow copies the
# read-only distro vars file to this path before each build.
variable "ovmf_vars" {
  type    = string
  default = ""
}

source "qemu" "win11" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  accelerator = "kvm"
  headless    = true
  # Pin VNC (display :99 -> port 5999) so CI can screenshot the guest.
  vnc_bind_address = "127.0.0.1"
  vnc_port_min     = 5999
  vnc_port_max     = 5999
  vnc_use_password = false
  # q35 + smm required for Secure Boot; smm appended to the machine type.
  machine_type = "q35,smm=on"
  cpus         = 2
  memory       = 6144
  disk_size    = "64G"
  format       = "qcow2"

  # q35 has no legacy IDE/floppy and QEMU has no `if=sata` bus, so the
  # boot disk is virtio-blk; its viostor driver is injected into Setup
  # from the virtio-win ISO (see autounattend windowsPE + qemuargs). The
  # deployed image is virtio-native as a result. NIC stays e1000 (inbox)
  # for the build; NetKVM is added by the provisioner.
  disk_interface   = "virtio"
  net_device       = "e1000"
  output_directory = var.output_dir
  vm_name          = "win11.qcow2"

  # UEFI + Secure Boot firmware is attached by hand in qemuargs below (the
  # plugin's efi_boot is ignored once qemuargs overrides the command line,
  # which silently left the VM on SeaBIOS). Do NOT set efi_boot here.

  # TPM 2.0 (plugin launches swtpm; requires swtpm on the runner).
  vtpm            = true
  tpm_device_type = "tpm-tis"

  # autounattend.xml rides on an extra CD; WinPE scans all drive roots.
  cd_files  = ["autounattend.xml"]
  boot_wait = "5s"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = "xToolsBuild2026!"
  winrm_timeout  = "1h30m"
  winrm_use_ssl  = false

  # Sysprep runs in the provisioner; just power off cleanly.
  shutdown_command = "shutdown /s /t 15 /f /c \"packer\""
  shutdown_timeout = "30m"

  qemuargs = [
    ["-cpu", "host"],
    # UEFI + Secure Boot firmware (secboot CODE + MS-keys VARS). Passed by
    # hand because qemuargs override the plugin's own EFI wiring; without
    # this QEMU silently falls back to SeaBIOS and Win11 refuses to install.
    ["-drive", "if=pflash,unit=0,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd"],
    ["-drive", "if=pflash,unit=1,format=raw,file=${var.ovmf_vars}"],
    # Protect the Secure Boot variable store (pairs with smm=on).
    ["-global", "driver=cfi.pflash01,property=secure,value=on"],
    # virtio-win ISO so WinPE can load the viostor boot driver.
    ["-drive", "file=${var.virtio_iso},media=cdrom"],
    # Install ISO on a dedicated AHCI controller with bootindex=0 so
    # OVMF actually boots it (Packer's EFI mode sets no boot priority).
    ["-device", "ahci,id=bootahci"],
    ["-drive", "id=bootcd,if=none,media=cdrom,file=${var.boot_iso}"],
    ["-device", "ide-cd,drive=bootcd,bus=bootahci.0,bootindex=0"],
    # TPM 2.0 FRONTEND. vtpm=true launches swtpm and adds the -tpmdev/
    # -chardev backend, but the qemuargs override drops the plugin's
    # `-device tpm-tis`, so the guest saw no TPM and Win11 Setup failed the
    # requirements check. Attach it by hand to the plugin's tpm0 backend.
    ["-device", "tpm-tis,tpmdev=tpm0"],
  ]
}

build {
  sources = ["source.qemu.win11"]

  provisioner "powershell" {
    script = "provision.ps1"
  }
}
