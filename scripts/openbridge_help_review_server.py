#!/usr/bin/env python3
from __future__ import annotations

import argparse
import html
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import shutil
import subprocess
import sys
import threading
from urllib.parse import urlparse


REPO_ROOT = Path(__file__).resolve().parents[1]
HELP_DIR = REPO_ROOT / "docs" / "help"
KNOWLEDGE_PATH = HELP_DIR / "OPENBRIDGE_HELP_KNOWLEDGE.md"
PROMPT_PATH = HELP_DIR / "OPENBRIDGE_HELP_SYSTEM_PROMPT.md"
DEFAULT_PORT = 17643
SETUP_DIAGNOSTICS_ENV_KEY = "OPENBRIDGE_SETUP_DIAGNOSTICS_PATH"
HELP_LOCAL_AI_ENV_KEY = "OPENBRIDGE_HELP_LOCAL_AI"

ANSI_ESCAPE_PATTERN = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, str(default)))
    except ValueError:
        return default


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


HELP_REQUEST_TIMEOUT_SECONDS = env_float("OPENBRIDGE_HELP_REQUEST_TIMEOUT_SECONDS", 12)
HELP_LOCAL_AI_TIMEOUT_SECONDS = env_float("OPENBRIDGE_HELP_LOCAL_AI_TIMEOUT_SECONDS", 8)
HELP_LOCAL_AI_MAX_TOKENS = env_int("OPENBRIDGE_HELP_LOCAL_AI_MAX_TOKENS", 360)
HELP_MODEL_CONTEXT_SECTION_LIMIT = env_int("OPENBRIDGE_HELP_MODEL_CONTEXT_SECTION_LIMIT", 4)
HELP_MODEL_CONTEXT_SECTION_CHARS = env_int("OPENBRIDGE_HELP_MODEL_CONTEXT_SECTION_CHARS", 900)
HELP_DIAGNOSTICS_CONTEXT_CHARS = env_int("OPENBRIDGE_HELP_DIAGNOSTICS_CONTEXT_CHARS", 4_000)
HELP_MODEL_PROMPT_CHARS = env_int("OPENBRIDGE_HELP_MODEL_PROMPT_CHARS", 12_000)
HELP_QUESTION_CHARS = env_int("OPENBRIDGE_HELP_QUESTION_CHARS", 600)
HELP_REQUEST_BODY_CHARS = env_int("OPENBRIDGE_HELP_REQUEST_BODY_CHARS", 4_000)
LOCAL_AI_LOCK = threading.Lock()
MODEL_CONTEXT_KEYWORDS = {
    "accessibility",
    "applications",
    "audio",
    "check again",
    "dictation",
    "file transcription",
    "input monitoring",
    "install",
    "media",
    "microphone",
    "permission",
    "privacy",
    "setup",
    "speech model",
    "troubleshoot",
    "transcription",
    "youtube",
}
LOW_SIGNAL_HELP_WORDS = {
    "hello",
    "help",
    "hey",
    "hi",
    "please",
    "thanks",
}

try:
    from openbridge_engine.local_llm import LocalLLMError, generate_local_text
except Exception:  # pragma: no cover - source review server can run without engine imports.
    LocalLLMError = RuntimeError
    generate_local_text = None

STOPWORDS = {
    "about",
    "after",
    "again",
    "also",
    "and",
    "app",
    "are",
    "can",
    "does",
    "for",
    "from",
    "how",
    "into",
    "openbridge",
    "should",
    "that",
    "the",
    "this",
    "what",
    "when",
    "where",
    "with",
    "you",
    "your",
}


class HelpSection(dict):
    @property
    def title(self) -> str:
        return str(self["title"])

    @property
    def body(self) -> str:
        return str(self["body"])

    @property
    def anchor(self) -> str:
        return str(self["anchor"])


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    return slug or "section"


def load_sections(markdown: str) -> list[HelpSection]:
    sections: list[HelpSection] = []
    current_title = "Openbridge Help"
    current_lines: list[str] = []

    for line in markdown.splitlines():
        heading = re.match(r"^(#{2,3})\s+(.+?)\s*$", line)
        if heading:
            body = "\n".join(current_lines).strip()
            if body:
                sections.append(
                    HelpSection(
                        title=current_title,
                        body=body,
                        anchor=slugify(current_title),
                    )
                )
            current_title = heading.group(2).strip()
            current_lines = []
        else:
            current_lines.append(line)

    body = "\n".join(current_lines).strip()
    if body:
        sections.append(
            HelpSection(
                title=current_title,
                body=body,
                anchor=slugify(current_title),
            )
        )
    return sections


def tokens(value: str) -> set[str]:
    return {
        token
        for token in re.findall(r"[a-z0-9']+", value.lower())
        if len(token) >= 3 and token not in STOPWORDS
    }


def retrieve_sections(question: str, sections: list[HelpSection], *, limit: int = 5) -> list[tuple[int, HelpSection]]:
    query_tokens = tokens(question)
    scored: list[tuple[int, HelpSection]] = []
    for section in sections:
        title_tokens = tokens(section.title)
        body_tokens = tokens(section.body)
        score = len(query_tokens & body_tokens) + (3 * len(query_tokens & title_tokens))
        for token in query_tokens:
            if len(token) >= 4 and token in section.title.lower():
                score += 2
        scored.append((score, section))
    scored.sort(key=lambda item: item[0], reverse=True)
    useful = [item for item in scored if item[0] > 0]
    return (useful or scored)[:limit]


