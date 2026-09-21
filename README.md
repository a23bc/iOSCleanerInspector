# iOSCleanerInspector

A read-only iOS/TrollStore filesystem inspector for auditing cache-cleaner behavior.

> **Safety:** This project intentionally contains no file deletion, move, rename, or write-to-scanned-path logic. It is designed to show *what* is being counted rather than silently reducing everything to a total size.

## What it scans

The first version probes these locations when accessible:

- `/tmp`
- `/var/tmp`
- `/var/mobile/Library/Caches`
- `/var/mobile/Library/Logs`
- `/var/mobile/Library/Preferences/Logs`
- `/var/mobile/Media/PhotoData/Caches`
- `/var/mobile/Media/PhotoData/Thumbnails`
- `/var/mobile/Containers/Data/Application`

For App containers it reports each application's container UUID and, where readable, cache-like directories.

## Important security design

The original cleaner being audited uses unusually broad private entitlements. This project does **not** copy every entitlement merely because the original has it.

The app is structured so that the scanner reports access failures. Start with the smallest entitlement set that works on the target iOS/TrollStore environment and only expand it when a measured access failure justifies it.

No network framework is linked. No background audio mode is used. No IOKit access is requested.

## Build

GitHub Actions builds the app on a macOS runner. The workflow produces:

- `iOSCleanerInspector.app`
- `iOSCleanerInspector.tipa`

The TIPA is an unsigned/ad-hoc packaged artifact intended for installation/testing with the user's own TrollStore environment. The workflow does not embed a developer signing identity.

## Local build

A full Xcode project is intentionally avoided in v0.1. The Makefile uses Apple's command-line SDK tools.

```sh
make
make package
```

On GitHub Actions the workflow selects the installed iPhoneOS SDK automatically.

## Scope

This is an auditing/inspection tool, not a cleaner. Do not add deletion APIs unless this project is explicitly redesigned and reviewed for that purpose.
