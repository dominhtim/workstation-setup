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

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }

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