def asks_for_live_setup_check(question: str) -> bool:
    value = question.lower()
    personal_setup_words = {
        "actual",
        "current",
        "mine",
        "my",
        "setup",
        "this mac",
    }
    inspection_words = {
        "check",
        "detect",
        "diagnose",
        "explain",
        "fix",
        "granted",
        "inspect",
        "is enabled",
        "is working",
        "permission",
        "see if",
        "summary",
        "tell whether",
        "what is wrong",
        "what's wrong",
    }
    return any(word in value for word in personal_setup_words) and any(
        word in value for word in inspection_words
    )


def strip_markdown(value: str) -> str:
    value = re.sub(r"`([^`]+)`", r"\1", value)
    value = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", value)
    value = re.sub(r"^\s*[-*]\s+", "- ", value, flags=re.MULTILINE)
    value = re.sub(r"^\s*\|.*\|\s*$", "", value, flags=re.MULTILINE)
    value = re.sub(r"\n{3,}", "\n\n", value)
    return value.strip()


def section_excerpt(section: HelpSection, *, max_chars: int = 1400) -> str:
    body = section.body.strip()
    if len(body) <= max_chars:
        return body
    return body[:max_chars].rsplit("\n", 1)[0].strip() + "\n..."


def truncate_text(value: str, max_chars: int) -> str:
    if len(value) <= max_chars:
        return value
    return value[:max_chars].rsplit("\n", 1)[0].strip() + "\n..."


def local_ai_enabled() -> bool:
    return os.environ.get(HELP_LOCAL_AI_ENV_KEY, "1").strip().lower() not in {"0", "false", "no", "off"}


def normalize_question(question: str) -> str:
    cleaned = " ".join(question.split())
    if not cleaned:
        raise ValueError("Question is required.")
    if len(cleaned) > HELP_QUESTION_CHARS:
        raise ValueError(f"Question is too long. Keep Help questions under {HELP_QUESTION_CHARS} characters.")
    return cleaned


def is_low_signal_question(question: str) -> bool:
    query_tokens = tokens(question)
    if not query_tokens:
        return True
    return query_tokens <= LOW_SIGNAL_HELP_WORDS


def model_context_allowed(section: HelpSection) -> bool:
    haystack = f"{section.title}\n{section.body}".lower()
    return any(keyword in haystack for keyword in MODEL_CONTEXT_KEYWORDS)


def model_context_sections(matched: list[tuple[int, HelpSection]]) -> list[tuple[int, HelpSection]]:
    allowed = [item for item in matched if item[0] > 0 and model_context_allowed(item[1])]
    return allowed[:HELP_MODEL_CONTEXT_SECTION_LIMIT]


def load_setup_diagnostics() -> dict[str, object] | None:
    path = os.environ.get(SETUP_DIAGNOSTICS_ENV_KEY, "").strip()
    if not path:
        return None
    try:
        with Path(path).expanduser().open(encoding="utf-8") as handle:
            data = json.load(handle)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def nested_value(data: dict[str, object], *keys: str, default: object = None) -> object:
    current: object = data
    for key in keys:
        if not isinstance(current, dict) or key not in current:
            return default
        current = current[key]
    return current


def as_bool(value: object) -> bool:
    return value is True


def setup_diagnostics_available(data: dict[str, object] | None) -> bool:
    return isinstance(data, dict) and nested_value(data, "schemaVersion") == 1


def setup_diagnostics_context(data: dict[str, object] | None) -> str:
    if not setup_diagnostics_available(data):
        return "No live setup diagnostics were provided. Answer only from the static help guide."
    return truncate_text(json.dumps(data, indent=2, sort_keys=True), HELP_DIAGNOSTICS_CONTEXT_CHARS)


def setup_visibility_summary(data: dict[str, object] | None) -> dict[str, object]:
    if not setup_diagnostics_available(data):
        return {
            "available": False,
            "summary": "Help was opened without a live setup summary.",
            "includedData": [],
            "excludedData": [],
        }
    return {
        "available": True,
        "summary": nested_value(data, "privacy", "summary", default="Setup state only."),
        "includedData": nested_value(data, "privacy", "includedData", default=[]),
        "excludedData": nested_value(data, "privacy", "excludedData", default=[]),
    }


def setup_status_lines(data: dict[str, object] | None) -> list[str]:
    if not setup_diagnostics_available(data):
        return ["Live setup summary is unavailable."]

    missing_permissions = nested_value(data, "readiness", "missingPermissions", default=[])
    if not isinstance(missing_permissions, list):
        missing_permissions = []

    lines = [
        f"Dictation ready: {'yes' if as_bool(nested_value(data, 'readiness', 'readyForDictation')) else 'no'}",
        f"Media transcription ready: {'yes' if as_bool(nested_value(data, 'readiness', 'readyForMediaTranscription')) else 'no'}",
        f"Install location: {nested_value(data, 'app', 'installLocation', default='Unknown')}",
        f"Selected microphone: {nested_value(data, 'microphone', 'selectedName', default='Unknown')}",
        (
            "Selected speech model: "
            f"{nested_value(data, 'speechModel', 'selectedDisplayName', default='Unknown')} "
            f"({'installed' if as_bool(nested_value(data, 'speechModel', 'selectedInstalled')) else 'not installed'})"
        ),
        f"Local AI cleanup: {nested_value(data, 'localAI', 'cleanupMode', default='Unknown')}",
        f"History setting: {nested_value(data, 'history', 'retentionMode', default='Unknown')}",
        f"Current status: {nested_value(data, 'activity', 'statusMessage', default='Unknown')}",
    ]
    if missing_permissions:
        lines.insert(2, f"Missing permissions: {', '.join(map(str, missing_permissions))}")
    return lines


