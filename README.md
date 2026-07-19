# Ledge

A native macOS menu-bar utility that turns the space around the MacBook camera notch into a focused home for media, calendar, clipboard, timers, agent usage, and timely device updates.

## Current implementation

- Menu-bar-only app (`LSUIElement`), with no Dock icon.
- Versioned first-run onboarding with a notch greeting, a separate native welcome window, and looping motion previews for core features.
- Transparent idle hit surface that leaves the physical MacBook notch visually untouched.
- Device-black active surfaces with a four-point hardware overlap and notch-specific shoulder curves to prevent visible seams.
- Larger compact playback surface with track artwork and an optional live five-band waveform driven by the active media app's outgoing audio.
- Coordinated spring-like hover or click expansion inside a fixed transparent canvas, preventing window-size jumps.
- Adaptive expanded surfaces with Home, Clipboard, and Timer tabs, plus a dedicated full-calendar route.
- Home dashboard with media controls, a horizontally scrollable Apple Calendar strip, and events for the selected day.
- EventKit calendar integration with explicit full-access permission handling and live refresh when Calendar changes.
- Spotify fallback metadata persisted from the last observed track; fallback controls relaunch Spotify before playback commands are sent.
- Finder-style clipboard tab with recent screenshots and copied text in separate horizontal strips, multi-selection, Command-C, native Quick Look, numbered text shortcuts, and drag export.
- Ruler-style 1–120 minute timer with a live countdown and completion sound.
- Single-surface animation inside a fixed transparent panel, preventing intermediate window-size jumps during hover.
- Hover expansion from idle into a minimal no-media state.
- Track title, artist, album, source-app icon, elapsed time, duration, and cached remote artwork.
- Capability-aware play/pause, previous, and next commands.
- Spotify desktop integration using its native scripting interface for authoritative playback state, controls, and album artwork when system metadata is incomplete.
- YouTube support through Safari and Chromium browsers that publish to the macOS Now Playing session, including inline, remote-URL, and YouTube-thumbnail artwork fallbacks.
- Automatic return to the idle notch when the source application becomes frontmost.
- Notch-aware geometry with a synthetic centered pill fallback for external displays.
- All-Spaces and full-screen auxiliary panel behavior.
- Built-in preview provider, available from the menu-bar menu.

## Requirements

- macOS 15 or later
- Xcode 26 or later for development

## Build and run

Open `MacDynamicIsland.xcodeproj` in Xcode and run the `Ledge` scheme, or build from Terminal:

```sh
xcodebuild \
  -project MacDynamicIsland.xcodeproj \
  -scheme Ledge \
  -configuration Debug \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

open DerivedData/Build/Products/Debug/Ledge.app
```

For a deterministic UI preview without active media, launch the executable with:

```sh
DerivedData/Build/Products/Debug/Ledge.app/Contents/MacOS/Ledge --preview
```

The welcome experience can be replayed from the menu bar, from Settings → About, or directly during development:

```sh
DerivedData/Build/Products/Debug/Ledge.app/Contents/MacOS/Ledge --onboarding
```

Run the unit tests with:

```sh
xcodebuild \
  -project MacDynamicIsland.xcodeproj \
  -scheme Ledge \
  -derivedDataPath DerivedData \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

## Media integration note

Apple does not expose a public cross-application Now Playing reader. Direct calls to the private MediaRemote framework are also entitlement-gated on macOS 15.4 and later.

The current prototype retrieves the local Now Playing object through the system JavaScript-for-Automation host and sends browser commands through `MRNowPlayingController`. Spotify is enriched and controlled through Spotify's built-in AppleScript interface because Spotify can omit playback-rate and artwork data from its system Now Playing dictionary. The first Spotify access may produce a macOS Automation permission prompt.

The compact live waveform and Bluetooth connection alerts start enabled and can be turned off independently in Settings. After onboarding, macOS requests System Audio Recording permission when the first live media capture begins and may request Bluetooth access as connection monitoring starts. The waveform uses a Core Audio process tap, scoped privately to this app, to analyze five frequency bands from the active source app in memory. Audio is never written to disk or transmitted. If permission is unavailable, the island keeps using its decorative waveform. Browser capture is process-scoped, so simultaneous audible tabs from the same browser are represented together. Codex and Claude polling begins only after the Agentic interface is opened.

Calendar data is read through EventKit only after the user grants Calendar access. Clipboard monitoring starts only after the user opens the Clipboard tab; history is kept in memory, limited to 30 entries, discarded on quit, and never transmitted. The clipboard tab also discovers recent files in the configured macOS screenshot location. Items can be selected, Command-clicked, copied again, previewed with Space, or dragged directly to another app; Command-0 through Command-9 copy the first ten text entries.

Current media metadata and agent-usage snapshots are session-only. Ledge removes metadata caches created by older prototype builds. The optional Claude Code status-line bridge retains only quota metadata and the restore record needed to preserve an existing user configuration, using owner-only file permissions.

Turning off **Enable Ledge** stops all runtime integrations and clears session-only media, Calendar, clipboard, Bluetooth, and agent data from the app.

macOS does not provide a supported API that lets a third-party utility intercept or replace notifications delivered by Messages, FaceTime, or iPhone call relay. `UNUserNotificationCenter` exposes notifications owned by this app, not other apps. A call/message interruption UI can be added once there is an authorized event source, but shipping a Notification Center scraper would require Accessibility or private APIs and would be fragile and privacy-sensitive.

Spotify metadata, playback state, supported commands, and a 640 × 640 album-art URL have been validated on macOS 26.3. YouTube uses the same system session exposed by Safari and Chromium browsers; browser/version compatibility still needs hands-on validation before distribution because MediaRemote is private implementation detail.

All private media access is isolated behind `MediaSessionProviding`, so it can be replaced without changing the island state machine or UI.

## Project structure

- `App`: process lifecycle and menu-bar menu
- `Core`: media model and island state machine
- `Services`: system/preview media providers, foreground-app monitor, and live system-audio meter
- `UI`: SwiftUI island views and the AppKit floating panel
- `LedgeTests`: timeline and visibility-state tests

## Distribution

Run the complete local gate before preparing an archive:

```sh
Scripts/security-check.sh
Scripts/release-check.sh
```

Ledge is intended for direct Developer ID distribution and notarization. The current media implementation uses a private macOS framework through the system automation host, so it is not suitable for Mac App Store submission. See `RELEASE.md` for the signing, notarization, clean-Mac acceptance, privacy, and support requirements. See `PRIVACY.md` for the user-facing data-handling notice.

After exporting and notarizing the public app, run `Scripts/verify-distribution.sh /path/to/Ledge.app` against the exact artifact users will receive.

## Next milestones

1. Complete hands-on interaction and visual validation for every tab, Calendar permission state, and clipboard drag destination.
2. Decide whether communication interruptions use a companion integration, user-provided automation, or an explicitly unsupported private/Accessibility adapter.
3. Add timer persistence and local completion notifications.
4. Add interactive media seek, launch-at-login, and display selection settings.
5. Add visual regression tests and complete hands-on clean-Mac acceptance testing for each release.
