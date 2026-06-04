#!/usr/bin/env bash
#
# DevSpace fresh-machine bootstrap (macOS).
#
# Solves the chicken-and-egg: DevSpace *is* the git auth layer, but cloning
# DevSpace needs git auth. This script mints a GitHub App installation token
# inline (no DevSpace checkout required), uses it to clone the repo, then runs
# install.sh — after which the credential helper is self-sustaining.
#
# SAFE TO PUBLISH AS A PUBLIC GIST: contains no secrets. App ID, installation
# ID, and the private key are supplied at runtime (prompt / 1Password / path).
#
# Usage on a bare Mac:
#   curl -fsSL <raw-gist-url> -o bootstrap.sh && bash bootstrap.sh
#
# Non-interactive (e.g. values pre-set):
#   GH_APP_ID=3527911 GH_APP_INSTALLATION_ID=127702005 \
#   PEM_OP_REF='op://Private/benedict-apptvt-ai/private-key' \
#   bash bootstrap.sh
#
set -euo pipefail

# --- knobs (override via env) ------------------------------------------------
DEVSPACE_REMOTE="${DEVSPACE_REMOTE:-https://github.com/apptivity-lab/devspace.git}"
DEVSPACE_DIR="${DEVSPACE_DIR:-$HOME/devspace}"
DEVSPACE_BRANCH="${DEVSPACE_BRANCH:-main}"
CONFIG_DIR="${CONFIG_DIR:-$HOME/.config/devspace}"
SSH_DIR="$HOME/.ssh"

say()  { printf '\033[1;34m→\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "this bootstrap targets macOS"

# --- 1. prerequisites: git (Xcode CLT), mise, jq ----------------------------
# DevSpace's only declared prereq is mise (docs/mise-setup.md); everything else
# — jq, gh, node — is a mise-managed tool. We install just enough here to mint a
# token and clone: git for the clone, jq for parsing the token response.
say "Checking prerequisites…"

if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools (for git)…"
  xcode-select --install || true
  die "Re-run this script once the Xcode CLT install dialog finishes."
fi
ok "git: $(git --version)"

# mise — the official one-liner. Installs to ~/.local/bin/mise (matches the
# zshrc activation printed at the end). No Homebrew involved.
if ! command -v mise >/dev/null 2>&1 && [[ ! -x "$HOME/.local/bin/mise" ]]; then
  say "Installing mise…"
  curl -fsSL https://mise.run | sh
fi
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"
ok "mise: $(mise --version)"

# jq — needed by the token mint below and by bin/gh-app-token. Install via mise
# unless it's already resolvable (a machine that already had it is left alone).
if ! command -v jq >/dev/null 2>&1; then
  say "Installing jq (via mise)…"
  mise use -g jq
  hash -r
fi
ok "jq: $(command -v jq)"

# openssl + curl: macOS-native (LibreSSL signs RS256 fine) — no install needed.
command -v openssl >/dev/null 2>&1 || die "openssl missing (unexpected on macOS)"

# --- 2. collect App credentials ---------------------------------------------
say "GitHub App credentials (per-developer App — reuse your existing one)…"

if [[ -z "${GH_APP_ID:-}" ]]; then
  read -r -p "  App ID: " GH_APP_ID
fi
if [[ -z "${GH_APP_INSTALLATION_ID:-}" ]]; then
  read -r -p "  Installation ID: " GH_APP_INSTALLATION_ID
fi
[[ -n "$GH_APP_ID" && -n "$GH_APP_INSTALLATION_ID" ]] || die "App ID and Installation ID are required"

mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"
PEM_DEST="$SSH_DIR/${PEM_NAME:-$GH_APP_ID.private-key.pem}"

# Resolve the private key from one of: 1Password, Bitwarden/Vaultwarden,
# a local path (AirDrop/scp), or pasted contents.
if [[ -f "$PEM_DEST" ]]; then
  ok "Private key already present: $PEM_DEST"
elif [[ -n "${PEM_OP_REF:-}" ]]; then
  command -v op >/dev/null 2>&1 || die "PEM_OP_REF set but 1Password CLI (op) not installed: brew install --cask 1password-cli"
  say "Reading private key from 1Password ($PEM_OP_REF)…"
  op read "$PEM_OP_REF" > "$PEM_DEST"
elif [[ -n "${PEM_BW_ITEM:-}" ]]; then
  command -v bw >/dev/null 2>&1 || die "PEM_BW_ITEM set but Bitwarden CLI (bw) not installed: brew install bitwarden-cli"
  say "Reading private key from Bitwarden/Vaultwarden item ($PEM_BW_ITEM)…"
  bw get notes "$PEM_BW_ITEM" > "$PEM_DEST"
elif [[ -n "${PEM_PATH:-}" ]]; then
  say "Copying private key from $PEM_PATH…"
  cp "$PEM_PATH" "$PEM_DEST"
else
  echo "  How do you want to provide the App private key (.pem)?"
  echo "    1) 1Password CLI   (op read 'op://Vault/Item/field')"
  echo "    2) Local file path (AirDrop/scp'd .pem)"
  echo "    3) Paste contents  (end with Ctrl-D)"
  read -r -p "  Choice [1/2/3]: " choice
  case "$choice" in
    1) read -r -p "  op reference: " ref
       command -v op >/dev/null 2>&1 || die "1Password CLI (op) not installed: brew install --cask 1password-cli"
       op read "$ref" > "$PEM_DEST" ;;
    2) read -r -p "  path to .pem: " src
       [[ -f "$src" ]] || die "no file at $src"
       cp "$src" "$PEM_DEST" ;;
    3) echo "  Paste the .pem now, then Ctrl-D:"
       cat > "$PEM_DEST" ;;
    *) die "invalid choice" ;;
  esac