def setup_recommendations(data: dict[str, object] | None) -> list[str]:
    if not setup_diagnostics_available(data):
        return ["Open Help from the Openbridge app so it can attach a local setup summary."]

    recommendations: list[str] = []
    install_location = str(nested_value(data, "app", "installLocation", default=""))
    if install_location in {"Mounted disk image", "Downloads"}:
        recommendations.append("Move Openbridge to Applications, then reopen it from there before granting permissions.")

    permissions = nested_value(data, "permissions", default=[])
    if isinstance(permissions, list):
        for permission in permissions:
            if not isinstance(permission, dict):
                continue
            if permission.get("state") != "Granted":
                title = str(permission.get("title", "permission"))
                if permission.get("needsFollowUp"):
                    recommendations.append(f"Return from System Settings and press Check again for {title}.")
                else:
                    recommendations.append(f"Grant {title} permission from Openbridge Settings.")

    if not as_bool(nested_value(data, "speechModel", "selectedInstalled")):
        model_name = nested_value(data, "speechModel", "selectedDisplayName", default="the selected speech model")
        recommendations.append(f"Install {model_name} before dictation or media transcription.")

    microphone_count = nested_value(data, "microphone", "availableInputCount", default=0)
    if isinstance(microphone_count, int) and microphone_count == 0:
        recommendations.append("Connect or enable a microphone input in macOS Sound settings.")

    microphone_message = str(nested_value(data, "microphone", "diagnosticsMessage", default="")).lower()
    if "no input detected" in microphone_message:
        recommendations.append("Try System Default or another microphone, then speak once while watching the meter.")

    ffmpeg_available = nested_value(data, "media", "ffmpegAvailable")
    if ffmpeg_available is False:
        recommendations.append("Media and YouTube transcription need the bundled or locally installed ffmpeg helper.")

    if not recommendations:
        recommendations.append("The main setup checks look ready. If something still fails, try the exact workflow again and note the status message.")

    deduped: list[str] = []
    for recommendation in recommendations:
        if recommendation not in deduped:
            deduped.append(recommendation)
    return deduped


def setup_diagnostic_answer(question: str, matched: list[tuple[int, HelpSection]], data: dict[str, object]) -> str:
    status_text = "\n".join(f"- {line}" for line in setup_status_lines(data))
    recommendation_text = "\n".join(f"- {item}" for item in setup_recommendations(data))
    privacy_summary = nested_value(data, "privacy", "summary", default="This uses setup state only.")
    related = ", ".join(section.title for _, section in matched[:3])

    return (
        "Here is what I can see from your local Openbridge setup summary.\n\n"
        f"{status_text}\n\n"
        "Suggested next steps:\n"
        f"{recommendation_text}\n\n"
        f"Privacy boundary: {privacy_summary}\n\n"
        f"Related help topics: {related}."
    )


def build_model_prompt(
    question: str,
    matched: list[tuple[int, HelpSection]],
    diagnostics: dict[str, object] | None = None,
) -> str:
    system_prompt = read_text(PROMPT_PATH)
    model_sections = model_context_sections(matched)
    excerpts = "\n\n".join(
        f"## {section.title}\n{section_excerpt(section, max_chars=HELP_MODEL_CONTEXT_SECTION_CHARS)}"
        for _, section in model_sections
    ) or "No focused local Help excerpt matched this question strongly enough for local AI."
    diagnostics_context = setup_diagnostics_context(diagnostics)
    return truncate_text(
        f"{system_prompt}\n\n"
        "LIVE_SETUP_DIAGNOSTICS:\n"
        f"{diagnostics_context}\n\n"
        "Use LIVE_SETUP_DIAGNOSTICS only when it is provided. Do not invent setup facts that are not present. "
        "Never claim to inspect transcript text, audio, selected text, snippets, media file contents, or saved history contents.\n\n"
        "RELEVANT_HELP_EXCERPTS:\n"
        f"{excerpts}\n\n"
        "USER_QUESTION:\n"
        f"{question.strip()}\n\n"
        "Answer now as Openbridge Help.",
        HELP_MODEL_PROMPT_CHARS,
    )


def apply_terminal_edits(value: str) -> str:
    output: list[str] = []
    index = 0
    while index < len(value):
        if value[index] == "\x1b":
            clear_match = re.match(r"\x1b\[(\d+)D\x1b\[K", value[index:])
            if clear_match:
                count = int(clear_match.group(1))
                while count > 0 and output and output[-1] not in {"\n", "\r"}:
                    output.pop()
                    count -= 1
                index += clear_match.end()
                continue

            escape_match = ANSI_ESCAPE_PATTERN.match(value, index)
            if escape_match:
                index = escape_match.end()
                continue

        output.append(value[index])
        index += 1
    return "".join(output)


def unwrap_hard_wrapped_markdown(value: str) -> str:
    paragraphs = re.split(r"\n{2,}", value.strip())
    unwrapped: list[str] = []

    for paragraph in paragraphs:
        lines = [line.strip() for line in paragraph.splitlines() if line.strip()]
        if not lines:
            continue

        rendered_lines: list[str] = []
        current: list[str] = []
        for line in lines:
            if re.match(r"^(?:[-*]|\d+\.)\s+", line):
                if current:
                    rendered_lines.append(" ".join(current))
                current = [line]
            else:
                current.append(line)
        if current:
            rendered_lines.append(" ".join(current))
        unwrapped.append("\n".join(rendered_lines))

    return "\n\n".join(unwrapped)


def clean_ollama_output(value: str) -> str:
    value = apply_terminal_edits(value)
    value = ANSI_ESCAPE_PATTERN.sub("", value)
    value = re.sub(r"\x1b\][^\a]*(?:\a|\x1b\\)", "", value)
    value = value.replace("\r", "")
    value = re.sub(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]", "", value)
    value = re.sub(r"(?is)<think>.*?</think>", "", value)
    marker = re.search(r"(?is)\.\.\.\s*done thinking\.?", value)
    if marker:
        value = value[marker.end():]
    value = re.sub(r"\n{3,}", "\n\n", value)
    return unwrap_hard_wrapped_markdown(value)


