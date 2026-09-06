# Getting started

Workstation targets an Ubuntu development environment. The machine needs
internet access and a user with `sudo` access.

## Install Ansible

Install Ansible and the Debian support library once:

```bash
sudo apt-get update
sudo apt-get install --yes ansible-core python3-debian
```

## Set your Git identity

Create the local host variables file and set the identity used by the managed
`.gitconfig`:

```bash
cp ansible/host_vars/localhost.example.yml ansible/host_vars/localhost.yml
nano ansible/host_vars/localhost.yml
```

## Apply the workstation configuration

Run the playbook from the repository root:

```bash
ansible-playbook ansible/site.yml --ask-become-pass
```

Preview changes without applying them:

```bash
ansible-playbook ansible/site.yml --check --diff --ask-become-pass
```

Apply only one part of the workstation when needed:

```bash
ansible-playbook ansible/site.yml --tags shell --ask-become-pass
ansible-playbook ansible/site.yml --tags docker --ask-become-pass
```

After Docker adds the user to its group, start a new terminal or run:

```bash
newgrp docker
```

