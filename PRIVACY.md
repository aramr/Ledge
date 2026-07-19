# Ledge Privacy and Data Handling

Effective: July 18, 2026

Ledge is designed as a local macOS utility. It has no Ledge account, analytics SDK, advertising SDK, telemetry service, crash-reporting service, or Ledge-operated backend. Ledge does not sell personal data or use data for tracking.

## Data handled locally

- **Clipboard:** Ledge begins observing the system clipboard only after you open the Clipboard tab. It retains at most 30 recent entries in memory and discards them when the app quits. Recent screenshot discovery reads file names and dates from your configured screenshot folder only after the Clipboard tab is opened. Quick Look may create session-scoped temporary preview files, which are removed when the app exits.
- **Calendar:** After you explicitly grant Calendar access, Ledge reads event titles, times, calendar names, and colors for the dates it displays. Calendar data remains in memory and is not copied to a Ledge server.
- **Media:** Ledge reads the current local Now Playing session. Current track metadata and artwork are held in memory and are not retained across launches. Spotify automation is performed locally through macOS Apple Events.
- **Audio waveform:** This optional integration starts disabled. If you enable it and grant macOS System Audio Recording permission, Ledge analyzes the active media process's outgoing audio in memory. It publishes only five short-lived level values to its interface. Audio samples are not recorded, written to disk, or transmitted.
- **Bluetooth:** This optional integration starts disabled. If enabled, Ledge observes local accessory connection state and briefly displays a device name. Connection data is not persisted or transmitted.
- **Agent usage:** Ledge does not start Codex or Claude polling until you open the Agentic tab or its settings. When enabled, it asks locally installed software for quota metadata such as percentage used and reset time. It does not read prompts, transcripts, credentials, API keys, or Keychain items. Usage snapshots are held in memory only. If you explicitly connect the Claude Code bridge, Ledge stores a quota-only cache and a restore record for the prior status-line setting in `~/Library/Application Support/Ledge/ClaudeUsage`; those files are restricted to the current macOS user.

## Network activity

Ledge may download current media artwork from an HTTPS URL supplied by the active media application. Downloads use an ephemeral session without a persistent URL cache or cookie store and are limited to 20 MB. Choosing setup or help actions can open a provider's website in your browser. Locally installed Codex, Claude, Spotify, or browser software remains governed by that provider's own privacy terms and may perform its own network activity.

## Permissions and control

macOS controls Calendar, System Audio Recording, Bluetooth, and Automation permissions. You can revoke them in System Settings. Clipboard history is session-only and starts only when you open its tab. Disconnecting the Claude Code bridge restores the prior status-line configuration when it is safe to do so and removes Ledge's bridge cache.

Live waveform analysis and Bluetooth connection alerts start enabled. After onboarding, macOS requests the corresponding access when each integration first becomes active. Either feature can be turned off independently in Ledge Settings; an explicit choice is retained across launches.

Turning off **Enable Ledge** stops active media, Calendar, clipboard, Bluetooth, audio, Codex, and Claude monitoring. Ledge also clears the corresponding session-only data from its interface and memory.

## Security

Ledge uses the macOS Hardened Runtime. Sensitive Claude bridge files are written atomically with owner-only file permissions. Release builds are intended to be Developer ID signed and notarized before direct distribution.

## Questions

Use the support contact provided on the page or service from which you obtained Ledge. The distributor should publish a direct support and privacy contact alongside every public download.
