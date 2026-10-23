# Asset and Model Provenance

## Project-owned assets

The following included assets are original Lunr Studio works:

| Asset | Purpose |
| --- | --- |
| `Resources/OpenBridgeAppIconSource.svg` | editable app icon source |
| `Resources/OpenBridgeIcon.icns` | generated app icon |
| `Resources/OpenBridgeMenuBarSource.jpeg` | editable menu-bar artwork source |
| `Resources/OpenBridgeMenuBarTemplate.png` | generated menu-bar template |
| `Sources/OpenBridgeApp/Resources/OpenBridgeBrandMark.png` | in-app brand mark |
| `Sources/OpenBridgeApp/Resources/OpenBridgeMenuBarTemplate.png` | in-app menu-bar resource |

They are reserved brand assets, not general-purpose Apache-2.0 artwork. See `TRADEMARK_AND_ASSET_POLICY.md`.

## Excluded material

The clean repository excludes the historical Bloomberg transcript, third-party product screenshots, internal archives, feedback logs, website media, and private release evidence. Tests must use synthetic or appropriately licensed fixtures.

## Model provenance

The source identifiers live in `openbridge_engine/config.py`.

- Whisper MLX conversions are fetched from `mlx-community` and use MIT-licensed Whisper weights.
- The default Parakeet MLX model is `sonic-speech/parakeet-tdt-0.6b-v3`, derived from NVIDIA Parakeet TDT v3. The weights are under CC-BY-4.0; the Python runtime is Apache-2.0.
- The optional NVIDIA Parakeet reference model is `nvidia/parakeet-tdt-0.6b-v3`, also under CC-BY-4.0.
- The correction/command model is `mlx-community/gemma-3-4b-it-qat-4bit` and is governed by the Google Gemma Terms of Use.

Weights are downloaded from upstream providers at runtime and are not included in this repository.

## Change rule

Any pull request that changes a model ID, dependency, or included visual asset must update `THIRD_PARTY_NOTICES.md` and `DEPENDENCY_LICENSE_INVENTORY.json`, then state the licence/provenance evidence in the pull request.
