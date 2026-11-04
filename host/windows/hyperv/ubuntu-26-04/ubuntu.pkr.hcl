packer {
  required_plugins {
    hyperv = {
      source  = "github.com/hashicorp/hyperv"
      version = "= 1.1.5"
    }
  }
}

variable "vm_name" { type = string }
variable "switch_name" { type = string }
variable "cpus" { type = number }
variable "memory_mb" { type = number }
variable "disk_mb" { type = number }
variable "state_dir" { type = string }
variable "iso_path" { type = string }
variable "seed_path" { type = string }
variable "register_command" { type = string }
variable "complete_command" { type = string }
variable "headless" { type = bool }

source "hyperv-iso" "ubuntu" {
  vm_name                          = var.vm_name
  generation                       = 2
  switch_name                      = var.switch_name
  cpus                             = var.cpus
  memory                           = var.memory_mb
  disk_size                        = var.disk_mb
  enable_dynamic_memory            = false
  enable_secure_boot               = true
  secure_boot_template             = "MicrosoftUEFICertificateAuthority"
  enable_virtualization_extensions = false
  iso_url                          = var.iso_path
  iso_checksum                     = "sha256:cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927"
  secondary_iso_images             = [var.seed_path]
  temp_path                        = "${var.state_dir}/machines"
  output_directory                 = "${var.state_dir}/export"
  keep_registered                  = true
  # skip_export moves live disks and breaks the retained VM's disk attachments.
  skip_export       = false
  skip_compaction   = true
  headless          = var.headless
  first_boot_device = "DVD"
  boot_wait         = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall ds=nocloud ---<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]
  # Host provisioners use pinned OpenSSH identities; do not introduce an unpinned communicator.
  communicator     = "none"
  disable_shutdown = true
  shutdown_command = "true"
  shutdown_timeout = "5m"
}

build {
  sources = ["source.hyperv-iso.ubuntu"]
  provisioner "shell-local" {
    tempfile_extension = ".cmd"
    inline             = [var.register_command]
  }
  provisioner "shell-local" {
    tempfile_extension = ".cmd"
    inline             = [var.complete_command]
    timeout            = "60m"
  }
}
