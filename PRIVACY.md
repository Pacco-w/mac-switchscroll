# Privacy

SwitchScroll runs entirely on your Mac.

It does not include networking, analytics, telemetry, crash reporting, auto-update, or remote logging.

## Permissions Used

Accessibility is used for:

- Listening for and adjusting scroll wheel events
- Reading application windows for the Control+Tab switcher
- Activating the selected window

Screen Recording is used for:

- Capturing local window thumbnails for the switcher overlay

If Screen Recording is denied, SwitchScroll still works without thumbnails.

## Data Handling

SwitchScroll does not send data anywhere. Window titles, app names, screenshots, thumbnails, scroll events, and keyboard events stay local.

Debug builds may write a local log file at `/tmp/SwitchScrollDebug.log`. Release builds do not write this debug log.