fi
chmod 600 "$PEM_DEST"
grep -q "BEGIN.*PRIVATE KEY" "$PEM_DEST" || die "that doesn't look like a PEM private key: $PEM_DEST"
ok "Private key in place: $PEM_DEST"

# --- 3. write per-user config (install.sh would seed a blank one) ------------
mkdir -p "$CONFIG_DIR"
ENV_FILE="$CONFIG_DIR/github-app.env"
umask 077
cat > "$ENV_FILE" <<EOF
GH_APP_ID=$GH_APP_ID
GH_APP_INSTALLATION_ID=$GH_APP_INSTALLATION_ID
GH_APP_PRIVATE_KEY="$PEM_DEST"
EOF
chmod 600 "$ENV_FILE"
ok "Wrote $ENV_FILE"

# --- 4. mint an installation token inline (no devspace checkout yet) ---------
# Mirrors bin/gh-app-token exactly so the very first clone can authenticate.
say "Minting installation access token…"
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now-60))" "$((now+540))" "$GH_APP_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" \
      | openssl dgst -sha256 -sign "$PEM_DEST" -binary | b64url)
jwt="$header.$payload.$sig"
TOKEN=$(curl -fsS -X POST \
  -H "Authorization: Bearer $jwt" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/app/installations/${GH_APP_INSTALLATION_ID}/access_tokens" \
  | jq -r .token)
[[ -n "$TOKEN" && "$TOKEN" != "null" ]] || die "token mint failed — check App ID / installation ID / key"
ok "Token minted (ghs_…)"

# --- 5. clone devspace with the token ---------------------------------------
if [[ -d "$DEVSPACE_DIR/.git" ]]; then
  ok "DevSpace already cloned at $DEVSPACE_DIR — pulling latest"
  git -C "$DEVSPACE_DIR" pull --ff-only || true
else
  say "Cloning DevSpace → $DEVSPACE_DIR"
  auth_remote="${DEVSPACE_REMOTE/https:\/\//https://x-access-token:$TOKEN@}"
  git clone --branch "$DEVSPACE_BRANCH" "$auth_remote" "$DEVSPACE_DIR"
  # scrub the token from the stored remote URL — the helper takes over next.
  git -C "$DEVSPACE_DIR" remote set-url origin "$DEVSPACE_REMOTE"
fi
ok "DevSpace checked out"

# --- 6. run the installer (wires credential helper, symlinks, skills) -------
say "Running install.sh…"
( cd "$DEVSPACE_DIR" && ./install.sh )

# --- 7. next steps -----------------------------------------------------------
cat <<EOF

$(ok "Bootstrap complete.")

Add to ~/.zshrc (once), then open a new shell:

  eval "\$(\$HOME/.local/bin/mise activate zsh)"
  path+=("\$HOME/.local/share/mise/shims")
  path+=("\$HOME/bin")
  source $CONFIG_DIR/shell/github-app.zsh
  source $CONFIG_DIR/shell/linear-app.zsh

Then verify:
  gh-app-token | head -c 4                                      # → ghs_
  gh api /installation/repositories --jq '.repositories[].full_name'
  git config --global user.name  "Your Name"
  git config --global user.email "you@example.com"

Remaining per-user configs install.sh seeded (fill if you use them):
  $CONFIG_DIR/linear-app.env   $CONFIG_DIR/aikido-cli.env   $CONFIG_DIR/mixpanel-cli.env
EOF
