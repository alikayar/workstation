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
variable "answer_path" { type = string }
variable "host_command" { type = string }
variable "nested" { type = bool }
variable "headless" { type = bool }

source "hyperv-iso" "windows_pro" {
  vm_name                          = var.vm_name
  generation                       = 2
  switch_name                      = var.switch_name
  cpus                             = var.cpus
  memory                           = var.memory_mb
  disk_size                        = var.disk_mb
  enable_dynamic_memory            = false
  enable_secure_boot               = true
  secure_boot_template             = "MicrosoftWindows"
  enable_tpm                       = true
  enable_mac_spoofing              = false
  enable_virtualization_extensions = var.nested
  iso_url                          = var.iso_path
  iso_checksum                     = "sha256:d141f6030fed50f75e2b03e1eb2e53646c4b21e5386047cb860af5223f102a32"
  secondary_iso_images             = [var.answer_path]
  temp_path                        = "${var.state_dir}/machines"
  output_directory                 = "${var.state_dir}/export"
  keep_registered                  = true
  # Keep the registered VM's attached disks in place; skip_export moves them.
  skip_export       = false
  skip_compaction   = true
  communicator      = "none"
  headless          = var.headless
  first_boot_device = "DVD"
  boot_wait         = "1s"
  boot_command      = ["<spacebar><wait><spacebar><wait><spacebar><wait><spacebar>"]
  # The credential-owning parent verifies Setup through PowerShell Direct and shuts down normally.
  disable_shutdown = true
  shutdown_command = "true"
  shutdown_timeout = "5m"
}

build {
  sources = ["source.hyperv-iso.windows_pro"]
  provisioner "shell-local" {
    tempfile_extension = ".cmd"
    inline             = [var.host_command]
    timeout            = "60m"
  }
}
