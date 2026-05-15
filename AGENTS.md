# SwitchScroll Project Instructions

## Project overview

SwitchScroll is a personal-use macOS menu bar utility.

It combines:
- Mouse wheel reverse direction
- Simple smooth scrolling
- Control+Tab window switcher
- Window thumbnails in the switcher overlay

This app is for personal use only. It is not intended for App Store release.

## Technical stack

Use:
- Swift
- AppKit
- NSStatusItem
- CGEventTap
- Accessibility API / AXUIElement
- ScreenCaptureKit
- UserDefaults

Do not use:
- Electron
- Web views
- Cross-platform UI frameworks
- Networking
- Analytics
- Auto-update
- App Store specific logic

## Code rules

- Keep the code simple and modular.
- Prefer small manager classes.
- Every feature should fail gracefully.
- Do not copy source code from Mos or AltTab.
- Implement using native macOS APIs.
- Do not introduce unnecessary dependencies.
- Keep the app menu-bar only.
- Do not show the app in the Dock.

## App behavior

The app should:
- Run as a menu bar app.
- Show a status bar icon.
- Provide menu items for feature toggles.
- Save settings in UserDefaults.
- Not open a main window on launch.
- Not appear in the Dock.

## Window switcher

The shortcut is Control+Tab.

Behavior:
- Press Control+Tab to show the switcher overlay.
- While Control is held, pressing Tab again cycles to the next window.
- Releasing Control activates the selected window.
- Pressing Escape cancels the switcher.
- The overlay should show app icon, app name, window title, and thumbnail.
- If thumbnail capture fails, show a placeholder instead.
- If Screen Recording permission is missing, the switcher must still work without thumbnails.

## Window thumbnails

Use ScreenCaptureKit for thumbnails.

Rules:
- Use SCShareableContent to retrieve shareable windows.
- Match captured windows to Accessibility windows using process ID, title, and frame when possible.
- Do not use CGWindowListCreateImage.
- Do not use CGDisplayStream.
- Thumbnail capture must be optional and failure-tolerant.
- Cache thumbnails briefly to avoid performance issues.
- Never let thumbnail failure break window switching.

## Scroll handling

Use CGEventTap for scroll wheel events.

Rules:
- Reverse scroll direction should modify scroll deltas.
- Smooth scrolling should split one scroll event into multiple smaller events.
- Avoid recursive event handling.
- Avoid high CPU usage.
- If Accessibility permission is missing, do not start event taps.
- Keep smooth scrolling simple in v1.

## Permissions

The app needs:
- Accessibility permission
- Screen Recording permission

Behavior:
- If permission is missing, show status in the menu.
- Provide menu items to open the relevant System Settings pages.
- Do not show repeated alerts.
- The app should keep running even when permissions are missing.

## Build requirement

After every implementation step:
- Run xcodebuild.
- Fix compile errors.
- Do not move to the next feature until the project compiles.
