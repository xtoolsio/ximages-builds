# Windows Server 2025 Evaluation image build (Track A3).
#
# QEMU/KVM on the CI runner: unattended install from the Microsoft
# evaluation ISO (autounattend.xml on a secondary CD), then WinRM
# provisioning (virtio drivers, QEMU guest agent, Cloudbase-Init),
# then sysprep /generalize as the shutdown command.
#
# The build VM deliberately uses SATA + e1000 (Windows inbox drivers,
# nothing to inject during Setup); the provisioner installs the virtio
# driver suite so deployed VMs run fully paravirtualized.

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
  default = "https://go.microsoft.com/fwlink/?linkid=2195333&clcid=0x409&culture=en-us&country=us"
}

# TODO: pin after the first successful CI run logs the real hash —
# Microsoft's evaluation fwlink serves a stable ISO but publishes its
# hash only on the Evaluation Center page.
variable "iso_checksum" {
  type    = string
  default = "none"
}

variable "output_dir" {
  type    = string
  default = "output"
}

source "qemu" "ws2022" {
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  accelerator  = "kvm"
  headless     = true
  cpus         = 2
  memory       = 4096
  disk_size    = "40G"
  format       = "qcow2"

  # Inbox-driver hardware for the build; virtio comes via provisioner.
  # (ide, not sata: packer maps disk_interface to qemu's `-drive if=`,
  # which accepts ide/scsi/virtio on the pc machine, not sata.)
  disk_interface   = "ide"
  net_device       = "e1000"
  output_directory = var.output_dir
  vm_name          = "ws2022.qcow2"

  # autounattend.xml rides on an extra CD; WinPE scans all drive roots.
  cd_files = ["autounattend.xml"]

  # BIOS boots the install CD directly on an empty disk.
  boot_wait = "3s"

  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = "xToolsBuild2026!"
  winrm_timeout  = "3h30m"
  winrm_use_ssl  = false

  # Sysprep already ran (generalize) in the provisioner; just power
  # off cleanly to preserve the generalized state.
  shutdown_command = "shutdown /s /t 15 /f /c \"packer\""
  shutdown_timeout = "30m"

  qemuargs = [
    ["-cpu", "host"],
  ]
}

build {
  sources = ["source.qemu.ws2022"]

  provisioner "powershell" {
    script = "provision.ps1"
  }
}
