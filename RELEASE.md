# Ledge Release Guide

Ledge is currently prepared for **direct Developer ID distribution**, not the Mac App Store. Its cross-application Now Playing implementation relies on a private macOS framework through the system automation host, and its local Codex/Claude integrations require process and file access that are incompatible with a conventional App Sandbox submission.

## Before every release

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in `MacDynamicIsland/Info.plist`.
2. Confirm the release is built from a clean, reviewed, committed revision. The release gate intentionally rejects an empty or dirty Git worktree.
3. Review `PRIVACY.md`, the permission purpose strings, and `ACKNOWLEDGEMENTS.md` against the exact features in the release.
4. Run `Scripts/security-check.sh`, then run `Scripts/release-check.sh` on the oldest supported macOS version and on the current macOS version.
5. Manually test onboarding, every permission state, Spotify and browser media, audio capture denial, Calendar denial, Clipboard/Quick Look/dragging, Bluetooth reconnects, Codex, Claude Desktop, and Claude Code connect/disconnect/restore.
6. Confirm the public download page contains a support contact, privacy contact, system requirements, version, checksum, and a link to the privacy notice.

## Sign and notarize

Use Xcode Organizer whenever possible:

1. Select the Ledge scheme and **Any Mac (Apple Silicon, Intel)**.
2. Product → Archive.
3. In Organizer, choose **Distribute App → Developer ID → Upload**.
4. Select the correct Developer ID Application certificate and team, then submit for notarization.
5. Review the notarization log even when the submission succeeds.
6. Export the notarized app, package it in a signed/notarized DMG or ZIP, and verify the final artifact on a clean Mac.

Command-line verification for the final exported app:

```sh
Scripts/verify-distribution.sh /path/to/Ledge.app
```

The verifier rejects non-Developer-ID identities, missing Hardened Runtime, unsafe debug/JIT entitlements, missing Intel or Apple Silicon slices, invalid Gatekeeper assessment, and missing notarization tickets.

After verification, create the exact downloadable ZIP and checksum without modifying the signed app:

```sh
Scripts/package-distribution.sh /path/to/Ledge.app
```

Publish the generated `.zip` and matching `.sha256` file from `dist/`. Re-run the verifier against an app extracted from the hosted download before announcing the release.

Do not publish an ad-hoc or Apple Development signed build. Never commit signing certificates, private keys, App Store Connect keys, notary credentials, or `.env` files.

## External release blockers

The repository cannot supply a Developer ID identity, Apple Developer team, notarization credentials, public download host, support address, privacy address, or hands-on compatibility results. Those items must be supplied and validated by the release owner before the first public download.
