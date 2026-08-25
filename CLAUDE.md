# CLAUDE.md

Context for working on this repo. Everything here used to live as comment
blocks in `bootstrap.sh` / `ansible/playbook.yml` or as sections of the
README; it was moved out because it is history and rationale, not
documentation of what the code currently does.

## House rules

- **Comments in code are at most 2 lines.** They say why, not what. If an
  explanation needs a paragraph, it belongs in this file, and the code gets
  a one-line pointer (`see CLAUDE.md`) at most.
- **Don't use code comments as a work log.** No "used to be X", no "re-tested
  on <date>", no "this was a hard failure until...". That is what this file
  and `git log` are for.
- **README.md is a README.** It documents what the repo is and how to use it,
  for someone who has never seen it. It is not a changelog, a postmortem,
  or a record of what was tried. New rationale goes here instead.
- **No second person.** Code comments don't address a reader as "you", and
  don't editorialize ("this alone is worth it", "the actual payoff").
- Keep this file current when the reasoning below stops being true.

## Layout

- `bootstrap.sh` — preflight + a pinned Ansible in its own venv, then hands
  off. Deliberately thin; provisioning logic goes in the playbook.
- `ansible/playbook.yml` — everything the machine actually gets.
- `ansible/templates/chezmoi.toml.j2` — pre-seeds chezmoi's identity data.

