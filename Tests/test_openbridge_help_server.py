from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
HELP_SERVER_PATH = REPO_ROOT / "scripts" / "openbridge_help_review_server.py"

spec = importlib.util.spec_from_file_location("openbridge_help_review_server", HELP_SERVER_PATH)
help_server = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(help_server)


def sample_diagnostics() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "generatedAt": "2026-05-18T12:00:00Z",
        "privacy": {
            "summary": (
                "This diagnostic summary contains setup state only. It does not include audio, transcript text, "
                "selected text, snippet text, media file contents, or dictation history contents."
            ),
            "includedData": ["Permission states", "Selected microphone name"],
            "excludedData": ["Audio recordings", "Transcript text"],
        },
        "app": {
            "displayName": "Openbridge",
            "bundleIdentifier": "studio.lunr.openbridge",
            "version": "1.2.3",
            "build": "4",
            "installLocation": "Downloads",
            "installLocationDetail": "Openbridge is running from Downloads.",
            "bundlePath": "/Users/test/Downloads/OpenBridge.app",
            "launchAtLogin": False,
            "onboardingCompleted": False,
        },
        "readiness": {
            "readyForDictation": False,
            "readyForMediaTranscription": False,
            "missingPermissions": ["Microphone", "Accessibility"],
            "selectedModelInstalled": False,
            "setupMessage": "Grant Microphone and Accessibility and install Whisper Base before dictating.",
        },
        "permissions": [
            {
                "id": "microphone",
                "title": "Microphone",
                "state": "Needs attention",
                "needsFollowUp": True,
                "whyItMatters": "Needed to record your dictation audio.",
            },
            {
                "id": "accessibility",
                "title": "Accessibility",
                "state": "Needs attention",
                "needsFollowUp": False,
                "whyItMatters": "Needed to paste text into the active app.",
            },
        ],
        "speechModel": {
            "selectedIdentifier": "whisper-base",
            "selectedDisplayName": "Whisper Base",
            "selectedInstalled": False,
            "installedCount": 0,
            "availableCount": 3,
            "managedStatus": "Installing Whisper Base",
            "isInstalling": True,
            "isWarmingSelectedModel": False,
        },
        "localAI": {
            "cleanupMode": "Fast",
            "cleanupEnabled": True,
            "defaultProvider": "auto",
            "mlxAvailable": True,
            "mlxDefaultModel": "mlx-community/gemma-3-4b-it-qat-4bit",
            "ollamaAvailable": False,
        },
        "microphone": {
            "selectedName": "System Default",
            "selectedIdentifier": "system-default",
            "availableInputCount": 1,
            "meterLevel": 0,
            "diagnosticsMessage": "No input detected yet.",
            "warning": None,
        },
        "transcription": {
            "formattingEnabled": True,
            "vocabularyCorrectionsEnabled": True,
            "spokenFormattingCommandsEnabled": False,
            "pressEnterVoiceCommandEnabled": False,
        },
        "media": {
            "ready": False,
            "setupMessage": "Install Whisper Base before transcribing media.",
            "ffmpegAvailable": True,
            "isTranscribing": False,
            "lastResultAvailable": False,
        },
        "shortcuts": [{"action": "Dictation", "binding": "Right Option"}],
        "history": {
            "retentionMode": "Never store",
            "storedItemCount": 0,
            "pasteLastAvailable": False,
        },
        "activity": {
            "statusMessage": "Grant permissions before dictating.",
            "isRecording": False,
            "isTranscribing": False,
            "isTranscribingMedia": False,
            "flowBarContext": "Dictation",
            "flowBarPhase": "Hidden",
        },
    }


