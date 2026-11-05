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
variable "state_dir" { type = string }
variable "iso_path" { type = string }
variable "seed_path" { type = string }
variable "host_command" { type = string }
variable "headless" { type = bool }
source "hyperv-iso" "base" {
  vm_name                          = var.vm_name
  generation                       = 2
  switch_name                      = var.switch_name
  cpus                             = 2
  memory                           = 4096
  enable_dynamic_memory            = false
  enable_secure_boot               = true
  enable_mac_spoofing              = false
  enable_virtualization_extensions = false
  iso_url                          = var.iso_path
  secondary_iso_images             = [var.seed_path]
  temp_path                        = "${var.state_dir}/machines"
  output_directory                 = "${var.state_dir}/export"
  keep_registered                  = true
  skip_export                      = true
  skip_compaction                  = true
  communicator                     = "none"
  headless                         = var.headless
  first_boot_device                = "DVD"
  disable_shutdown                 = true
  shutdown_command                 = "true"
  shutdown_timeout                 = "5m"
  disk_size                        = 40960
  enable_tpm                       = false
  secure_boot_template             = "MicrosoftUEFICertificateAuthority"
  iso_checksum                     = "sha256:cc8a95cde20f6ced61a322420de00f10cc3c90ced545daa46cb9c1a117f1d927"
  boot_wait                        = "5s"
  boot_command                     = ["c<wait>", "linux /casper/vmlinuz autoinstall ds=nocloud ---<enter>", "initrd /casper/initrd<enter>", "boot<enter>"]
}
build {
  sources = ["source.hyperv-iso.base"]
  provisioner "shell-local" {
    tempfile_extension = ".cmd"
    inline             = [var.host_command]
    timeout            = "90m"
  }
}
