# workstation-setup

Ansible playbook that provisions a fresh Linux machine and applies
[dotfiles](https://github.com/dominhtim/dotfiles) as its last step.

This is the "set up a brand new box" half: packages, zsh, docker, an SSH key
for GitHub, chezmoi. The dotfiles themselves — zsh, git, tmux and Neovim
config — live in that separate repo and know nothing about this one.

## Quick start

```bash
git clone git@github.com:dominhtim/workstation-setup.git ~/.workstation-setup
cd ~/.workstation-setup
./bootstrap.sh
```

You'll be asked for your sudo password once, and for your git name/email
once. Everything else is unattended, apart from pasting an SSH key into
GitHub partway through (see [GitHub SSH access](#github-ssh-access)).

Safe to re-run any time. Packages, oh-my-zsh and chezmoi are only touched
when missing; the dotfiles step pulls and applies whatever is new in the
dotfiles repo. Re-running after pushing a dotfiles change is a legitimate
way to sync a machine, not just a first-time step.

## Requirements

`bootstrap.sh` and the playbook each check their own preconditions up front
and stop with a specific message rather than failing partway through.

Before Ansible can run at all (`bootstrap.sh`):

- **A real terminal.** Don't pipe, redirect or background it — `visudo` and
  the SSH-key checkpoint both need to prompt.
- **`sudo` installed, and your user in a sudo group.** A default Debian
  install with a root password set has neither.
- **Python >= 3.12**, the floor for the pinned `ansible-core` 2.21. Debian 13
  and Ubuntu 24.04+ are fine; Debian 12 and Ubuntu 22.04 are not.

Before the machine is touched (`ansible/playbook.yml`):

- **Every base package resolves in the archives.** Anything missing is named
  up front, before the first change is made.
- **systemd is running.** Where it isn't — typically WSL without
  `systemd=true` in `/etc/wsl.conf` — enabling the docker service is skipped
  with a note instead of failing the run.

## What it does

1. Installs base packages: git, zsh, curl, tmux, neovim, fzf, ripgrep, unzip,
   xclip, openssh-client, nodejs, npm, build-essential, docker.io, Compose v2,
   docker-buildx, gh
2. Installs an upstream Neovim into `/opt` and links it into `/usr/local/bin`
   when the distro's is older than 0.11, which the dotfiles' LSP config needs
3. Adds you to the `docker` group, enables and starts the docker service
4. Generates `~/.ssh/id_ed25519` if absent and prints the public key
   immediately, so it can be added to GitHub while the slower steps run
5. Clones oh-my-zsh, powerlevel10k, zsh-autosuggestions, zsh-syntax-highlighting
6. Sets zsh as the default shell
7. Installs chezmoi and seeds its config with your git identity
8. Pauses — only if the dotfiles aren't cloned yet — for the SSH key
9. Clones and applies the dotfiles repo over SSH
10. Clones your project repos into `~/projects` (first run only)

## Configuration

Both live in `vars:` at the top of `ansible/playbook.yml`.

**Which dotfiles repo gets applied:**

```yaml
dotfiles_repo: "dominhtim/dotfiles"
```

`chezmoi init --ssh` expands this shorthand to
`git@github.com:dominhtim/dotfiles.git`. See `chezmoi init --help` for the
other forms it accepts (`user`, `user/repo`, `site/user/repo`).

**Which project repos get cloned:**

```yaml
project_repos:
  - git@github.com:dominhtim/TestProject.git
  - git@github.com:dominhtim/discord-bot.git
```

Each is cloned to `~/projects/<repo-name>`. This is a one-time clone, not a
sync: once a repo exists at that path, Ansible leaves it alone entirely on
every future run — no pulling, no overwriting, whatever you've changed or
left uncommitted. `git pull` yourself when you want upstream.

**Git identity** (`git_name`, `git_email`) is passed to chezmoi, which uses
it to render `~/.gitconfig`. Change these if you fork this repo.

## GitHub SSH access

The playbook generates an SSH key if you don't have one and prints the
public key right after packages install, well before the clone that needs
it — so you can add it at
[github.com/settings/keys](https://github.com/settings/keys) while
oh-my-zsh, the plugin clones and the chezmoi download run.

If that isn't enough time, the playbook pauses again immediately before the
clone and waits for Enter. Both the key generation and that pause are
skipped on every run after the dotfiles are cloned, so it doesn't become a
recurring interruption.

No token or password is stored in this repo. Adding the printed key to your
GitHub account is left manual on purpose — GitHub requires an authenticated
browser session for it.

## After the first run

1. **Log out and back in.** The `docker` group and the default-shell change
   only apply to a new login session. Until then `docker ps` still needs
   `sudo` — that's expected, not a bug. (`newgrp docker` works for the
   current shell if you'd rather not log out.)
2. `p10k configure` to set up the prompt.
3. Open `nvim` once and let lazy.nvim install the plugins.

To edit a dotfile from then on: `chezmoi edit ~/.zshrc`, then `chezmoi apply`.

## Troubleshooting

**`Timed out waiting for become success or become password prompt`** —
`Defaults use_pty` in `/etc/sudoers` blocks Ansible's sudo. `bootstrap.sh`
comments it out automatically; if that didn't take, run `sudo visudo` and
comment the line out by hand.

**A dotfile was edited by hand** — the playbook stops and names it rather
than letting `chezmoi apply` hit a prompt it has no terminal for. Keep the
edit with `chezmoi add <file>` (then commit it in the dotfiles repo), or
discard it with `chezmoi apply --force <file>`.

**A base package isn't in the archives** — the preflight names it before
anything is changed. Run `sudo apt update` in case the index is stale;
otherwise find the name this distro uses, or drop it from `base_packages`.

**Neovim was replaced and plugins misbehave** — run `:Lazy sync` once.

## Notes

`bootstrap.sh` pins `ansible-core` in a dedicated venv rather than using the
distro's. Docker comes from the distro's own `docker.io` packages rather
than Docker's third-party apt repo. Rationale for these and other design
decisions is in [CLAUDE.md](CLAUDE.md).
