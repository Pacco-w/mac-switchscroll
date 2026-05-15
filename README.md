# SwitchScroll

SwitchScroll is a small macOS menu bar utility for personal window and scroll workflows.

## Features

- Reverse mouse wheel scrolling
- Simple smooth scrolling
- Control+Tab window switcher
- Window thumbnails in the switcher overlay
- Lightweight recent-window ordering
- Native AppKit menu bar app

## Download

Download the latest DMG from the GitHub Releases page.

Open the DMG, then drag `SwitchScroll.app` into `Applications`.

The public DMG is ad-hoc signed for privacy, so it does not expose a personal Apple Developer certificate. Because it is not Developer ID signed or notarized, macOS may show a Gatekeeper warning the first time you open it. If you trust the source, open it from Finder with Control-click or right-click, then choose Open.

## Permissions

SwitchScroll needs these macOS permissions:

- Accessibility: required for scroll handling and window activation
- Screen Recording: optional for window thumbnails

If thumbnails are unavailable, the window switcher still works without them.

## Privacy

SwitchScroll is local-only:

- No networking
- No analytics
- No auto-update
- No telemetry
- No upload of window titles, screenshots, scroll events, or app usage

Screen Recording permission is used only to capture local window thumbnails for the switcher overlay.

## Build

Open `SwitchScroll.xcodeproj` in Xcode and select your own signing team if needed.

Command-line build:

```sh
xcodebuild -project SwitchScroll.xcodeproj -scheme SwitchScroll -configuration Debug build
```

## Notes

This project is not intended for App Store distribution. Release builds may need to be signed or notarized again on your own machine if you redistribute them broadly.
