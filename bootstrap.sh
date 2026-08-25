#!/usr/bin/env bash
# Entry point for a brand new machine. All it does is make sure a working
# Ansible exists, then hand off — every actual provisioning step (packages,
# oh-my-zsh, chezmoi, applying dotfiles) lives in ansible/playbook.yml.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/.workstation-setup-venv"

# Still pinned in its own venv rather than trusting whatever a distro
# package manager ships — but the pin is no longer 2.17. This used to sit
# at 2.17.* because `become` (sudo) negotiation hung with "Timed out
# waiting for become success or become password prompt" on 2.19+ and the
# cause was read as an ansible-core regression. Re-tested 2026-08-24:
# 2.20.0, 2.20.8 and 2.21.3 all run `become` fine here, including 2.20 —
# the version originally called broken. The real cause was almost
# certainly `Defaults use_pty` in /etc/sudoers, the classic source of that
# exact timeout, which this script now comments out itself further down.
# Caveat: that re-test ran on a machine already past both hurdles (use_pty
# disabled, NOPASSWD in place), so the very first bootstrap of a truly
# fresh machine is the one path still unverified against 2.21. If it hangs
# there, drop this back to "2.17.*" — the venv is recreated automatically
# on a version mismatch, so that costs nothing but a re-run.
ANSIBLE_VERSION="2.21.*"
# The glob's fixed prefix (e.g. "2.21." from "2.21.*") — used to check an
# already-installed version against the pin below.
ANSIBLE_VERSION_PREFIX="${ANSIBLE_VERSION%\**}"
# ansible-core's own floor for the controller: 2.21 needs >= 3.12 (2.17
# only needed >= 3.10). Checked in preflight below purely so the failure
# reads as "your Python is too old for the pin" instead of a wall of pip
# resolver output. Keep this in step with ANSIBLE_VERSION.
ANSIBLE_MIN_PYTHON="3.12"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------
# Only the things that must hold before Ansible can run at all live here.
# Anything about the machine being provisioned belongs in the playbook's
# own preflight instead — see the top of ansible/playbook.yml.

# visudo (below) and the playbook's `pause` before the dotfiles clone both
# need a real terminal to talk to. Failing here beats hanging on invisible
# prompts halfway through a provision.
if [ ! -t 0 ]; then
  die "No terminal attached to stdin. Run this script directly in a terminal — not piped, redirected, or backgrounded (it needs to prompt for sudo and, later, for you to add an SSH key to GitHub)."
fi

# A default Debian install with a root password set installs no sudo at
# all and leaves your user out of the sudo group. Ansible can't warn about
# this itself: `become` fails on the playbook's very first task, long after
# this script has already used sudo.
if ! command -v sudo >/dev/null 2>&1; then
  die "sudo isn't installed. As root: 'apt install sudo && usermod -aG sudo $USER' (or the equivalent for your distro), then log out and back in and re-run this."
fi
# Deliberately never prompts: every probe here is either -n (fail rather
# than ask) or a pure group lookup. A check that can block waiting on a
# password nobody is there to type is the exact failure this repo already
# spent a debugging session on.
if sudo -n -v 2>/dev/null; then
  : # passwordless or already-cached credentials — nothing to warn about
elif id -nG "$USER" 2>/dev/null | grep -qwE 'sudo|wheel|admin'; then
  : # can sudo, will be asked for a password further down. Fine.
else
  die "This user isn't in a sudo group ($USER), so nothing here can install anything. As root: 'usermod -aG sudo $USER', then log out and back in and re-run this. (If you have sudo rights through an explicit sudoers rule rather than group membership, this check is wrong — delete it and re-run.)"
fi

# The venv doesn't exist yet, so this can't be an Ansible assert either.
if ! command -v python3 >/dev/null 2>&1; then
  die "python3 isn't installed, and Ansible needs it. Install your distro's python3 package, then re-run this."
fi
if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= tuple(int(p) for p in '${ANSIBLE_MIN_PYTHON}'.split('.')) else 1)"; then
  die "ansible-core ${ANSIBLE_VERSION} needs Python >= ${ANSIBLE_MIN_PYTHON}, but python3 here is $(python3 -c 'import sys; print(".".join(str(p) for p in sys.version_info[:3]))'). Use a newer distro release, or pin ANSIBLE_VERSION near the top of this script back to a version that supports this Python (2.17.* needs only 3.10)."
