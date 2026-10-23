# OpenBridge Engine

This folder is the reusable Python engine.

The engine handles transcription, model lookup, media processing, vocabulary correction, and command-mode text transformation. The native Mac app calls into this engine through [../engine_cli.py](../engine_cli.py).

| File | What it is for |
| --- | --- |
| `cli.py` | Command-line interface used by `engine_cli.py`. |
| `common.py` | Shared transcription and text-cleanup logic. |
| `config.py` | Default paths and configuration. |
| `media.py` | Audio/video extraction and media transcription helpers. |
| `models.py` | Curated speech model definitions, install logic, and Parakeet validation planning. |
| `command_mode.py` | Selected-text transformation through local MLX models, with optional Ollama fallback. |

Beginner note: a Python package is just a folder of related Python files with an `__init__.py` marker.

## Benchmarking transcription models

Use the benchmark command when comparing local speech models for V2 speed/quality decisions:

```bash
.venv/bin/python engine_cli.py benchmark \
  --audio-path /path/to/sample.wav \
  --model whisper-base \
  --label "10-second dictation" \
  --warm-model-first
```

The command prints JSON with:

- audio duration
- model label and resolved local model path
- wall time and real-time factor
- Python/MLX runtime details
- basic Mac hardware context
- a `markdownTableRow` value that can be pasted into the V2 optimization roadmap

By default it does not print transcript text, only transcript length and segment counts. Add `--include-transcript-text` only when the sample is safe to expose in terminal logs.

Before installing experimental Parakeet dependencies, inspect the validation plan:

```bash
.venv/bin/python engine_cli.py parakeet-plan
```

That command is read-only. It reports the v3/v2 comparison candidates, public evidence, local dependency readiness, and the approved V2 default gate. The V2 default is `parakeet-tdt-0.6b-v3-mlx-bf16`; Whisper Base remains the fallback and rollback path.

For Parakeet validation, use an isolated environment instead of the release `.venv`:

```bash
python3.13 -m venv ~/Library/Caches/OpenBridge/parakeet-validation/venv
~/Library/Caches/OpenBridge/parakeet-validation/venv/bin/python -m pip install \
  parakeet-mlx torch librosa soundfile huggingface_hub \
  git+https://github.com/huggingface/transformers
```

Set `OPENBRIDGE_MODEL_DIR` and `HF_HOME` to the same validation cache before installing or benchmarking Parakeet when testing outside the packaged app. Release builds include the Parakeet MLX runtime, while model files remain installable local assets.

```bash
OPENBRIDGE_MODEL_DIR=~/Library/Caches/OpenBridge/parakeet-validation/models \
HF_HOME=~/Library/Caches/OpenBridge/parakeet-validation/hf-home \
~/Library/Caches/OpenBridge/parakeet-validation/venv/bin/python \
  engine_cli.py models install --model parakeet-tdt-0.6b-v3-mlx-bf16

OPENBRIDGE_MODEL_DIR=~/Library/Caches/OpenBridge/parakeet-validation/models \
HF_HOME=~/Library/Caches/OpenBridge/parakeet-validation/hf-home \
~/Library/Caches/OpenBridge/parakeet-validation/venv/bin/python \
  engine_cli.py readiness --model parakeet-tdt-0.6b-v3-mlx-bf16 --cleanup-mode off --load-check --inference-check
```
