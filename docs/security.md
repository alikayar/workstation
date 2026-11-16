# Security boundaries and exposure

Workstation places development execution inside Ubuntu and keeps host connectivity explicit. It is a development baseline, not a guarantee that untrusted code cannot reach the host or other systems. Distinguish the hypervisor/network boundary, the development user's authority and the host application's own permissions.

## Controls and limits

| Surface | Implemented control | Limit |
| --- | --- | --- |
| Managed Hyper-V Ubuntu guest | Host-side extended ACLs and adapter guards, journaled and checked by wvm | Shared layer 2, allowed Internet access, topology changes and hypervisor flaws remain relevant; existing VMs outside this workflow are not isolated automatically |
| SSH access | Host-held client key and pinned bootstrap server identity in the managed workflow; agent forwarding disabled | SSH authorizes a channel into the guest; application bridges and forwarded ports need their own review |
| Ubuntu Codex | Task instructions and destructive-command rules | The managed sandbox is `danger-full-access`; instructions are not an OS access-control boundary |
| Host Codex | Reviewed user defaults and permission-profile preservation | Active profile/policy and host tools determine actual access; setup does not prove current sandbox enforcement |
| VS Code appearance | Static local JSON/images without extension runtime entry points | VS Code, Remote SSH, other extensions, image parsers and update channels remain in the trusted computing base |
| Chrome | Managed root-owned executable, isolated profile, task context/page ownership and namespace policy | Contexts are not VM isolation; the AppArmor policy grants user namespaces rather than confining filesystem/network access |
| Tool downloads | Reviewed pins; checksums/signatures where implemented | Not every dependency is transitively locked; pins do not establish that a package is harmless |

The detailed [Hyper-V policy](windows.md#network-isolation), [browser boundary](browser.md#security-boundary), [editor setup](vscode.md) and [Codex ownership](codex.md) remain authoritative for their components. The [verification guide](verification.md) separates local test evidence from unexecuted scenarios.

## Host applications and remote execution

Opening a repository as an SSH project puts project commands inside the guest. The host desktop application still runs with host privileges. Workstation does not sandbox Windows VS Code to its installation directory, install an application container around it or disable every remote-extension API bridge. A remote extension cannot be treated as having zero host impact merely because its process runs in Ubuntu. Local and remote extensions, links, clipboard workflows, file-opening actions and forwarded application content remain inputs to the host client.

Using the bundled appearance removes the need for upstream theme/icon runtime packages only after those packages are explicitly removed. Setup warns but does not uninstall them. It does not impose an extension allowlist or remove unrelated host extensions. See the [appearance procedure](vscode.md#extensions-and-appearance).

For Codex, the repository configures the existing host app and the Ubuntu CLI separately. It does not assert that a remote desktop connection eliminates every host-facing capability. Select the actual SSH project for guest work; a host chat issuing an SSH command still retains its host context and tools. Avoid treating UI location or a configuration file as proof of the execution boundary.

Keep private host keys and personal browser profiles on the host. Do not expose shared host folders, forwarded SSH agents, Docker sockets or broadly bound preview ports to untrusted guest workloads without an explicit need. The [host guide](host.md#preview-an-application) shows a loopback-only preview tunnel. Basic VMConnect avoids the resource redirection offered by enhanced Windows sessions; guest network policy remains a separate concern.

## Ubuntu server baseline

The [security role](../ansible/roles/security/tasks/main.yml) is enabled by default through `workstation_security_enabled: true`. Full direct Ansible applies and the confirmed Windows Ubuntu development scope include it. It requires systemd and installs OpenSSH, UFW, AppArmor, unattended security upgrades and password-quality enforcement. It locks root password login, grants the development account sudo membership, configures key-only SSH for that account, disables agent/X11 forwarding, permits local TCP forwarding, opens TCP/22 in UFW and enables the firewall. Security updates do not automatically reboot the machine.

This role changes access policy. Before applying it, establish working public-key access for the intended account, confirm SSH is on port 22, and keep a console/recovery route available. A custom SSH port, additional users or additional inbound services need a reviewed configuration change; the role does not infer those exceptions. Do not run it over your only password-authenticated session and assume you can reconnect.

To reapply only this baseline from the Ubuntu checkout:

```sh
ansible-playbook ansible/site.yml --tags security --ask-become-pass
```

Set `workstation_security_enabled: false` in ignored host variables or deliberately skip the `security` tag to omit this role. This skips future management; it does not undo a previously applied policy. The role checks selected effective SSH settings after applying, but it does not prove a new remote connection works. Keep the existing session open until a separately opened connection succeeds. The role does not provide the host-enforced Hyper-V policy, restrict outbound Internet traffic or isolate Docker-published services. Guest-root processes can alter guest-side controls. The Windows Ubuntu workflow also has its own guest/bootstrap setup. Declining the Workstation development setup skips this Ansible role; the guest bootstrap and host-side network policy remain separate.

## Privilege, data and maintenance

The default Docker group grants root-equivalent control inside Ubuntu. `docker_add_user_to_group: false` prevents the role from adding membership; it does not remove membership already granted. The role still installs and starts Docker. VM Codex's full filesystem access includes the development account's reachable files, and available sudo/Docker authority can widen its practical reach.

Graphify caches describe indexed source. Semantic documentation indexing sends selected documents to the existing Codex model service; structure-only indexing avoids that model step. Browser captures, protocol logs, traces and audit reports can contain application data. Store them under project-approved private artifact locations and review before publication. Filename exclusions and read-only tool modes are not secret-content scanners.

Updates are reviewed through the [maintenance workflow](maintenance.md); Renovate proposals do not apply changes to machines. Omitted/retired tools are not uninstalled automatically. Removing an old MCP registration does not erase its cache or stop an already running session. Any cleanup of private state is a separate, scoped action. On suspected compromise, preserve relevant state, stop using the affected environment for sensitive work and choose an explicit recovery scope rather than blindly rerunning provisioning.
