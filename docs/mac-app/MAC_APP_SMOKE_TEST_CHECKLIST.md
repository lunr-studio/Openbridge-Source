# Source-Run Smoke Checklist

Run this checklist on the exact candidate commit without signing credentials.

| Check | Action | Pass condition |
| --- | --- | --- |
| Commands | `make help` | only source setup, compile, run, and test commands are offered |
| Python | `make python-test` | syntax and unit tests pass |
| Swift | `make swift-check` | app compiles and source checks pass |
| Launch | `make app-run` | app opens and menu-bar item appears |
| Setup | review the first-run and permission guidance | required actions and current status are understandable |
| Dictation | record a short synthetic phrase | local transcription completes or gives an actionable model/setup message |
| Stop/cancel | exercise recording stop and cancel | no stuck recording or overlay |
| Settings | change a safe preference and relaunch from source | preference remains consistent |
| History/privacy | enable, inspect, and disable local history using synthetic text | controls and local data behaviour match the privacy documentation |
| Help | open local Help | page loads from the source tree and avoids unsupported privacy claims |
| Media | transcribe a small self-created file | FFmpeg path and engine result are clear |
| Compatibility | run `make test` | history, dictionary, formatting, and compatibility checks pass |

Record the Mac model, macOS/Swift/Python versions, source commit, and outcomes. Do not attach real transcripts, credentials, or private machine paths.
