# workstation-setup

Ansible playbook that provisions a fresh Linux machine and applies
[dotfiles](https://github.com/dominhtim/dotfiles) as its last step.

This is the "set up a brand new box" half. The dotfiles themselves — zsh,
git, tmux, Neovim config — live in that separate repo and know nothing
about this one. This repo just installs packages, sets up zsh, installs
chezmoi, and points it at that repo.

## Quick start

```bash
git clone <this-repo-url> ~/.workstation-setup
cd ~/.workstation-setup
./bootstrap.sh
```

You'll be asked for your sudo password once (package installs, setting
your default shell), then your git name/email once (used to fill in
`~/.gitconfig` via the dotfiles repo's chezmoi template — stored so you're
never asked again on this machine). Everything else is unattended.

Safe to re-run any time: package installs, oh-my-zsh, and the chezmoi
binary are only touched if missing; the dotfiles step always runs
`chezmoi update`, which pulls whatever's new in the dotfiles repo and
applies it. Re-running this after you've pushed a dotfiles change is a
legitimate way to sync a machine, not just a first-time setup step.

## What has to be true before you run it

Both entry points check their own preconditions and stop with a specific
message rather than failing somewhere in the middle.

`bootstrap.sh` checks what has to hold before Ansible can run at all:

- **A real terminal.** Don't pipe it, redirect it, or background it —
  `visudo` and the SSH-key checkpoint both need to prompt you.
- **`sudo` installed, and you in a sudo group.** A default Debian install
  with a root password set does neither, and Ansible can't warn about it
  itself — `become` would fail on the playbook's first task.
- **Python >= 3.12**, the floor for the pinned `ansible-core` 2.21 (see
  below). Debian 13 and Ubuntu 24.04+ are fine; Debian 12 and Ubuntu 22.04
  are not.

`ansible/playbook.yml` then checks the machine it's about to provision,
before its first task changes anything:

- **Every base package resolves in the archives.** They install as one
  unit, so a single missing name would otherwise take the whole task down
  with an apt error that doesn't say which name was at fault. Names are
  less portable between Debian and Ubuntu than they look: Compose v2 is
  `docker-compose` on Debian 13 and `docker-compose-v2` on Ubuntu, and
  neither distro has the other's name. The playbook picks the right one by
  distribution; anything else that turns up missing gets named here.
- **systemd is what's running.** Where it isn't — Debian or Ubuntu under
  WSL without `systemd=true` in `/etc/wsl.conf` — enabling the docker
  service is skipped with a note instead of failing the run.

## What it does (`ansible/playbook.yml`)

1. Installs base packages (git, zsh, curl, tmux, neovim, fzf, ripgrep, unzip,
   xclip, openssh-client, nodejs, npm, build-essential, docker.io,
   docker-compose-v2, docker-buildx, gh)
2. Adds you to the `docker` group and enables/starts the docker service
3. Generates an SSH key for GitHub if you don't already have one, and
   prints the public key immediately — right after packages, before the
   slower steps below, so you have time to add it to GitHub while they run
4. Clones oh-my-zsh + powerlevel10k + zsh-autosuggestions + zsh-syntax-highlighting
5. Sets zsh as the default shell
6. Installs chezmoi (plain binary from its GitHub releases, no curl\|sh installer)
7. Seeds chezmoi's config with your git identity, so its own interactive
   prompt never fires — Ansible tasks don't have a real TTY for that prompt
   to work through anyway
8. Pauses, only if the dotfiles haven't been cloned yet, to give you one
   more chance to add the SSH key before it's actually needed
9. `chezmoi init --ssh` (first run only) + `chezmoi update` (every run) to
   pull and apply the dotfiles repo over SSH
10. Clones your project repos into `~/projects` (first run only — see
    below for details)

## Changing which dotfiles repo gets applied

```yaml
vars:
  dotfiles_repo: "dominhtim/dotfiles"
```

near the top of `ansible/playbook.yml`. Change this if you fork either
repo or use a different GitHub account. `chezmoi init --ssh` expands this
shorthand to `git@github.com:dominhtim/dotfiles.git` — see `chezmoi init
--help` for the exact patterns it recognizes (bare `user`, `user/repo`,
`site/user/repo`, and a couple of sourcehut-specific ones).

## Changing which project repos get cloned

```yaml
vars:
  project_repos:
    - git@github.com:dominhtim/TestProject.git
    - git@github.com:dominhtim/discord-bot.git
```

near the top of `ansible/playbook.yml`, alongside `dotfiles_repo`. Add or
remove lines here for whichever repos you want. Each one is cloned into
`~/projects/<repo-name>` (the name is derived from the URL, so
`TestProject.git` becomes `~/projects/TestProject`).

