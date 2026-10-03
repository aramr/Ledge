# Ledge Release Guide

Ledge publishes signed, notarized universal macOS builds through GitHub Releases. The same DMG powers direct downloads and the `aramr/homebrew-tap` cask. Sparkle uses the release ZIP and `appcast.xml` for in-app updates.

## One-time owner setup

### 1. Apple distribution identity

Join the Apple Developer Program and create a **Developer ID Application** certificate in Xcode:

1. Open Xcode → Settings → Accounts.
2. Select the Ledge team, then Manage Certificates.
3. Add a Developer ID Application certificate.
4. Export the certificate and private key from Keychain Access as a password-protected `.p12`.

Base64-encode the `.p12` and add these Actions secrets to `aramr/Ledge`:

- `MACOS_CERTIFICATE_P12_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`

From a terminal authenticated with GitHub CLI:

```sh
base64 -i /path/to/DeveloperIDApplication.p12 |
  gh secret set MACOS_CERTIFICATE_P12_BASE64 --repo aramr/Ledge
gh secret set MACOS_CERTIFICATE_PASSWORD --repo aramr/Ledge
```

`APPLE_TEAM_ID` is currently committed in the release workflow as `M7PFX75L8L`.

### 2. Apple notarization key

Create a **team** App Store Connect API key with permission to submit Developer ID software for notarization. Individual API keys are not supported by `notarytool`. Add:

- `APPLE_API_KEY_P8_BASE64` — base64-encoded `.p8` contents
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`

```sh
base64 -i /path/to/AuthKey_KEYID.p8 |
  gh secret set APPLE_API_KEY_P8_BASE64 --repo aramr/Ledge
gh secret set APPLE_API_KEY_ID --repo aramr/Ledge
gh secret set APPLE_API_ISSUER_ID --repo aramr/Ledge
```

The release workflow writes the key only to the ephemeral runner and removes it when the runner is destroyed.

### 3. Sparkle update signing

Ledge uses a dedicated Ed25519 key under the Keychain account `com.aramrahimi.Ledge`. Its public key is committed as `SUPublicEDKey`; its private key is stored in the repository secret `SPARKLE_PRIVATE_KEY`.

Back up the Keychain key securely. Losing both the Keychain item and GitHub secret would require an update-signing key rotation.

### 4. Homebrew tap

The public repository `aramr/homebrew-tap` accepts release updates through a write-enabled SSH deploy key scoped only to that repository. Its private half is stored in Ledge as:

- `HOMEBREW_TAP_DEPLOY_KEY`

The release workflow publishes the immutable GitHub Release, generates and audits `Casks/ledge.rb`, then pushes it to the tap over SSH. If the key is ever rotated, replace both the tap deploy key and this Actions secret.

### 5. GitHub repository protections

- Require the CI workflow before merging into `main`.
- Require pull requests for `main`.
- Keep private vulnerability reporting enabled.
- Keep release immutability enabled.
- Keep secret scanning, push protection, and Dependabot security updates enabled.
- Keep Actions limited to GitHub-owned actions pinned to full commit SHAs.
- Restrict who can create tags matching `v*`.

## Publishing a release

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the Ledge Release build settings.
2. Merge the release commit into `main` and confirm CI passes.
3. Create and push a signed semantic-version tag:

```sh
git tag -s v1.0.0 -m "Ledge 1.0.0"
git push origin v1.0.0
```

The release workflow:

1. validates the tag against `MARKETING_VERSION`;
2. runs tests and creates a universal Developer ID archive;
3. notarizes and staples the app and DMG;
4. creates the DMG, Sparkle ZIP, appcast, checksums, and dSYM archive;
5. verifies signatures, Hardened Runtime, entitlements, architectures, Gatekeeper, and notarization;
6. creates GitHub artifact attestations;
7. publishes the immutable GitHub Release with categorized release notes;
8. updates and audits the Homebrew cask.

All build, signing, notarization, verification, and attestation gates run before publication. Homebrew updates run in a separate job after publication. That job downloads and verifies the published DMG's GitHub attestation, reads the public tap over HTTPS, and uses the scoped deploy key explicitly for pushes. A matching version and checksum are a successful no-op.

If the Homebrew job fails, rerun only the failed job, or dispatch the standalone workflow without rebuilding or republishing the immutable release:

```sh
gh workflow run homebrew.yml --repo aramr/Ledge -f version=1.0.1
```

The workflow only accepts the latest published release to prevent accidental downgrades. Authentication errors are reported before cask generation or audit; the key fingerprint is safe to compare with the tap's registered deploy key. Private key material is never logged.

## Local release verification

Run the unsigned CI gates:

```sh
Scripts/ci.sh
```

After exporting a Developer ID archive, package it using either a Keychain notary profile:

```sh
export NOTARYTOOL_PROFILE=LedgeNotary
export SPARKLE_PRIVATE_KEY="$(security find-generic-password -a com.aramrahimi.Ledge -s https://sparkle-project.org -w)"
Scripts/build-release.sh build/release
Scripts/package-release.sh build/release/Export/Ledge.app
```

or the App Store Connect API key variables used by CI. Never commit exported certificates, API keys, Sparkle private keys, or generated release artifacts.

## Installation verification

On a clean macOS user account:

```sh
brew install --cask aramr/tap/ledge
```

Also download the DMG from the GitHub Release, drag Ledge to Applications, and confirm both installations launch without a Gatekeeper override. Verify an asset’s provenance with:

```sh
gh attestation verify Ledge-1.0.0.dmg --repo aramr/Ledge
```
