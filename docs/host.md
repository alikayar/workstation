# Connect from the host

The host is the computer where you use the desktop app, terminal and browser. The Ubuntu VM holds the repositories and runs agent commands. This guide covers the connection between them; [Ubuntu setup](getting-started.md) covers installation inside the VM.

## Choose where the VM runs

| | Local VM | Remote VM |
| --- | --- | --- |
| Where Ubuntu runs | In VM software on your computer | On another machine or a hosting provider |
| What the host needs | Desktop app, SSH client, browser and VM software | Desktop app, SSH client and browser; VPN access if required |
| SSH destination | Guest IP, or a host port forwarded to the guest's SSH port | The VM's reachable DNS name or IP |
| Availability | Depends on the host and VM staying awake | Depends on the remote machine and network remaining available |

Use the VM software or provider you already operate. Workstation does not create VMs, install host applications or configure their networking. For WSL 2, follow the [WSL notes](getting-started.md#wsl-2); a working WSL terminal alone does not establish an SSH connection from the desktop app.

## Prepare access to Ubuntu

Inside Ubuntu, create or use a non-root development account with sudo access. Enable an SSH server if the image does not already provide one; Ubuntu documents installation and key setup in its [OpenSSH guide](https://ubuntu.com/server/docs/how-to/security/openssh-server/). The Workstation playbook does not install or configure the SSH server.

Authorize your host's public key for that account using your VM console or provider's key setup. Keep the private key on the host. Verify the server's host-key fingerprint through the VM console or provider before accepting the first connection.

For a local VM using NAT, configure a host port such as `127.0.0.1:2222` to forward to the guest's SSH port `22`. If the host can reach the guest IP directly, no NAT port mapping is needed. For a remote VM, use its reachable address and the provider's SSH port; allow access through the intended network or VPN.

## Add a host-side SSH alias

Edit the SSH client configuration belonging to the user running the desktop app. This is usually `~/.ssh/config`; with Windows OpenSSH it is `%USERPROFILE%\.ssh\config`. Add a concrete alias while preserving existing entries:

```sshconfig
Host workstation
    HostName ubuntu-vm.example.com
    User dev
    Port 22
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
    ForwardAgent no
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

Replace the example address, username, port and identity path with your own. For the local NAT example, use `HostName 127.0.0.1` and `Port 2222`. Keep machine-specific values in the host's SSH config, outside this repository. See the [OpenSSH configuration reference](https://man.openbsd.org/ssh_config) for these options.

From the **host terminal**, connect with:

```sh
ssh workstation
```

This should open a shell as the development user inside Ubuntu. Complete this connection before configuring the desktop app.

## Prepare the VM and connect the app

In the **VM shell**, clone Workstation and follow the [Ubuntu setup guide](getting-started.md). Keep application repositories on the VM's Linux filesystem, for example under `~/projects/`. Reconnect after setup so the new login shell and environment take effect.

Authenticate Codex in the VM using its supported sign-in flow. The playbook installs the CLI and configuration but does not provision account credentials. SSH access and authentication to Git hosting are separate as well; configure repository access for the VM without copying the host's private keys.

In the desktop app, open **Settings → Connections**, add or enable the SSH alias, and select a project folder inside the VM, such as `/home/dev/projects/my-project`. The app uses SSH to start the remote Codex app server through the remote user's login shell. Follow the [official remote connection guide](https://learn.chatgpt.com/docs/remote-connections#connect-to-an-ssh-host) for the current app flow.

The selected folder and commands belong to the VM. Host filesystem paths and host-only applications are not automatically available there. The remote app server travels over SSH; it does not need a separately exposed public port.

## Preview an application

Start the application's development server **inside the VM** using its own project instructions. Note its actual port. For a server listening on the VM's `127.0.0.1:4321`, open a separate **host terminal** and run:

```sh
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:4321:127.0.0.1:4321 workstation
```

Open `http://127.0.0.1:4321` in the host browser. The first address and port belong to the host; the second are reached from inside the VM. Substitute the application's port. If host port `4321` is occupied, use `127.0.0.1:14321:127.0.0.1:4321` and browse to port `14321`.

Keep that terminal open while previewing. Ctrl+C closes the tunnel without stopping the application in the VM. A containerized application must first publish its port to the VM, preferably on loopback. See [OpenSSH local forwarding](https://man.openbsd.org/ssh#L) for the command's behavior.

## Daily use and connection problems

Connect to the same VM and project folder when returning to work. For terminal processes that need to survive an SSH disconnect, use the existing [tmux workflow](shell.md#productivity-shortcuts). A VM shutdown still stops its processes.

| Symptom | Where to look |
| --- | --- |
| SSH times out or is refused | VM power state, address, SSH server, NAT mapping and network access |
| SSH reports a changed host key | Verify whether the VM was rebuilt before updating the host's known-host entry |
| Permission denied | Development username and the public key authorized for that account |
| Terminal SSH works but the app cannot connect | The app user's SSH config, access to the selected key and the VM's Codex sign-in |
| Agent cannot find a runtime | VM [PATH and version inspection](getting-started.md#inspect-the-agent-environment); reconnect after environment changes |
| Browser preview does not load | Application listener in the VM, actual port and the running SSH tunnel |

Host replacement requires setting up the app and SSH access again. When the VM is remote and remains available, its repositories and installed toolchains stay in place. A local VM must be moved or recreated separately when replacing the computer that runs it.