fi
# --- End preflight -----------------------------------------------------

installed_ansible_version() {
  "$VENV_DIR/bin/pip" show ansible-core 2>/dev/null | awk '/^Version:/{print $2}'
}

needs_install=1
if [ -x "$VENV_DIR/bin/ansible-playbook" ]; then
  installed_version="$(installed_ansible_version)"
  case "$installed_version" in
    "${ANSIBLE_VERSION_PREFIX}"*) needs_install=0 ;;
    *)
      log "Venv has ansible-core ${installed_version:-<unknown>}, but this script now pins ${ANSIBLE_VERSION} — recreating the venv..."
      rm -rf "$VENV_DIR"
      ;;
  esac
fi

if [ "$needs_install" -eq 1 ]; then
  log "Setting up Ansible (pinned to ${ANSIBLE_VERSION} — see comment in this script for why)..."
  if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
    # Debian/Ubuntu splits venv support into a separate package; a bare
    # `python3 -m venv` silently produces a broken environment without it.
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -qq || true
      sudo apt-get install -y python3-venv python3-full
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y python3-pip
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -S --noconfirm python-pip
    fi
    python3 -m venv "$VENV_DIR"
  fi
  "$VENV_DIR/bin/pip" install --quiet "ansible-core==${ANSIBLE_VERSION}"
fi

ANSIBLE_PLAYBOOK="$VENV_DIR/bin/ansible-playbook"

cd "$REPO_DIR"

# `Defaults use_pty` in /etc/sudoers forces every sudo call to have a real
# terminal attached — a deliberate anti-scripting security measure that
# also blocks Ansible's `become`, since Ansible doesn't allocate one. This
# can't be fixed from inside the playbook: an Ansible task using `become`
# would be blocked by the exact setting it's trying to remove. It has to
# happen here, directly, while this script still has your real terminal.
if sudo grep -qE '^\s*Defaults\s+use_pty' /etc/sudoers 2>/dev/null; then
  log "Found 'Defaults use_pty' in /etc/sudoers — this blocks Ansible's sudo entirely (it requires a real terminal, which automation doesn't have). Disabling it, this one time..."
  editor_script="$(mktemp)"
  cat > "$editor_script" <<'EOF'
#!/usr/bin/env bash
# visudo invokes its editor as `$SUDO_EDITOR -- /path/to/tmpfile` — forward
# everything (including the leading --) straight to sed, which already
# understands -- as its own end-of-options marker.
sed -i -E 's/^([[:space:]]*Defaults[[:space:]]+use_pty)/# \1  # disabled by workstation-setup bootstrap.sh, blocks Ansible become/' "$@"
EOF
  chmod +x "$editor_script"
  # visudo specifically wants SUDO_EDITOR (not plain EDITOR), and it has to
  # be explicitly preserved through sudo's environment reset or it's
  # silently ignored in favor of visudo's own default editor.
  sudo --preserve-env=SUDO_EDITOR env SUDO_EDITOR="$editor_script" visudo >/dev/null 2>&1 || true
  rm -f "$editor_script"
  # Don't trust the exit code alone (visudo exits 0 even if the editor made
  # no change) — verify the line is actually gone.
  if sudo grep -qE '^\s*Defaults\s+use_pty' /etc/sudoers 2>/dev/null; then
    log "Automatic edit didn't apply — /etc/sudoers is untouched. Comment out 'Defaults use_pty' yourself with 'sudo visudo', then re-run this script."
  else
    log "Disabled successfully."
  fi
fi

# `sudo -n true` alone isn't reliable here — it also succeeds off a recently
# cached sudo ticket, not just a real NOPASSWD rule, and Ansible's `become`
# runs in a separate process that doesn't get to use that same cached
# ticket. Checking `sudo -n -l` for the literal NOPASSWD tag distinguishes
# "actually configured passwordless" from "happens to work right now."
if sudo -n -l 2>/dev/null | grep -qi nopasswd; then
  log "Passwordless sudo (NOPASSWD) detected, skipping the sudo password prompt..."
  log "Running the playbook..."
  "$ANSIBLE_PLAYBOOK" ansible/playbook.yml
else
  log "Running the playbook (you'll be asked for your sudo password)..."
  "$ANSIBLE_PLAYBOOK" -K ansible/playbook.yml
fi
