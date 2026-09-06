# WORKSTATION

To me, the best development setup is a dedicated Ubuntu virtual machine running on your computer.

I like this setup because it:

- Keeps the host machine clean instead of filling it with programming languages, packages, and development tools
- Reduces the host's exposure and blast radius when running development code
- Runs all of the commands natively on Linux, regardless of the host
- Tracks resources like CPU, memory, and disk to see performance better

## The Problems With This Setup

I spend a lot of time building my development environment.

I configure my shell, Git, personalize the terminal, install some packages, and add CLI tools.

But when time passes, I forget even which tools I've installed.

And whenever I replace my computer or have problems with the VM, I have to reconfigure everything.

So I wanted it to be reusable, idempotent, stable, and version-controlled instead of relying on my memory.

## How Workstation Fixes This

Workstation uses Ansible to apply configurations and commands while preserving idempotency.

The process is very simple:

```text
Ubuntu VM
    ↓
Run Ansible playbook
    ↓
Everything is ready
```

Ansible is a good fit here because playbooks and roles are easier to manage than shell scripts. The tasks are designed to be idempotent, so re-running the playbook should converge on the same workstation state.

## Getting started

Follow the [getting started guide](docs/getting-started.md) for prerequisites,
Git identity setup, previewing changes, and applying the playbook.

## Documentation

See [docs/tools.md](docs/tools.md) for the managed tool inventory and the
reason each tool belongs in the workstation. Design and policy notes for the
more complex parts live in [docs/shell.md](docs/shell.md),
[docs/mise.md](docs/mise.md), and [docs/codex.md](docs/codex.md).

## Contributions

I am not actively looking for any contributions.

This repository represents a personal development environment. I like to share my dotfiles and my current setup.

If something here is useful to you, feel free to use it as a reference or fork it for your own setup.

Also, I'm open to suggestions all the time via Issues.
