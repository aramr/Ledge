#!/bin/zsh

set -euo pipefail

[[ $# -eq 2 ]] || {
  echo "Usage: ${0:t} VERSION /path/to/Ledge-VERSION.dmg" >&2
  exit 64
}
ROOT="${0:A:h:h}"
VERSION="$1"
DMG="${2:A}"
[[ "$VERSION" == <->.<->.<-> && -f "$DMG" ]] || exit 64
[[ -n "${HOMEBREW_TAP_DEPLOY_KEY:-}" ]] || {
  echo "HOMEBREW_TAP_DEPLOY_KEY is required." >&2
  exit 1
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/LedgeTap.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
KEY_PATH="$WORK/deploy-key"
KNOWN_HOSTS="$WORK/known_hosts"
print -r -- "$HOMEBREW_TAP_DEPLOY_KEY" > "$KEY_PATH"
chmod 600 "$KEY_PATH"

# Fail early on malformed or encrypted keys without prompting or printing them.
ssh-keygen -y -P '' -f "$KEY_PATH" > "$WORK/deploy-key.pub"
ssh-keygen -lf "$WORK/deploy-key.pub"
# Use GitHub's HTTPS-authenticated host keys rather than an unverified scan.
gh api meta --jq '.ssh_keys[] | "github.com " + .' > "$KNOWN_HOSTS"
[[ -s "$KNOWN_HOSTS" ]]
SSH_COMMAND="ssh -F /dev/null -i ${(q)KEY_PATH} -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${(q)KNOWN_HOSTS}"
authenticated_git() {
  git -c core.sshCommand="$SSH_COMMAND" "$@"
}

# The tap is public: Homebrew never needs the private deploy key to read it.
brew tap aramr/tap https://github.com/aramr/homebrew-tap.git
tap_directory="$(brew --repository aramr/tap)"
git -C "$tap_directory" remote set-url --push origin git@github.com:aramr/homebrew-tap.git
# Verify the actual push authentication before generating or auditing the cask.
authenticated_git -C "$tap_directory" push --dry-run origin HEAD:main

mkdir -p "$tap_directory/Casks"
dmg_sha256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
"$ROOT/Scripts/generate-cask.sh" "$VERSION" "$dmg_sha256" > "$tap_directory/Casks/ledge.rb"
brew style "$tap_directory/Casks/ledge.rb"
brew audit --cask --strict aramr/tap/ledge

git -C "$tap_directory" add Casks/ledge.rb
if git -C "$tap_directory" diff --cached --quiet; then
  echo "Homebrew already serves Ledge $VERSION with the expected checksum."
  exit 0
fi
git -C "$tap_directory" config user.name "github-actions[bot]"
git -C "$tap_directory" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$tap_directory" commit -m "Update Ledge to $VERSION"
authenticated_git -C "$tap_directory" push origin HEAD:main
