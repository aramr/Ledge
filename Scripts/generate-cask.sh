#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: ${0:t} VERSION DMG_SHA256" >&2
  exit 64
fi

VERSION="$1"
SHA256="$2"

[[ "$VERSION" == <->.<->.<-> ]] || {
  echo "Version must use semantic versioning, for example 1.2.3." >&2
  exit 1
}
[[ ${#SHA256} -eq 64 && "$SHA256" != *[^0-9a-f]* ]] || {
  echo "Expected a lowercase SHA-256 digest." >&2
  exit 1
}

cat <<EOF
cask "ledge" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/aramr/Ledge/releases/download/v#{version}/Ledge-#{version}.dmg"
  name "Ledge"
  desc "Native Dynamic Island experience for the MacBook notch"
  homepage "https://github.com/aramr/Ledge"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Ledge.app"

  zap trash: [
    "~/Library/Application Support/Ledge",
    "~/Library/Caches/com.aramrahimi.Ledge",
    "~/Library/HTTPStorages/com.aramrahimi.Ledge",
    "~/Library/Preferences/com.aramrahimi.Ledge.plist",
    "~/Library/Saved Application State/com.aramrahimi.Ledge.savedState",
  ]
end
EOF
