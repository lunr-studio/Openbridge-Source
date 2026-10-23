# OpenBridgeApp

This folder is the native macOS app.

| File | What it is for |
| --- | --- |
| `OpenBridgeApp.swift` | The app entry point: macOS starts here. |
| `AppState.swift` | Shared app state, like whether recording is active. |
| `Views.swift` | Most of the Settings and menu UI. |
| `EngineService.swift` | Bridge between Swift and the Python engine. |
| `AudioRecorderService.swift` | Microphone recording. |
| `HotkeyService.swift` | Keyboard shortcut handling. |
| `PermissionService.swift` | macOS permission checks. |
| `FlowBarOverlayView.swift` and `FlowBarWindowController.swift` | Floating overlay shown while recording or processing. |
| `PasteboardService.swift` | Clipboard and paste behavior. |
| `DictationHistoryStore.swift` and `SnippetStore.swift` | Local saved text/history helpers. |
| `Models.swift` and `ShortcutSettings.swift` | Small data models used by the app. |
| `OpenBridgeTheme.swift` | Shared colors and styling. |
| `Resources/` | Assets bundled directly inside the Swift target. |

Beginner note: Swift files usually define types. A "service" file is usually code that does a job for the UI.