This is a one-time clone, not a sync: once a repo exists at that path,
Ansible leaves it alone completely on every future run — no pulling, no
overwriting, regardless of what you've committed, changed, or left
uncommitted in there. These are meant to be your actual working copies.
If you want the latest from upstream, `cd` in and `git pull` yourself,
same as you would on any machine.

## Why Ansible instead of a bash install.sh

A hand-rolled script doing the same job needs manual `[ -d ... ]` checks
before every clone to avoid re-cloning, bash conditionals for "does this
package manager exist," and a hand-rolled backup step for anything it
might overwrite. Ansible's modules (`package`, `git`, `user`, `file`)
already know how to check current state and do nothing when nothing needs
to change — that's what "idempotent" means for a module, not something you
hand-code per step. It also ends up reading like a checklist of *what* the
machine needs rather than a script describing *how* to check for it.

## Why ansible-core is pinned at all, and why the pin moved to 2.21

`bootstrap.sh` doesn't use whatever `ansible-core` your distro's package
manager ships — it creates a dedicated venv at `~/.workstation-setup-venv`
and installs `ansible-core==2.21.*` into it specifically. A dedicated venv
means the automation runs against a version this repo chose, not one a
distro upgrade picked for you.

The pin used to be `2.17.*`, because `become` (sudo) negotiation hung with
`Timed out waiting for become success or become password prompt` — even
with a correct password, regardless of how it was supplied (`-K`, a
variable, made no difference). Every layer underneath Ansible was tested
individually (sudo directly, sudo with stdin piped, sudo with stdin *and*
stdout *and* stderr redirected away from any terminal) and all worked, so
the cause was read as a regression in `ansible-core` 2.19+ — 2.17 worked,
2.20 hung.

Re-tested on 2026-08-24 against a minimal `become` playbook: **2.20.0,
2.20.8 and 2.21.3 all pass**, including the 2.20 that was originally
called broken. So the diagnosis above was misattributed. The real cause
was almost certainly `Defaults use_pty` in `/etc/sudoers` — the classic
source of that exact timeout — which `bootstrap.sh` now detects and
comments out itself before running the playbook. The version was never
the problem.

One caveat on that re-test: it ran on a machine already past both hurdles
(`use_pty` disabled, passwordless sudo in place), so it can't speak for
the very first bootstrap of a genuinely fresh machine. That path is the
one still unverified against 2.21. If it hangs there, set
`ANSIBLE_VERSION` near the top of `bootstrap.sh` back to `"2.17.*"` — the
script checks the venv's installed version against the pin on every run
and recreates `~/.workstation-setup-venv` automatically on a mismatch, so
no manual deletion is needed either way.

## GitHub SSH access

The playbook generates an SSH key (`~/.ssh/id_ed25519`, no passphrase —
protected by the machine's disk like any other local key) if one doesn't
already exist, and prints the public key right after packages install —
well before the dotfiles clone that needs it, so you have the slower steps
(oh-my-zsh, plugin clones, downloading chezmoi) running in the background
while you go add it.

If that isn't enough time, there's a second checkpoint: right before the
actual clone, the playbook pauses and waits for you to press Enter — but
only if the dotfiles haven't been cloned successfully yet. Once they have,
every future run skips both the key generation and this pause entirely,
so this doesn't turn into a recurring interruption.

No token or password is ever stored anywhere in this repo, deliberately.
Adding the printed public key to your GitHub account
(github.com/settings/keys) is the one step left undone on purpose — that's
GitHub requiring proof you own the account through an authenticated
browser session, not a gap in the automation.

## Docker

Installed via Ubuntu's own `docker.io` + `docker-compose-v2` +
`docker-buildx` packages (simpler than adding Docker's official
third-party apt repo, and current enough for personal use — 29.x at time
of writing on 24.04). The playbook also adds you to the `docker` group
and enables/starts the service.

One thing that can't be automated away: **group membership doesn't apply
to your already-running shell session** — same as the zsh default-shell
change elsewhere in this playbook. You need to log out and back in (or run
`newgrp docker` in your current shell) before `docker run` works without
`sudo`. Running the playbook itself doesn't put you in a new session, so
don't be surprised if `docker ps` still asks for `sudo` immediately
afterward — that's expected, not a bug.

## Adding a second machine

Since this only targets `localhost`, adding a real inventory (multiple
hosts, `hosts:` other than `localhost`, an actual `inventory.ini`) is the
natural next step once you've got more than one box to provision this way
— nothing here currently assumes single-machine-only, it's just not built
out yet.
