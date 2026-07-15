# RevivalFrame

Turn Old iPads into Digital Photo Frames.

This directory contains the iPadOS app target for RevivalFrame. It is intentionally separate from the existing macOS Swift Package app because the iPad version targets iOS 12.0+ and must use UIKit for the original iPad Air on iOS 12.5.8.

Initial scope:

- UIKit app target for iPad and iPhone families.
- iOS deployment target 12.0.
- Four generated preset landscape photos.
- Full-screen playback with simple controls.

Planned sources:

- Preset generated photos.
- Immich shared album.
- SMB folders through an in-app SMB client, not a macOS Finder mount.
# RevivalFrame
