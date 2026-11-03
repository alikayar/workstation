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
variable "host_address" { type = string }
variable "http_port" { type = number }
variable "cpus" { type = number }
variable "memory_mb" { type = number }
variable "disk_mb" { type = number }
variable "state_dir" { type = string }
variable "username" { type = string }
variable "public_key" { type = string }
variable "bootstrap_public_key" { type = string }
variable "bootstrap_private_key" {
  type      = string
  sensitive = true
}
variable "bootstrap_id" { type = string }
variable "revision" { type = string }
variable "payload_dir" { type = string }

source "hyperv-iso" "ubuntu" {
  vm_name                         = var.vm_name
  generation                      = 2
  switch_name                     = var.switch_name
  cpus                            = var.cpus
  memory                          = var.memory_mb
  disk_size                       = var.disk_mb
  enable_dynamic_memory           = false
  enable_secure_boot              = true
  secure_boot_template            = "MicrosoftUEFICertificateAuthority"
  iso_url                         = "https://releases.ubuntu.com/24.04/ubuntu-24.04.5-live-server-amd64.iso"
  iso_checksum                    = "sha256:97f3d7ffb032c3eb3b23d2c8be9cc76e60c2c1f2c0146ba5ba9fe01cafae0fd8"
  temp_path                       = "${var.state_dir}/machines"
  output_directory                = "${var.state_dir}/output"
  keep_registered                 = true
  # skip_export moves the original disks; keep the registered VM paths intact.
  skip_export                     = false
  skip_compaction                 = true
  http_bind_address               = var.host_address
  http_port_min                   = var.http_port
  http_port_max                   = var.http_port
  http_content = {
    "/meta-data" = "instance-id: ${var.vm_name}\n"
    "/user-data" = "#cloud-config\n${yamlencode({
      autoinstall = {
        version = 1
        refresh-installer = { update = false }
        locale = "en_US.UTF-8"
        keyboard = { layout = "us" }
        identity = { hostname = var.vm_name, username = var.username, password = "!" }
        ssh = { install-server = true, allow-pw = false, authorized-keys = [var.public_key, var.bootstrap_public_key] }
        storage = { layout = { name = "direct" } }
        packages = ["git", "ansible-core", "python3-debian", "sudo", "linux-cloud-tools-virtual"]
        late-commands = [
          "printf '${var.username} ALL=(ALL) NOPASSWD:ALL\\n' > /target/etc/sudoers.d/90-workstation",
          "chmod 440 /target/etc/sudoers.d/90-workstation",
          "printf '${var.bootstrap_id}\\n' > /target/etc/workstation-bootstrap-id"
        ]
      }
    })}"
  }
  boot_wait = "5s"
  boot_command = [
    "c<wait>",
    "linux /casper/vmlinuz autoinstall 'ds=nocloud-net;s=http://${var.host_address}:${var.http_port}/' ---<enter>",
    "initrd /casper/initrd<enter>",
    "boot<enter>"
  ]
  ssh_username         = var.username
  ssh_private_key_file = var.bootstrap_private_key
  ssh_timeout          = "45m"
  shutdown_command     = "sudo shutdown -P now"
  shutdown_timeout     = "5m"
}

build {
  sources = ["source.hyperv-iso.ubuntu"]
  provisioner "shell" {
    inline = [
      "echo SSH_HOST_FINGERPRINT_FOR_FIRST_CONNECTION:",
      "ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub",
      "mkdir -p ~/.local/state/workstation-bootstrap/${var.bootstrap_id}"
    ]
  }
  provisioner "file" {
    source      = "${var.payload_dir}/"
    destination = ".local/state/workstation-bootstrap/${var.bootstrap_id}"
  }
  provisioner "shell" {
    inline = ["sh ~/.local/state/workstation-bootstrap/${var.bootstrap_id}/provision-workstation.sh ${var.bootstrap_id} ${var.revision}"]
  }
}
