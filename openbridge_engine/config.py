from __future__ import annotations

from dataclasses import asdict, dataclass
import os
from pathlib import Path


ENGINE_VERSION = "0.1.0"
APP_NAME = "OpenBridge"
DEFAULT_CORRECTION_MODEL = "gemma4:e2b"
DEFAULT_TRANSCRIPTION_LANGUAGE = "en"
DEFAULT_LLM_PROVIDER = os.environ.get("OPENBRIDGE_LLM_PROVIDER", "auto").strip().lower() or "auto"
DEFAULT_MLX_LLM_MODEL = os.environ.get(
    "OPENBRIDGE_MLX_LLM_MODEL",
    "mlx-community/gemma-3-4b-it-qat-4bit",
).strip()
DEFAULT_MLX_LLM_CAREFUL_MODEL = os.environ.get(
    "OPENBRIDGE_MLX_LLM_CAREFUL_MODEL",
    "mlx-community/gemma-3-4b-it-qat-4bit",
).strip()
REPO_ROOT = Path(__file__).resolve().parents[1]
APP_SUPPORT_ROOT = Path.home() / "Library" / "Application Support" / APP_NAME
LLM_CACHE_ROOT = Path(
    os.environ.get(
        "OPENBRIDGE_LLM_CACHE_DIR",
        str(APP_SUPPORT_ROOT / "llm-cache"),
    )
).expanduser()
REPO_MODEL_ROOT = Path(
    os.environ.get(
        "LUNR_WHISPR_REPO_MODEL_DIR",
        str(REPO_ROOT / "models"),
    )
).expanduser()
MODEL_ROOT = Path(
    os.environ.get(
        "OPENBRIDGE_MODEL_DIR",
        os.environ.get(
            "LUNR_WHISPR_LOCAL_MODEL_DIR",
            str(APP_SUPPORT_ROOT / "models"),
        ),
    )
).expanduser()
HF_CACHE_ROOT = (
    Path(os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface"))).expanduser()
    / "hub"
)
DEFAULT_VOCAB_PATH = REPO_ROOT / "vocab_corrections.json"
SPEECH_RUNTIME_MLX_WHISPER = "mlx_whisper"
SPEECH_RUNTIME_PARAKEET_TRANSFORMERS = "parakeet_transformers"
SPEECH_RUNTIME_PARAKEET_MLX = "parakeet_mlx"
DEFAULT_PARAKEET_CANDIDATE_MODEL_ID = "parakeet-tdt-0.6b-v3-mlx-bf16"
DEFAULT_WHISPER_FALLBACK_MODEL_ID = "whisper-base"


@dataclass(frozen=True)
class CuratedModel:
    identifier: str
    repo_id: str
    display_name: str
    summary: str
    runtime: str = SPEECH_RUNTIME_MLX_WHISPER
    auto_manage: bool = True

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


@dataclass(frozen=True)
class ParakeetValidationCandidate:
    identifier: str
    repo_id: str | None
    display_name: str
    candidate_type: str
    architecture: str
    languages: str
    license: str | None
    public_evidence: tuple[str, ...]
    openbridge_strengths: tuple[str, ...]
    openbridge_risks: tuple[str, ...]
    runtime_options: tuple[str, ...]
    validation_role: str
    source_urls: tuple[str, ...]

    def to_dict(self) -> dict[str, object]:
        return asdict(self)


CURATED_MODELS: dict[str, CuratedModel] = {
    "whisper-tiny": CuratedModel(
        identifier="whisper-tiny",
        repo_id="mlx-community/whisper-tiny-mlx",
        display_name="Whisper Tiny",
        summary="Fastest model with lower accuracy.",
    ),
    "whisper-base": CuratedModel(
        identifier="whisper-base",
        repo_id="mlx-community/whisper-base-mlx",
        display_name="Whisper Base",
        summary="Balanced default for the first app release.",
    ),
    "whisper-large-v3": CuratedModel(
        identifier="whisper-large-v3",
        repo_id="mlx-community/whisper-large-v3-mlx",
        display_name="Whisper Large v3",
        summary="Highest accuracy with the heaviest footprint.",
    ),
    DEFAULT_PARAKEET_CANDIDATE_MODEL_ID: CuratedModel(
        identifier=DEFAULT_PARAKEET_CANDIDATE_MODEL_ID,
        repo_id="sonic-speech/parakeet-tdt-0.6b-v3",
        display_name="Parakeet TDT v3 MLX BF16",
        summary="Approved V2 default speech model for Apple silicon. Whisper Base remains the fallback and rollback path.",
        runtime=SPEECH_RUNTIME_PARAKEET_MLX,
        auto_manage=True,
    ),
    "parakeet-tdt-0.6b-v3": CuratedModel(
        identifier="parakeet-tdt-0.6b-v3",
        repo_id="nvidia/parakeet-tdt-0.6b-v3",
        display_name="Parakeet TDT v3 Transformers",
        summary="Official NVIDIA v3 validation path. Works locally with source/new-enough Transformers, but is heavier than the MLX candidate.",
        runtime=SPEECH_RUNTIME_PARAKEET_TRANSFORMERS,
        auto_manage=False,
    ),
}
DEFAULT_MODEL_ID = DEFAULT_PARAKEET_CANDIDATE_MODEL_ID

PARAKEET_VALIDATION_CANDIDATES: dict[str, ParakeetValidationCandidate] = {
    DEFAULT_PARAKEET_CANDIDATE_MODEL_ID: ParakeetValidationCandidate(
        identifier=DEFAULT_PARAKEET_CANDIDATE_MODEL_ID,
        repo_id="sonic-speech/parakeet-tdt-0.6b-v3",
        display_name="Parakeet TDT 0.6B v3 MLX BF16",
        candidate_type="converted-model",
        architecture="FastConformer-TDT via MLX",
        languages="English model card; converted from NVIDIA Parakeet TDT 0.6B v3",
        license="CC-BY-4.0 model weights; parakeet-mlx package is Apache-2.0",
        public_evidence=(
            "The sonic-speech MLX conversion exposes a 2.34 GB BF16 model.safetensors artifact derived from NVIDIA Parakeet TDT v3.",
            "The parakeet-mlx package provides an Apple silicon MLX implementation for Parakeet models without the PyTorch/Transformers runtime stack.",
            "OpenBridge local validation on Apple M4 loaded this candidate, passed readiness inference, and benchmarked it successfully on generated 10s, 31s, and 138s samples.",
        ),
        openbridge_strengths=(
            "Best current fit for OpenBridge's downloadable Apple silicon app because it avoids the heavier PyTorch/Transformers path.",
            "Validated through the OpenBridge engine path faster than the official Transformers path on the 31s and 138s synthetic samples while preserving Parakeet's quality advantage over Whisper Base on the long domain sample.",
        ),
        openbridge_risks=(
            "This is a third-party conversion, so release use needs source/provenance review and package maintenance review.",
            "Still slower than Whisper Base on some synthetic samples tested here, so V2 keeps Whisper Base as the fallback and rollback path.",
        ),
        runtime_options=("parakeet-mlx BF16", "future int8 if package compatibility is fixed"),
        validation_role="Approved V2 default runtime; keep Whisper Base as fallback for missing runtime, missing model, or transcription errors.",
        source_urls=(
            "https://huggingface.co/sonic-speech/parakeet-tdt-0.6b-v3",
            "https://pypi.org/project/parakeet-mlx/",
            "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
        ),
    ),
    "parakeet-tdt-0.6b-v3": ParakeetValidationCandidate(
        identifier="parakeet-tdt-0.6b-v3",
        repo_id="nvidia/parakeet-tdt-0.6b-v3",
        display_name="Parakeet TDT 0.6B v3 Transformers",
        candidate_type="model",
        architecture="FastConformer-TDT",
        languages="25 European languages, including English",
        license="CC-BY-4.0",
        public_evidence=(
            "Hugging Face model card reports 600M parameters, punctuation/capitalization, timestamps, 25-language support, and HF Open-ASR average WER around 6.34%.",
            "NVIDIA technical report reports Parakeet-TDT-0.6B-v3 at RTFx 3332.74 and average WER 6.32 on HF OpenASR leaderboard benchmarks.",
            "Hugging Face model card says Transformers usage needs a source/new-enough Transformers build until TDT support is in an official release.",
        ),
        openbridge_strengths=(
            "Official NVIDIA source path for v3; useful as the reference implementation because it is newer, multilingual, and includes native punctuation/capitalization.",
            "TDT architecture is designed for efficient decoding and can expose token/timestamp data later.",
        ),
        openbridge_risks=(
            "OpenBridge local validation required torch, source Transformers, librosa, and a 4.7 GB local model checkout before the path could run.",
            "On the Apple M4 synthetic benchmark set, this path was slower than Whisper Base and slower than the MLX BF16 conversion on longer samples.",
        ),
        runtime_options=("Transformers/PyTorch validation", "NeMo reference path", "future converted runtime if practical"),
        validation_role="Official reference path; not recommended as the shipped Apple silicon default if the MLX path passes integration and packaging review.",
        source_urls=(
            "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3",
            "https://arxiv.org/pdf/2509.14128",
            "https://huggingface.co/docs/transformers/en/model_doc/parakeet",
        ),
    ),
    "parakeet-tdt-0.6b-v3-mlx-int8": ParakeetValidationCandidate(
        identifier="parakeet-tdt-0.6b-v3-mlx-int8",
        repo_id="sonic-speech/parakeet-tdt-0.6b-v3-int8",
        display_name="Parakeet TDT 0.6B v3 MLX INT8",
        candidate_type="converted-model",
        architecture="FastConformer-TDT via MLX, encoder INT8",
        languages="English model card; converted from NVIDIA Parakeet TDT 0.6B v3",
        license="CC-BY-4.0",
        public_evidence=(
            "The model card reports a 755 MB weight file, 58% lower peak memory, and 30% faster RTFx than the BF16 conversion on an Apple M3 Max.",
            "OpenBridge local validation with parakeet-mlx 0.5.2 could not load this model because quantized scale/bias parameters were rejected by the installed model class.",
        ),
        openbridge_strengths=(
            "Best package-size target if package/model compatibility is fixed.",
            "Could make Parakeet practical for the downloadable app if quality remains equivalent to BF16.",
        ),
        openbridge_risks=(
            "Not currently runnable in this validation environment with parakeet-mlx 0.5.2.",
            "Third-party quantization needs additional provenance, compatibility, and quality checks.",
        ),
        runtime_options=("parakeet-mlx INT8",),
        validation_role="Track as a future optimization candidate; do not select for V2 until it loads and benchmarks in OpenBridge.",
        source_urls=("https://huggingface.co/sonic-speech/parakeet-tdt-0.6b-v3-int8",),
    ),
    "parakeet-tdt-0.6b-v2": ParakeetValidationCandidate(
        identifier="parakeet-tdt-0.6b-v2",
        repo_id="nvidia/parakeet-tdt-0.6b-v2",
        display_name="Parakeet TDT 0.6B v2",
        candidate_type="model",
        architecture="FastConformer-TDT",
        languages="English",
        license="CC-BY-4.0",
        public_evidence=(
            "Hugging Face model card reports average WER 6.05 and RTFx 3380 on HF Open-ASR leaderboard benchmarks with batch size 128.",
            "Model card reports punctuation, capitalization, timestamp prediction, and long audio support up to 24 minutes in one pass.",
        ),
        openbridge_strengths=(
            "Strong English-only comparison baseline for normal OpenBridge dictation.",
            "Slightly stronger published English average WER than the current v3 card, so it should not be skipped.",
        ),
        openbridge_risks=(
            "Older than v3 and less aligned with future multilingual product options.",
            "Published runtime path is NeMo-first and still needs Apple silicon/package validation.",
        ),
        runtime_options=("NeMo reference path", "possible Transformers support if/when available"),
        validation_role="Historical comparison baseline; do not block the approved v3 MLX BF16 default unless release QA finds a blocking issue.",
        source_urls=("https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2",),
    ),
    "parakeet-ctc-rnnt-family": ParakeetValidationCandidate(
        identifier="parakeet-ctc-rnnt-family",
        repo_id=None,
        display_name="Parakeet CTC/RNNT family",
        candidate_type="architecture-family",
        architecture="FastConformer-CTC or FastConformer-RNNT",
        languages="Varies by checkpoint",
        license=None,
        public_evidence=(
            "Hugging Face Transformers documents Parakeet CTC, RNNT, and TDT architectures.",
            "CTC/RNNT paths may be easier to adapt in some runtimes but need output-quality checks against TDT.",
        ),
        openbridge_strengths=(
            "Fallback research path if TDT proves too heavy or brittle on Apple silicon.",
            "Can help separate architecture/runtime risk from the Parakeet model family itself.",
        ),
        openbridge_risks=(
            "May lose product-critical punctuation, capitalization, timestamp behavior, or require more glue code.",
            "Not yet selected as an installable OpenBridge model candidate.",
        ),
        runtime_options=("Transformers/PyTorch research", "future conversion research"),
        validation_role="Evaluate only if TDT v3/v2 cannot meet Mac packaging or runtime needs.",
        source_urls=("https://huggingface.co/docs/transformers/en/model_doc/parakeet",),
    ),
    "nvidia-nim-riva-parakeet": ParakeetValidationCandidate(
        identifier="nvidia-nim-riva-parakeet",
        repo_id=None,
        display_name="NVIDIA NIM/Riva Parakeet path",
        candidate_type="deployment-path",
        architecture="Server/container deployment",
        languages="v2 English or v3 25-language deployment options",
        license=None,
        public_evidence=(
            "NVIDIA NGC describes v2 and v3 Parakeet TDT 0.6B artifacts and NIM containers.",
            "The collection positions both variants around native punctuation, capitalization, word timestamps, and long-form audio support.",
        ),
        openbridge_strengths=(
            "Useful reference for production/server behavior and future enterprise deployments.",
            "Can validate expected Parakeet output behavior outside the Mac app.",
        ),
        openbridge_risks=(
            "Not suitable for OpenBridge V2's local-first downloadable Mac default because it depends on NVIDIA/server infrastructure.",
            "Would weaken the privacy and no-cloud default promise if required for core dictation.",
        ),
        runtime_options=("NVIDIA NIM", "Riva", "NeMo reference"),
        validation_role="Document as non-default for local-first V2; keep as reference path only.",
        source_urls=("https://catalog.ngc.nvidia.com/orgs/nvidia/collections/parakeet-tdt-0.6b",),
    ),
}


def ensure_app_support_dirs() -> None:
    MODEL_ROOT.mkdir(parents=True, exist_ok=True)
    LLM_CACHE_ROOT.mkdir(parents=True, exist_ok=True)
