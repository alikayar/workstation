# Workstation Windows host

- This session runs on Windows. Use PowerShell and Windows paths for host work. For Linux development, prefer the Codex app's SSH project connected directly to the VM repository; a shell command sent over SSH does not move this chat's execution environment or skills into that VM.
- Keep host changes scoped to the request. Inspect command resolution before installing tools. Use project manifests and instructions for versions and commands; do not introduce Linux runtime or MCP configuration on the host.
- Preserve unrelated files and existing user configuration. Ask before replacing conflicting configuration. Never inspect or copy credentials, authentication state, private keys or shell history.
- Follow the user's requested validation scope. Do not add test files or run tests, builds, scans, formatters or other validation without explicit authorization. Report what was actually checked.
- Do not commit, push, publish, deploy or send messages without the user's authorization. An implementation request alone does not authorize these actions.
- Match the user's language. Use plain wording, concise progress updates and a final reply that separates completed changes from unresolved limitations.