class OpenBridgeHelpServerTests(unittest.TestCase):
    def test_setup_question_uses_live_diagnostics_without_local_ai(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            diagnostics_path = Path(td) / "setup.json"
            diagnostics_path.write_text(json.dumps(sample_diagnostics()), encoding="utf-8")
            with patch.dict(os.environ, {help_server.SETUP_DIAGNOSTICS_ENV_KEY: str(diagnostics_path)}):
                with patch.object(help_server, "call_local_ai", return_value=(None, "fallback")):
                    payload = help_server.answer_question("Explain my current Openbridge setup.")

        answer = payload["answer"]
        self.assertIn("Dictation ready: no", answer)
        self.assertIn("Missing permissions: Microphone, Accessibility", answer)
        self.assertIn("Move Openbridge to Applications", answer)
        self.assertIn("Install Whisper Base", answer)
        self.assertIn("does not include audio, transcript text", answer)
        self.assertTrue(payload["diagnostics"]["available"])

    def test_setup_question_without_diagnostics_keeps_manual_boundary(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with patch.object(help_server, "call_local_ai", return_value=(None, "fallback")):
                payload = help_server.answer_question("Can you check my setup?")

        self.assertIn("cannot inspect your current setup yet", payload["answer"])
        self.assertFalse(payload["diagnostics"]["available"])

    def test_model_prompt_includes_live_diagnostics_boundary(self) -> None:
        diagnostics = sample_diagnostics()
        sections = help_server.load_sections(help_server.read_text(help_server.KNOWLEDGE_PATH))
        matched = help_server.retrieve_sections("Explain my current setup.", sections)

        prompt = help_server.build_model_prompt("Explain my current setup.", matched, diagnostics)

        self.assertIn("LIVE_SETUP_DIAGNOSTICS", prompt)
        self.assertIn('"installLocation": "Downloads"', prompt)
        self.assertIn("Never claim to inspect transcript text", prompt)

    def test_help_page_clears_question_input_after_successful_answer(self) -> None:
        html = help_server.page_html()
        success_assignment_index = html.index(
            "pending.textContent = payload.answer || 'I do not know that from the local Openbridge help guide yet.';"
        )
        clear_input_index = html.index("input.value = '';", success_assignment_index)
        error_assignment_index = html.index("Openbridge Help could not answer that just now.", success_assignment_index)

        self.assertLess(clear_input_index, error_assignment_index)

    def test_help_page_supports_cancel_and_client_timeout(self) -> None:
        html = help_server.page_html()

        self.assertIn("AbortController", html)
        self.assertIn("Cancel", html)
        self.assertIn("HELP_REQUEST_TIMEOUT_MS", html)
        self.assertIn("Openbridge Help took too long", html)
        self.assertIn("payload.fallbackStatus", html)
        self.assertNotIn("Status: ' + payload.engineStatus", html)

    def test_low_signal_question_returns_topic_prompt_without_local_ai(self) -> None:
        with patch.object(help_server, "call_local_ai", return_value=(None, "raw provider error")) as local_ai:
            payload = help_server.answer_question("hey")

        local_ai.assert_not_called()
        self.assertTrue(payload["usedFallback"])
        self.assertEqual(payload["fallbackStatus"], "")
        self.assertIn("Ask me about setup", payload["answer"])
        self.assertIn("beta feedback", payload["answer"])
        self.assertNotIn("Permission buttons look like", payload["answer"])

    def test_local_ai_provider_error_uses_plain_fallback_status(self) -> None:
        with patch.object(
            help_server,
            "call_local_ai",
            return_value=(
                None,
                "Ollama could not list local models: Error: could not connect to ollama server",
            ),
        ):
            payload = help_server.answer_question("How do I start dictation?")

        self.assertTrue(payload["usedFallback"])
        self.assertIn("Ollama", payload["engineStatus"])
        self.assertEqual(
            payload["fallbackStatus"],
            "Using guide-based Help because local AI Help is unavailable right now.",
        )
        self.assertNotIn("Ollama", payload["fallbackStatus"])
        self.assertIn("Dictation", payload["answer"])

    def test_model_prompt_uses_bounded_context(self) -> None:
        diagnostics = sample_diagnostics()
        sections = help_server.load_sections(help_server.read_text(help_server.KNOWLEDGE_PATH))
        matched = help_server.retrieve_sections("How do I start dictation and fix permissions?", sections, limit=12)

        prompt = help_server.build_model_prompt("How do I start dictation and fix permissions?", matched, diagnostics)

        self.assertLessEqual(len(prompt), help_server.HELP_MODEL_PROMPT_CHARS)
        self.assertIn("RELEVANT_HELP_EXCERPTS", prompt)
        self.assertLessEqual(len(help_server.model_context_sections(matched)), help_server.HELP_MODEL_CONTEXT_SECTION_LIMIT)

    def test_answer_uses_static_fallback_when_local_ai_times_out(self) -> None:
        with patch.object(
            help_server,
            "call_local_ai",
            return_value=(None, "Local AI timed out after 8 seconds. Showing the grounded fallback answer."),
        ):
            payload = help_server.answer_question("How do I start dictation?")

        self.assertTrue(payload["usedFallback"])
        self.assertIn("Local AI timed out", payload["engineStatus"])
        self.assertEqual(payload["fallbackStatus"], "Using guide-based Help because local AI Help took too long.")
        self.assertIn("Dictation", payload["answer"])

    def test_local_ai_subprocess_timeout_returns_status_without_answer(self) -> None:
        with patch.object(help_server.subprocess, "run", side_effect=subprocess.TimeoutExpired(["python"], 1)):
            answer, status = help_server.call_local_ai_subprocess("prompt")

        self.assertIsNone(answer)
        self.assertIn("timed out", status)

    def test_prompt_preview_is_hidden_by_default(self) -> None:
        with patch.object(help_server, "call_local_ai", return_value=(None, "fallback")):
            payload = help_server.answer_question("How do I start dictation?")

        self.assertNotIn("promptPreview", payload)

    def test_custom_dictionary_question_returns_settings_workflow(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with patch.object(help_server, "call_local_ai", return_value=(None, "fallback")):
                payload = help_server.answer_question("How do I add my name to the dictionary?")

        answer = payload["answer"]
        self.assertIn("most relevant section is", answer)
        self.assertIn("Custom Dictionary", answer)
        self.assertIn("Open Openbridge Settings", answer)
        self.assertIn("When Openbridge hears", answer)
        self.assertIn("trishan panch", answer)
        self.assertIn("post-transcription correction", answer)
        self.assertIn("stored locally on this Mac", answer)
        self.assertEqual(payload["matchedSections"][0]["title"], "Custom Dictionary")

    def test_spoken_formatting_question_returns_command_guidance(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with patch.object(help_server, "call_local_ai", return_value=(None, "fallback")):
                payload = help_server.answer_question("How do I dictate a new line or say period?")

        answer = payload["answer"]
        self.assertIn("Spoken Formatting", answer)
        self.assertIn("new line", answer)
        self.assertIn("period", answer)
        self.assertIn("deterministic post-processing", answer)
        self.assertEqual(payload["matchedSections"][0]["title"], "Spoken Formatting")


if __name__ == "__main__":
    unittest.main()
