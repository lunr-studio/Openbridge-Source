# macOS App Identity

| Field | Value |
| --- | --- |
| App name | Openbridge |
| Bundle identifier | `studio.lunr.openbridge` |
| Minimum macOS | 14.0 |
| Full-colour icon | `Resources/OpenBridgeIcon.icns` |
| Menu-bar icon | `Resources/OpenBridgeMenuBarTemplate.png` |

The source app explains why it needs microphone, Accessibility, and Input Monitoring access. Contributors should verify that the app’s permission guidance matches its actual macOS API use.

The icons are generated from the project-owned sources in `Resources/`. They are reserved Openbridge brand assets and should be replaced by downstream distributions.

Official identity, versioning, signing, and notarization are controlled by the separate private build process and are not contributor tasks.
