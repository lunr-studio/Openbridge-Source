# Third-Party Notices

Openbridge project-authored source is licensed under Apache-2.0. The following software and model assets retain their own terms.

## Python packages

Versions below are the direct versions resolved in `requirements-lock.txt`.

| Package | Version | Licence |
| --- | --- | --- |
| mlx-whisper | 0.4.3 | MIT |
| mlx-lm | 0.31.3 | MIT |
| parakeet-mlx | 0.5.2 | Apache-2.0 |
| huggingface-hub | 1.15.0 | Apache-2.0 |
| numpy | 2.4.5 | BSD-3-Clause |
| pyautogui | 0.9.54 | BSD-3-Clause |
| pynput | 1.8.2 | LGPL-3.0-or-later |
| pyperclip | 1.11.0 | BSD-3-Clause |
| psutil | 7.2.2 | BSD-3-Clause |
| sounddevice | 0.5.5 | MIT |
| soundfile | 0.13.1 | BSD-3-Clause |
| yt-dlp | 2026.7.4 | Unlicense |

The full resolved environment and package hashes are in `requirements-lock.txt`. Installing dependencies downloads them from their upstream distributors; their licences are not replaced by Openbridge’s licence.

## FFmpeg

FFmpeg is an external executable used for audio extraction. It is not stored or distributed in this repository. FFmpeg can be LGPL or GPL depending on its compile configuration. Anyone redistributing an FFmpeg binary must inspect `ffmpeg -buildconf`, identify the applicable licence, provide required notices and source availability, and comply with the FFmpeg project’s terms.

The private official-build process has its own binary-specific compliance evidence. That evidence and its packaging operations are outside this source repository.

## Model weights

Model weights are downloaded at runtime and are not committed here.

| Runtime identifier | Upstream model | Terms |
| --- | --- | --- |
| `whisper-tiny` | `mlx-community/whisper-tiny-mlx` | MIT |
| `whisper-base` | `mlx-community/whisper-base-mlx` | MIT |
| `whisper-large-v3` | `mlx-community/whisper-large-v3-mlx` | MIT |
| `parakeet-tdt-0.6b-v3-mlx-bf16` | `sonic-speech/parakeet-tdt-0.6b-v3`, derived from NVIDIA Parakeet TDT v3 | CC-BY-4.0 weights; Apache-2.0 runtime |
| Parakeet reference path | `nvidia/parakeet-tdt-0.6b-v3` | CC-BY-4.0 weights |
| correction / command model | `mlx-community/gemma-3-4b-it-qat-4bit` | Google Gemma Terms of Use |

Users who download a model must comply with its current upstream terms. The source identifiers are authoritative in `openbridge_engine/config.py`.

## Openbridge assets

Openbridge names, marks, app icons, and menu-bar artwork remain reserved trademarks or brand assets of Lunr Studio. See `docs/governance/TRADEMARK_AND_ASSET_POLICY.md`.

This notice is informational and is not legal advice. Contributors changing dependencies, model identifiers, or assets must update the inventory and provenance documents in the same pull request.

## Application fonts and evaluation tools

Instrument Sans and Geist Mono retain their bundled SIL Open Font License 1.1
notices under `Sources/OpenBridgeUI/Resources/Fonts/`. Source URLs and hashes are
in that directory's `sources.json`.

Satoshi font binaries and their private history are excluded from this clean
repository. Application headings use Instrument Sans.

The existing Cloud evaluation tooling uses `@playwright/test` 1.64.0 under
Apache-2.0; its dependency lock is `evals/cloud/package-lock.json`. It is developer
tooling, not a production Cloud feature or website distribution.