def parse_ollama_size_gb(value: str) -> float:
    match = re.search(r"(?i)(\d+(?:\.\d+)?)\s*(KB|MB|GB|TB)", value)
    if not match:
        return 0.0

    amount = float(match.group(1))
    unit = match.group(2).upper()
    if unit == "KB":
        return amount / (1024 * 1024)
    if unit == "MB":
        return amount / 1024
    if unit == "TB":
        return amount * 1024
    return amount


def gemma_parameter_billions(model_name: str) -> float:
    matches = re.findall(r"(?i)e?(\d+(?:\.\d+)?)b", model_name)
    if not matches:
        return 0.0
    return max(float(match) for match in matches)


def installed_ollama_models() -> tuple[list[dict[str, object]], str | None]:
    executable = shutil.which("ollama")
    if executable is None:
        return [], "Ollama is not installed or is not on PATH. Showing the grounded fallback answer."

    try:
        proc = subprocess.run(
            [executable, "list"],
            capture_output=True,
            text=True,
            timeout=8,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return [], "Ollama did not respond while listing models. Showing the grounded fallback answer."

    if proc.returncode != 0:
        details = (proc.stderr or proc.stdout or "Unknown Ollama error.").strip()
        return [], f"Ollama could not list local models: {details[:240]}"

    models: list[dict[str, object]] = []
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if not parts:
            continue
        size_text = " ".join(parts[2:4]) if len(parts) >= 4 else ""
        models.append(
            {
                "name": parts[0],
                "sizeGb": parse_ollama_size_gb(size_text),
            }
        )
    return models, None


def select_largest_gemma_model() -> tuple[str | None, str]:
    models, error = installed_ollama_models()
    gemma_models = [model for model in models if "gemma" in str(model["name"]).lower()]
    if not gemma_models:
        return None, error or "No installed local Gemma model was found. Showing the grounded fallback answer."

    gemma_models.sort(
        key=lambda model: (
            gemma_parameter_billions(str(model["name"])),
            float(model["sizeGb"]),
            str(model["name"]),
        ),
        reverse=True,
    )
    model_name = str(gemma_models[0]["name"])
    return model_name, f"Using largest installed local Gemma model: {model_name}."


def call_ollama(prompt: str, model: str, *, timeout: float = HELP_LOCAL_AI_TIMEOUT_SECONDS) -> tuple[str | None, str]:
    executable = shutil.which("ollama")
    if executable is None:
        return None, "Ollama is not installed or is not on PATH. Showing the grounded fallback answer."

    cmd = [
        executable,
        "run",
        model,
        "--think",
        "false",
        "--hidethinking",
    ]
    try:
        proc = subprocess.run(
            cmd,
            input=prompt,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "Ollama timed out. Showing the grounded fallback answer."

    if proc.returncode != 0:
        details = (proc.stderr or proc.stdout or "Unknown Ollama error.").strip()
        return None, f"Ollama was unavailable: {details[:240]}"

    answer = clean_ollama_output(proc.stdout)
    if not answer:
        return None, "Ollama returned an empty answer. Showing the grounded fallback answer."
    return answer, f"Answered with local Gemma model: {model}."


def call_largest_gemma(prompt: str) -> tuple[str | None, str]:
    model, selection_status = select_largest_gemma_model()
    if model is None:
        return None, selection_status

    answer, engine_status = call_ollama(prompt, model, timeout=HELP_LOCAL_AI_TIMEOUT_SECONDS)
    if answer:
        return answer, engine_status
    return None, f"{selection_status} {engine_status}"


def call_local_ai_direct(prompt: str) -> tuple[str | None, str]:
    if generate_local_text is not None:
        try:
            result = generate_local_text(
                prompt,
                provider="auto",
                max_tokens=HELP_LOCAL_AI_MAX_TOKENS,
                timeout_seconds=HELP_LOCAL_AI_TIMEOUT_SECONDS,
            )
            if result.text.strip():
                return result.text.strip(), f"Answered with local {result.provider} model: {result.model}."
        except LocalLLMError as exc:
            details = getattr(exc, "details", None) or str(exc)
            return None, f"Local AI was unavailable: {details[:240]}"
        except Exception as exc:
            return None, f"Local AI was unavailable: {str(exc)[:240]}"

    return call_largest_gemma(prompt)


def run_local_ai_once() -> int:
    try:
        payload = json.loads(sys.stdin.read() or "{}")
        prompt = str(payload.get("prompt", "")).strip()
        if not prompt:
            raise ValueError("Prompt is required.")
        answer, status = call_local_ai_direct(prompt)
        print(
            json.dumps(
                {
                    "ok": bool(answer),
                    "answer": answer or "",
                    "engineStatus": status,
                },
                sort_keys=True,
            )
        )
        return 0
    except Exception as exc:
        print(
            json.dumps(
                {
                    "ok": False,
                    "answer": "",
                    "engineStatus": f"Local AI failed safely: {str(exc)[:240]}",
                },
                sort_keys=True,
            )
        )
        return 1


def call_local_ai_subprocess(prompt: str) -> tuple[str | None, str]:
    command = [sys.executable, str(Path(__file__).resolve()), "--local-ai-once"]
    try:
        proc = subprocess.run(
            command,
            input=json.dumps({"prompt": prompt}),
            capture_output=True,
            text=True,
            timeout=HELP_LOCAL_AI_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, f"Local AI timed out after {HELP_LOCAL_AI_TIMEOUT_SECONDS:g} seconds. Showing the grounded fallback answer."
    except Exception as exc:
        return None, f"Local AI could not start safely: {str(exc)[:240]}"

    try:
        payload = json.loads(proc.stdout or "{}")
    except json.JSONDecodeError:
        return None, "Local AI returned an unreadable response. Showing the grounded fallback answer."

    answer = str(payload.get("answer", "")).strip()
    status = str(payload.get("engineStatus", "")).strip()
    if proc.returncode == 0 and answer:
        return answer, status or "Answered with local AI."
    return None, status or "Local AI had no grounded answer. Showing the fallback guide."


def call_local_ai(prompt: str) -> tuple[str | None, str]:
    if not local_ai_enabled():
        return None, "Local AI Help is off. Showing the grounded fallback answer."
    if not LOCAL_AI_LOCK.acquire(blocking=False):
        return None, "Local Help is already thinking locally. Showing the grounded fallback answer."
    try:
        return call_local_ai_subprocess(prompt)
    finally:
        LOCAL_AI_LOCK.release()


def setup_boundary_answer(question: str, matched: list[tuple[int, HelpSection]]) -> str:
    lower_question = question.lower()
    if "microphone" in lower_question:
        manual_check = (
            "Open Openbridge Settings, look at the Permissions card for Microphone, "
            "then look at the Microphone card and speak once. The live meter should move."
        )
    elif "accessibility" in lower_question:
        manual_check = (
            "Open Openbridge Settings and look at the Permissions card for Accessibility. "
            "If it is not granted, use the permission button, turn Openbridge on in System Settings, "
            "then return and press Check again."
        )
    elif "input" in lower_question or "monitoring" in lower_question or "shortcut" in lower_question:
        manual_check = (
            "Open Openbridge Settings and look at the Permissions card for Input Monitoring. "
            "If it is not granted, use the permission button, turn Openbridge on in System Settings, "
            "then return and press Check again."
        )
    else:
        manual_check = (
            "Open Openbridge Settings and look at the Permissions card. For any permission that is not granted, "
            "use the permission button, change the setting in System Settings, then return and press Check again."
        )

    related = [section.title for _, section in matched[:3]]
    related_text = ", ".join(related)
    return (
        "This version of Openbridge Help cannot inspect your current setup yet. "
        f"{manual_check}\n\n"
        "Setup-aware diagnosis is planned separately, so for now I can explain where to check rather than read your Mac directly."
        f"\n\nRelated help topics: {related_text}."
    )


def topic_prompt_answer() -> str:
    return (
        "Hi. Ask me about setup, permissions, dictation, Command Mode, audio or video transcription, "
        "YouTube, privacy, or beta feedback.\n\n"
        "For example: \"How do I finish setup?\" or \"What should I send as beta feedback?\""
    )


def fallback_answer(
    question: str,
    matched: list[tuple[int, HelpSection]],
    diagnostics: dict[str, object] | None = None,
) -> str:
    if is_low_signal_question(question):
        return topic_prompt_answer()

    if asks_for_live_setup_check(question):
        if setup_diagnostics_available(diagnostics):
            return setup_diagnostic_answer(question, matched, diagnostics)
        return setup_boundary_answer(question, matched)

    best_score, best_section = matched[0]
    if best_score == 0:
        return (
            "I do not know that from the local Openbridge help guide yet.\n\n"
            "The closest useful starting point is the Help overview. Try asking about installing, permissions, "
            "dictation, Command Mode, media transcription, YouTube, privacy, or beta feedback."
        )

    excerpt = strip_markdown(section_excerpt(best_section, max_chars=1100))
    related = [section.title for _, section in matched[1:4]]
    related_text = ", ".join(related)
    suffix = f"\n\nRelated help topics: {related_text}." if related_text else ""
    return (
        f"From the local Openbridge help guide, the most relevant section is \"{best_section.title}.\"\n\n"
        f"{excerpt}"
        f"{suffix}"
    )


def should_try_local_ai(question: str, matched: list[tuple[int, HelpSection]]) -> tuple[bool, str]:
    if is_low_signal_question(question):
        return False, "Showing the guide-based Help topic prompt."
    if not local_ai_enabled():
        return False, "Local AI Help is off. Showing the grounded fallback answer."
    if not model_context_sections(matched):
        return False, "This question is outside the bounded local AI context. Showing the grounded fallback answer."
    if len(question) > HELP_QUESTION_CHARS:
        return False, "The question is too long for local AI Help. Showing the grounded fallback answer."
    return True, "Thinking locally with a bounded Help context."


def fallback_status_for_user(engine_status: str, *, used_fallback: bool) -> str:
    if not used_fallback:
        return ""

    status = engine_status.lower()
    if not status or status.startswith("thinking locally"):
        return ""
    if "topic prompt" in status:
        return ""
    if "timed out" in status or "too long" in status:
        return "Using guide-based Help because local AI Help took too long."
    if "already thinking" in status:
        return "Using guide-based Help because another local answer is still running."
    if "off" in status:
        return "Using guide-based Help because local AI Help is turned off."
    if "outside" in status:
        return "Using guide-based Help for this question."
    if "question is too long" in status:
        return "Using guide-based Help because the question is too long for local AI Help."
    return "Using guide-based Help because local AI Help is unavailable right now."


def answer_question(question: str) -> dict[str, object]:
    question = normalize_question(question)
    knowledge = read_text(KNOWLEDGE_PATH)
    sections = load_sections(knowledge)
    matched = retrieve_sections(question, sections)
    diagnostics = load_setup_diagnostics()
    fallback = fallback_answer(question, matched, diagnostics)
    prompt = ""

    answer = fallback
    used_fallback = True
    should_generate, engine_status = should_try_local_ai(question, matched)
    if should_generate:
        prompt = build_model_prompt(question, matched, diagnostics)
        gemma_answer, engine_status = call_local_ai(prompt)
        if gemma_answer:
            answer = gemma_answer
            used_fallback = False

    payload: dict[str, object] = {
        "answer": answer,
        "engineStatus": engine_status,
        "fallbackStatus": fallback_status_for_user(engine_status, used_fallback=used_fallback),
        "usedFallback": used_fallback,
        "requestTimeoutSeconds": HELP_REQUEST_TIMEOUT_SECONDS,
        "diagnostics": setup_visibility_summary(diagnostics),
        "setupStatus": setup_status_lines(diagnostics),
        "setupRecommendations": setup_recommendations(diagnostics),
        "matchedSections": [
            {
                "title": section.title,
                "score": score,
                "excerpt": strip_markdown(section_excerpt(section, max_chars=420)),
            }
            for score, section in matched
        ],
    }
    if os.environ.get("OPENBRIDGE_HELP_DEBUG_PROMPT", "").strip() == "1":
        payload["promptPreview"] = prompt
    return payload


def page_html() -> str:
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Cache-Control" content="no-store, no-cache, must-revalidate, max-age=0">
  <meta http-equiv="Pragma" content="no-cache">
  <meta http-equiv="Expires" content="0">
  <title>Openbridge Help Review</title>
  <style>
    :root {{
      --ink: #142034;
      --muted: #5d6c81;
      --canvas: #f6f9fd;
      --card: #ffffff;
      --border: #cbd8e8;
      --blue: #2367d8;
      --teal: #1aa39a;
      --gold: #f6c84c;
      --cool: #edf3ff;
      --shadow: 0 24px 70px rgba(20, 32, 52, 0.10);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      background: linear-gradient(135deg, #ffffff 0%, var(--canvas) 46%, #eef5ff 100%);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }}
    .shell {{
      display: grid;
      grid-template-columns: 300px minmax(0, 1fr);
      min-height: 100vh;
    }}
    aside {{
      padding: 24px;
      border-right: 1px solid var(--border);
      background: rgba(255, 255, 255, 0.68);
    }}
    main {{
      display: grid;
      grid-template-rows: auto 1fr auto;
      min-width: 0;
      padding: 28px;
    }}
    .brand {{
      display: flex;
      gap: 12px;
      align-items: center;
      margin-bottom: 18px;
    }}
    .mark {{
      width: 44px;
      height: 44px;
      flex: 0 0 auto;
    }}
    h1, h2, h3 {{ margin: 0; }}
    h1 {{ font-size: 30px; line-height: 1.08; letter-spacing: 0; }}
    h2 {{ font-size: 18px; }}
    h3 {{ font-size: 14px; }}
    p {{ color: var(--muted); line-height: 1.45; }}
    .pill {{
      display: inline-flex;
      align-items: center;
      gap: 7px;
      padding: 7px 10px;
      border: 1px solid rgba(26, 163, 154, 0.30);
      border-radius: 999px;
      background: rgba(26, 163, 154, 0.10);
      color: var(--ink);
      font-size: 12px;
      font-weight: 800;
    }}
    .topics {{
      display: grid;
      gap: 8px;
      margin-top: 18px;
    }}
    .setup-panel {{
      margin-top: 18px;
      padding: 12px;
      border: 1px solid rgba(35, 103, 216, 0.22);
      border-radius: 12px;
      background: rgba(237, 243, 255, 0.72);
    }}
    .setup-panel h3 {{
      margin-bottom: 8px;
    }}
    .setup-list {{
      display: grid;
      gap: 6px;
      margin: 0;
      padding: 0;
      list-style: none;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.35;
    }}
    .topic, .question {{
      width: 100%;
      text-align: left;
      padding: 10px;
      border: 1px solid rgba(203, 216, 232, 0.88);
      border-radius: 10px;
      background: rgba(255, 255, 255, 0.86);
      color: var(--ink);
      font: inherit;
      font-size: 13px;
      font-weight: 700;
      cursor: pointer;
    }}
    .question {{
      font-weight: 650;
      color: var(--muted);
    }}
    .header {{
      display: flex;
      align-items: flex-start;
      justify-content: space-between;
      gap: 20px;
      padding-bottom: 18px;
    }}
    .header p {{ max-width: 680px; margin-bottom: 0; }}
    .messages {{
      display: grid;
      gap: 14px;
      align-content: start;
      overflow: auto;
      padding: 0 0 18px;
    }}
    .message {{
      max-width: 780px;
      padding: 14px;
      border: 1px solid rgba(203, 216, 232, 0.86);
      border-radius: 14px;
      background: rgba(255, 255, 255, 0.90);
      box-shadow: 0 12px 34px rgba(20, 32, 52, 0.06);
      white-space: pre-wrap;
      line-height: 1.45;
      font-size: 14px;
    }}
    .message.user {{
      justify-self: end;
      max-width: 620px;
      border-color: rgba(35, 103, 216, 0.32);
      background: rgba(237, 243, 255, 0.94);
    }}
    .status {{
      margin-top: 8px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
    }}
    .composer {{
      display: grid;
      grid-template-columns: 1fr auto auto;
      gap: 10px;
      align-items: center;
      padding: 10px;
      border: 1px solid var(--border);
      border-radius: 14px;
      background: rgba(255, 255, 255, 0.94);
      box-shadow: 0 12px 34px rgba(20, 32, 52, 0.06);
    }}
    input[type="text"] {{
      width: 100%;
      border: 0;
      outline: 0;
      background: transparent;
      color: var(--ink);
      font: inherit;
      font-size: 14px;
    }}
    button.send {{
      min-height: 36px;
      padding: 0 16px;
      border: 0;
      border-radius: 9px;
      background: var(--ink);
      color: white;
      font-weight: 800;
      cursor: pointer;
    }}
    button.send.cancel {{
      border: 1px solid var(--border);
      background: #ffffff;
      color: var(--ink);
    }}
    button:disabled, input:disabled {{
      cursor: wait;
      opacity: 0.62;
    }}
    label {{
      display: inline-flex;
      align-items: center;
      gap: 7px;
      color: var(--muted);
      font-size: 12px;
      font-weight: 700;
      white-space: nowrap;
    }}
    @media (max-width: 1180px) {{
      .shell {{ grid-template-columns: 1fr; }}
      aside {{ max-height: none; border: 0; border-bottom: 1px solid var(--border); }}
    }}
  </style>
</head>
<body>
  <div class="shell">
    <aside>
      <div class="brand">
        <svg class="mark" viewBox="0 0 128 128" role="img" aria-label="Openbridge icon">
          <circle cx="64" cy="64" r="48" fill="none" stroke="#142034" stroke-width="5" stroke-linecap="round"/>
          <path d="M64 93v23" fill="none" stroke="#142034" stroke-width="5" stroke-linecap="round"/>
          <rect x="45" y="29" width="38" height="66" rx="19" fill="#f6c84c" stroke="#142034" stroke-width="5"/>
          <circle cx="56" cy="57" r="2.5" fill="#142034" opacity=".18"/>
          <circle cx="72" cy="57" r="2.5" fill="#142034" opacity=".18"/>
          <path d="M55 74c0 12 18 12 18 0" fill="none" stroke="#142034" stroke-width="2.25" stroke-linecap="round" opacity=".2"/>
        </svg>
        <div>
          <h2>Openbridge Help</h2>
        </div>
      </div>
      <p>If you are having trouble using Openbridge then help is at hand. This local assistant can use the Help guide plus a privacy-safe setup summary from the app.</p>
      <div class="topics">
        <button class="topic" data-question="Explain my current Openbridge setup and what I should fix first.">Explain my setup</button>
        <button class="topic" data-question="How do I start dictation?">Getting started</button>
        <button class="topic" data-question="Why do I have to move Openbridge to Applications?">Install</button>
        <button class="topic" data-question="Why do I have to press Check again after permissions?">Permissions</button>
        <button class="topic" data-question="What does Command Mode do?">Command Mode</button>
        <button class="topic" data-question="How do I transcribe a YouTube video?">YouTube</button>
        <button class="topic" data-question="Is my audio sent anywhere?">Privacy</button>
      </div>
      <div class="setup-panel">
        <h3>Setup summary</h3>
        <ul class="setup-list" id="setupSummary">
          <li>Loading local setup summary...</li>
        </ul>
      </div>
    </aside>
    <main>
      <div class="header">
        <div>
          <h1>Ask how Openbridge works</h1>
        </div>
      </div>
      <div class="messages" id="messages"></div>
      <form class="composer" id="askForm">
        <input id="question" type="text" placeholder="Please ask anything..." aria-label="Ask Openbridge Help anything" autocomplete="off">
        <button class="send" type="submit">Ask</button>
      </form>
    </main>
  </div>
  <script>
    const form = document.getElementById('askForm');
    const input = document.getElementById('question');
    const messages = document.getElementById('messages');
    const setupSummary = document.getElementById('setupSummary');
    const submitButton = form.querySelector('button[type="submit"]');
    const topicButtons = Array.from(document.querySelectorAll('[data-question]'));
    const HELP_REQUEST_TIMEOUT_MS = {int(HELP_REQUEST_TIMEOUT_SECONDS * 1000)};
    let isAsking = false;
    let currentRequest = null;

    function appendMessage(text, kind) {{
      const node = document.createElement('div');
      node.className = 'message' + (kind === 'user' ? ' user' : '');
      node.textContent = text;
      messages.appendChild(node);
      messages.scrollTop = messages.scrollHeight;
    }}

    function setBusy(isBusy) {{
      isAsking = isBusy;
      input.disabled = isBusy;
      submitButton.disabled = false;
      submitButton.textContent = isBusy ? 'Cancel' : 'Ask';
      submitButton.classList.toggle('cancel', isBusy);
      for (const button of topicButtons) {{
        button.disabled = isBusy;
      }}
    }}

    function cancelCurrentAnswer() {{
      if (!currentRequest) return;
      currentRequest.cancelledByUser = true;
      currentRequest.controller.abort();
    }}

    async function ask(question) {{
      if (isAsking) return;
      const controller = new AbortController();
      const requestState = {{
        controller,
        timedOut: false,
        cancelledByUser: false
      }};
      currentRequest = requestState;
      setBusy(true);
      appendMessage(question, 'user');
      appendMessage('Thinking locally. If local AI is slow, Openbridge will fall back to the static Help guide instead of hanging.', 'assistant');
      const pending = messages.lastElementChild;
      const timeout = window.setTimeout(() => {{
        requestState.timedOut = true;
        controller.abort();
      }}, HELP_REQUEST_TIMEOUT_MS);
      try {{
        const response = await fetch('/api/ask', {{
          method: 'POST',
          headers: {{ 'Content-Type': 'application/json' }},
          body: JSON.stringify({{ question }}),
          signal: controller.signal
        }});
        const payload = await response.json();
        if (!response.ok) {{
          throw new Error(payload.error || 'Openbridge Help could not answer that just now.');
        }}
        pending.textContent = payload.answer || 'I do not know that from the local Openbridge help guide yet.';
        if (payload.usedFallback && payload.fallbackStatus) {{
          pending.textContent += '\\n\\n' + payload.fallbackStatus;
        }}
        input.value = '';
      }} catch (error) {{
        if (error.name === 'AbortError') {{
          pending.textContent = requestState.timedOut
            ? 'Openbridge Help took too long, so I stopped waiting. Try one of the topic buttons or ask a shorter setup question.'
            : 'Cancelled. You can ask another Help question.';
        }} else {{
          pending.textContent = 'Openbridge Help could not answer that just now. Use the topic buttons for static setup, permissions, dictation, media, and privacy guidance.';
        }}
      }} finally {{
        window.clearTimeout(timeout);
        if (currentRequest === requestState) {{
          currentRequest = null;
        }}
        setBusy(false);
        input.focus();
      }}
    }}

    async function loadSetupSummary() {{
      try {{
        const response = await fetch('/api/diagnostics', {{ cache: 'no-store' }});
        const payload = await response.json();
        setupSummary.innerHTML = '';
        const diagnostics = payload.diagnostics || {{}};
        const rows = payload.setupStatus || [];
        if (!diagnostics.available) {{
          const node = document.createElement('li');
          node.textContent = 'Live setup summary unavailable. Open Help from the Openbridge app.';
          setupSummary.appendChild(node);
          return;
        }}
        for (const row of rows.slice(0, 6)) {{
          const node = document.createElement('li');
          node.textContent = row;
          setupSummary.appendChild(node);
        }}
        const privacy = document.createElement('li');
        privacy.textContent = 'No audio or transcript text is included.';
        setupSummary.appendChild(privacy);
      }} catch (error) {{
        setupSummary.innerHTML = '<li>Setup summary could not load.</li>';
      }}
    }}

    form.addEventListener('submit', (event) => {{
      event.preventDefault();
      if (isAsking) {{
        cancelCurrentAnswer();
        return;
      }}
      const question = input.value.trim();
      if (question) ask(question);
    }});

    for (const button of topicButtons) {{
      button.addEventListener('click', () => {{
        input.value = button.dataset.question;
        ask(button.dataset.question);
      }});
    }}

    loadSetupSummary();
  </script>
</body>
</html>"""


class HelpReviewHandler(BaseHTTPRequestHandler):
    server_version = "OpenbridgeHelpReview/1.0"

    def do_HEAD(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/help"}:
            self.send_html(page_html(), include_body=False)
            return
        if parsed.path == "/knowledge.md":
            self.send_text(read_text(KNOWLEDGE_PATH), content_type="text/markdown; charset=utf-8", include_body=False)
            return
        if parsed.path == "/system-prompt.md":
            self.send_text(read_text(PROMPT_PATH), content_type="text/markdown; charset=utf-8", include_body=False)
            return
        if parsed.path == "/favicon.ico":
            self.send_no_content()
            return
        self.send_error(404)

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path in {"/", "/help"}:
            self.send_html(page_html())
            return
        if parsed.path == "/knowledge.md":
            self.send_text(read_text(KNOWLEDGE_PATH), content_type="text/markdown; charset=utf-8")
            return
        if parsed.path == "/system-prompt.md":
            self.send_text(read_text(PROMPT_PATH), content_type="text/markdown; charset=utf-8")
            return
        if parsed.path == "/api/diagnostics":
            diagnostics = load_setup_diagnostics()
            self.send_json(
                {
                    "diagnostics": setup_visibility_summary(diagnostics),
                    "setupStatus": setup_status_lines(diagnostics),
                    "setupRecommendations": setup_recommendations(diagnostics),
                }
            )
            return
        if parsed.path == "/favicon.ico":
            self.send_no_content()
            return
        self.send_error(404)

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        if parsed.path != "/api/ask":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > HELP_REQUEST_BODY_CHARS:
                raise ValueError("Question payload is too large.")
            data = json.loads(self.rfile.read(length) or b"{}")
            question = normalize_question(str(data.get("question", "")))
        except Exception as exc:
            self.send_json({"error": str(exc)}, status=400)
            return

        try:
            payload = answer_question(question)
        except Exception as exc:
            payload = {
                "answer": (
                    "Openbridge Help could not load the local guide just now.\n\n"
                    "Try the setup basics: move Openbridge to Applications, open Settings, check permissions, "
                    "then try dictation again. If Help keeps failing, send beta feedback with what you clicked."
                ),
                "engineStatus": f"Help failed safely: {str(exc)[:240]}",
                "usedFallback": True,
                "diagnostics": setup_visibility_summary(None),
                "setupStatus": setup_status_lines(None),
                "setupRecommendations": setup_recommendations(None),
                "matchedSections": [],
            }

        self.send_json(payload)

    def send_html(self, body: str, *, include_body: bool = True) -> None:
        self.send_text(body, content_type="text/html; charset=utf-8", include_body=include_body)

    def send_text(self, body: str, *, content_type: str, include_body: bool = True) -> None:
        encoded = body.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        self.end_headers()
        if include_body:
            try:
                self.wfile.write(encoded)
            except (BrokenPipeError, ConnectionResetError):
                return

    def send_json(self, payload: dict[str, object], *, status: int = 200) -> None:
        encoded = json.dumps(payload, indent=2).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        try:
            self.wfile.write(encoded)
        except (BrokenPipeError, ConnectionResetError):
            return

    def send_no_content(self) -> None:
        self.send_response(204)
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.end_headers()

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} - {format % args}", file=sys.stderr)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Serve the local Openbridge Help review page.")
    parser.add_argument("--local-ai-once", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args(argv)

    if args.local_ai_once:
        return run_local_ai_once()

    if not KNOWLEDGE_PATH.exists() or not PROMPT_PATH.exists():
        print("Help knowledge or prompt file is missing.", file=sys.stderr)
        return 1

    server = ThreadingHTTPServer((args.host, args.port), HelpReviewHandler)
    print(f"Openbridge Help review running at http://{args.host}:{args.port}/help")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping Openbridge Help review server.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
