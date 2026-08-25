#!/usr/bin/env bash
# Ensures a working Ansible exists, then hands off to ansible/playbook.yml,
# which does every actual provisioning step.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$HOME/.workstation-setup-venv"

# Pinned in a dedicated venv so the automation runs against a version this
# repo chose, not one a distro upgrade picked. See CLAUDE.md before changing.
ANSIBLE_VERSION="2.21.*"
ANSIBLE_VERSION_PREFIX="${ANSIBLE_VERSION%\**}"
# ansible-core's controller floor for the pin above. Keep the two in step.
ANSIBLE_MIN_PYTHON="3.12"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31m==>\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------
# Only what must hold before Ansible can run at all. Checks about the
# machine being provisioned belong in the playbook's own preflight.

if [ ! -t 0 ]; then
  die "No terminal attached to stdin. Run this script directly in a terminal — not piped, redirected, or backgrounded (it needs to prompt for sudo and, later, for you to add an SSH key to GitHub)."
fi

if ! command -v sudo >/dev/null 2>&1; then
  die "sudo isn't installed. As root: 'apt install sudo && usermod -aG sudo $USER' (or the equivalent for your distro), then log out and back in and re-run this."
fi
# Every probe below is -n or a pure group lookup: none of them can block
# waiting on a password nobody is there to type.
if sudo -n -v 2>/dev/null; then
  : # passwordless or already-cached credentials
elif id -nG "$USER" 2>/dev/null | grep -qwE 'sudo|wheel|admin'; then
  : # can sudo, will be asked for a password further down
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
  log "Setting up Ansible (pinned to ${ANSIBLE_VERSION})..."
  if ! python3 -m venv "$VENV_DIR" >/dev/null 2>&1; then
    # Debian/Ubuntu split venv support out; without it `python3 -m venv`
    # silently produces a broken environment.
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

# `Defaults use_pty` blocks Ansible's `become` entirely. It can't be fixed
# from inside the playbook — see CLAUDE.md.
if sudo grep -qE '^\s*Defaults\s+use_pty' /etc/sudoers 2>/dev/null; then
  log "Found 'Defaults use_pty' in /etc/sudoers — this blocks Ansible's sudo entirely (it requires a real terminal, which automation doesn't have). Disabling it, this one time..."
  editor_script="$(mktemp)"
  cat > "$editor_script" <<'EOF'
#!/usr/bin/env bash
# visudo invokes its editor as `$SUDO_EDITOR -- /path/to/tmpfile`; sed
# understands the leading -- as its own end-of-options marker.
sed -i -E 's/^([[:space:]]*Defaults[[:space:]]+use_pty)/# \1  # disabled by workstation-setup bootstrap.sh, blocks Ansible become/' "$@"
EOF
  chmod +x "$editor_script"
  # visudo wants SUDO_EDITOR specifically, and it has to survive sudo's
  # environment reset or it's silently ignored.
  sudo --preserve-env=SUDO_EDITOR env SUDO_EDITOR="$editor_script" visudo >/dev/null 2>&1 || true
  rm -f "$editor_script"
  # visudo exits 0 even when the editor made no change, so verify directly.
  if sudo grep -qE '^\s*Defaults\s+use_pty' /etc/sudoers 2>/dev/null; then
    log "Automatic edit didn't apply — /etc/sudoers is untouched. Comment out 'Defaults use_pty' yourself with 'sudo visudo', then re-run this script."
  else
    log "Disabled successfully."
  fi
fi

# Checking `-l` for the NOPASSWD tag, not `sudo -n true`: the latter also
# succeeds off a cached ticket that Ansible's `become` won't inherit.
if sudo -n -l 2>/dev/null | grep -qi nopasswd; then
  log "Passwordless sudo (NOPASSWD) detected, skipping the sudo password prompt..."
  log "Running the playbook..."
  "$ANSIBLE_PLAYBOOK" ansible/playbook.yml
else
  log "Running the playbook (you'll be asked for your sudo password)..."
  "$ANSIBLE_PLAYBOOK" -K ansible/playbook.yml
fi