Dotfiles themselves live in [dominhtim/dotfiles](https://github.com/dominhtim/dotfiles).
That repo doesn't know this one exists; this one applies it as its last step.

## Why ansible-core is pinned, and the history of the pin

`bootstrap.sh` installs `ansible-core` into `~/.workstation-setup-venv`
rather than using the distro package, so the automation runs against a
version this repo chose.

The pin was `2.17.*` for a long time because `become` hung with `Timed out
waiting for become success or become password prompt`, regardless of how
the password was supplied. Every layer under Ansible was tested
individually (sudo directly; sudo with stdin piped; sudo with stdin, stdout
and stderr all redirected away from a terminal) and all worked, so the
cause was read as an `ansible-core` 2.19+ regression.

Re-tested 2026-08-24 against a minimal `become` playbook: 2.20.0, 2.20.8
and 2.21.3 **all pass**, including the 2.20 originally called broken. The
diagnosis was misattributed. The real cause was almost certainly `Defaults
use_pty` in `/etc/sudoers` — the classic source of that exact timeout —
which `bootstrap.sh` now detects and comments out itself before running the
playbook. The version was never the problem.

Caveat: that re-test ran on a machine already past both hurdles (`use_pty`
disabled, NOPASSWD in place), so the first bootstrap of a genuinely fresh
machine is the one path still unverified against 2.21. If it hangs there,
set `ANSIBLE_VERSION` back to `"2.17.*"`; the venv is recreated
automatically on a version mismatch, so that costs nothing but a re-run.

`ANSIBLE_MIN_PYTHON` exists so the failure reads as "your Python is too old
for the pin" rather than a wall of pip resolver output. 2.21 needs >= 3.12;
2.17 needed only >= 3.10. Keep it in step with `ANSIBLE_VERSION`.

## Why `Defaults use_pty` is handled in bash, not Ansible

It forces every sudo call to have a real terminal attached — a deliberate
anti-scripting measure that also blocks Ansible's `become`, which allocates
no terminal. It can't be fixed from inside the playbook: an Ansible task
using `become` would be blocked by the exact setting it is trying to
remove. So it happens in `bootstrap.sh`, while the script still has a real
terminal, via a throwaway `SUDO_EDITOR` script handed to `visudo`.

`visudo` exits 0 even when its editor changed nothing, so the result is
verified by grepping `/etc/sudoers` again rather than trusting the exit code.

## Why the NOPASSWD probe uses `sudo -n -l`

`sudo -n true` also succeeds off a recently cached sudo ticket, and
Ansible's `become` runs in a separate process that doesn't inherit that
ticket. Grepping `sudo -n -l` for the literal NOPASSWD tag distinguishes
"actually configured passwordless" from "happens to work right now".

Related: every sudo probe in the preflight is either `-n` or a pure group
lookup. A check that can block on a password nobody is there to type is the
exact failure this repo already spent a debugging session on.

## Why the package preflight simulates an install

`package` fails as a single unit: one missing name takes the whole install
task down, and apt's error doesn't make it obvious which name was at fault.

`apt-get -s install` is used rather than `apt-cache show` because `show`
exits 0 for a purely virtual name with no installation candidate — on
Ubuntu, `docker-compose` is exactly such a name, provided by
`docker-compose-v2` — so it would wave through things that cannot actually
be installed. The simulated install resolves providers properly. It needs
no root.

Package names are less portable across Debian and Ubuntu than they look:
Debian 13 has `docker-compose` 2.26 (its v1 python package is long gone),
Ubuntu has `docker-compose-v2` and no `docker-compose` at all. Hence
`compose_package`.

## Why Neovim has a version floor

A distro archive is only ever as new as the distro: Ubuntu 26.04 ships
0.11.6, Debian 13 is still on 0.10.x. The shared dotfiles' nvim config calls
`vim.lsp.config()` / `vim.lsp.enable()` (both landed in 0.11), and
mason-lspconfig v2 calls `vim.lsp.enable()` itself — so on an older Neovim
the entire LSP layer dies at startup with `attempt to call field 'config'
(a nil value)`. A box with the older one isn't merely behind; it throws
three errors before you get a prompt.

apt's copy is left installed on purpose. It still owns the vi/vim
alternatives, costs nothing, and `/usr/local/bin` precedes `/usr/bin` on
both distros — so the symlink simply wins on PATH, and undoing the whole
thing is one `rm /usr/local/bin/nvim` away.

No checksum is verified on the tarball (or the chezmoi binary): upstream
publishes no shasum asset for either. HTTPS to GitHub's release CDN is the
integrity guarantee in both cases.

## Why the SSH key is generated early

It used to happen immediately before the dotfiles clone, which meant you
only found out you needed to add a key to GitHub after everything else had
finished — a hard failure at the very end, with no way to continue the same
run. Generating and printing it right after packages means the key is
pasteable within the first few seconds, while oh-my-zsh, the plugin clones
and the chezmoi download run. The `pause` before the clone is the backstop.

No token or password is stored anywhere in this repo. The private key never
leaves the machine; only the public key goes anywhere, and it isn't secret
by definition. Adding it to a GitHub account is the one step that genuinely
can't be automated — GitHub requires an authenticated browser session as a
deliberate security boundary, not a gap here.

## Why only the key line is kept from ssh-keyscan

`ssh-keyscan` writes a `# github.com:22 SSH-2.0-<build>` banner to **stdout**,
not stderr (OpenSSH 10.2), so its raw output is two lines and only the
second is a host key.

Passing both to the `known_hosts` module meant the value could never match
what was already in the file, so every run appended the pair afresh: the
task reported `changed` every time and known_hosts grew by two lines per
provision — 18 github.com entries on this machine before anyone noticed.
The banner is the worst possible thing to have left in, too: it carries
GitHub's current babeld build id, so it doesn't even hold still between runs
for a comparison to succeed.

The `until:` on the keyscan retries on a real key line rather than on
non-empty output, for the same reason — the banner is written even when no
key comes back.

## Why the chezmoi pull and apply are split

`chezmoi update` is pull + apply in one. They're split because the
hand-edit check between them is only meaningful against the freshly pulled
target: a file that looks hand-edited against yesterday's source can be
perfectly in step with what was just pushed, and checking before the pull
blocks on a divergence the pull itself resolves. Not hypothetical — it is
exactly what happened when the fix for a hand-edited `.gitignore_global`
was sitting unpulled in the dotfiles repo while this check refused to let
the pull happen.

The check itself exists because `chezmoi apply` prompts before overwriting
a file that changed since chezmoi last wrote it, and an Ansible task has no
TTY to answer through — the run would otherwise die with `could not open a
new TTY: open /dev/tty: no such device or address`, which names the file
only in passing and says nothing about what to do. `chezmoi status` puts a
non-blank character in column 1 for exactly this case; column 2 is just
"differs from target", which is every file waiting to be applied.

## Odds and ends

- The `~/projects` clones are one-time on purpose. These are working repos;
  Ansible leaves them completely alone once they exist. `# noqa: latest[git]`
  is there because pinning them to a frozen commit would be wrong, not safer.
- oh-my-zsh and its plugins deliberately track upstream tip. It's a rolling
  theme/plugin install, not something with a release to pin to.
- The docker service task is skipped rather than failed where there's no
  systemd — Debian/Ubuntu under WSL without `systemd=true` in `/etc/wsl.conf`
  is the case that actually turns up.
- `.gitignore` covers `ansible/~*` because Ansible occasionally creates a
  literal `~username/` directory there when HOME/USER end up mismatched.
- Only `localhost` is targeted. A real inventory is the natural next step for
  more than one box; nothing here assumes single-machine-only, it just isn't
  built out.
