# Openbridge Help Knowledge

This is the editable knowledge source for the local Openbridge Help assistant.

It is written for early testers, not developers. Use direct language. Prefer what the user should do and what they should expect to see.

## Scope Of This Help Version

This Help version can explain how Openbridge works, how to use the visible app features, and how to troubleshoot common setup problems.

When opened from the Openbridge app, Help can also use a privacy-safe setup summary. That summary can include app version, launch location, permission states, selected microphone name and meter status, selected model readiness, local AI availability, shortcut bindings, history/privacy mode, and current task status.

The setup summary does not include audio, transcript text, selected text, snippet text, media file contents, or saved dictation history contents.

If the setup summary is unavailable, Help should point the user to the right Settings area and explain what to check manually.

## What Openbridge Is

Openbridge is a local-first macOS menu bar app for voice typing and transcription.

The main workflow is:

1. Press a shortcut.
2. Speak.
3. Press the shortcut again.
4. Openbridge transcribes the audio on your Mac.
5. Openbridge pastes the text into the app where you were already working.

Openbridge is designed for people who want useful AI voice workflows without making a cloud service the default place where speech and transcripts are processed.

## What Openbridge Is Not

Openbridge is beta software.

It is not a medical device. It is not clinical decision support. It is not a substitute for reviewing the text yourself. It is not a hosted support service. It does not certify that a particular organization, workflow, or device setup is compliant with any regulation.

If you are testing in a clinical or sensitive workflow, use synthetic or non-sensitive examples unless you have independently decided that your local setup is appropriate.

## Where Openbridge Lives

Openbridge lives in the Mac menu bar, near Wi-Fi, battery, and the clock.

When it is running, look at the top-right area of the screen for the Openbridge icon and label. Click it to open the menu.

If you expected a normal app window and do not see one, that is probably okay. Openbridge is a menu bar app. The main controls are in the menu bar panel, and deeper controls are in Settings.

## Running From Source

This repository supports the contributor source path. After completing the README setup, run:

```text
make app-run
```

The source-run app can request macOS permissions under its development identity. Permissions granted to an independently installed Openbridge app may not carry over to the source-run process.

## First Launch

On first launch, Openbridge opens a setup guide.

The setup guide checks:

- whether the Mac is supported
- whether the app is running from the right place
- whether required permissions are granted
- whether the selected speech model is ready

Openbridge's local transcription build expects an Apple silicon Mac running macOS 14 or later.

## Permissions

Openbridge needs a few macOS permissions because it works across other apps.

### Microphone

Microphone permission lets Openbridge record your dictation audio.

Without Microphone permission, Openbridge cannot listen.

### Accessibility

Accessibility permission lets Openbridge paste text into the app where you are working and read selected text for Command Mode.

Without Accessibility permission, Openbridge may transcribe audio but fail to insert text into the active app.

### Input Monitoring

Input Monitoring lets Openbridge catch keyboard shortcuts while you are using other apps.

Without Input Monitoring, global shortcuts may not work reliably outside Openbridge.

## Permission Setup Is A Round Trip

macOS permission setup can feel odd. Often the flow is:

1. Openbridge asks for permission or opens System Settings.
2. You turn Openbridge on in System Settings.
3. You return to Openbridge.
4. You press `Check again`.

That does not mean Openbridge is broken. It is how macOS privacy controls often work.

Openbridge also checks again when you bring the app back to the front, but the clearest recovery step is to press `Check again`.

## If A Permission Looks Stuck

Try this:

1. Make sure you opened the exact Openbridge app you moved into Applications.
2. Open Openbridge Settings.
3. Look at the Permissions card.
4. For each permission, use `Request`, `Open`, or `Open Settings`.
5. In System Settings, turn Openbridge on.
6. Return to Openbridge and press `Check again`.

If Openbridge is not listed in the macOS privacy pane yet, use the Request/Open Settings button from Openbridge first. macOS often only lists an app after that exact app bundle asks for access.

## Main Menu Actions

The Openbridge menu gives quick access to the core actions.

### Mic Start Dictation

Starts normal dictation. Speak, then stop the recording to transcribe and paste.

### Hands-Free

Starts a longer recording mode. This is useful when you want to talk for longer before stopping. Openbridge shows elapsed time and has stop/cancel controls in the Flow Bar.

### Command Mode

Transforms selected text using a spoken instruction. Select text in another app, start Command Mode, say what change you want, then stop. Openbridge rewrites the selected text locally and replaces it.

### Paste Last

Pastes the most recent successful transcript again. This can help if you dictated something useful and want to reuse it in another place.

## Default Shortcuts

The current default shortcuts are:

| Shortcut | Action |
| --- | --- |
| Right Option | Start or stop normal dictation. |
| Control + Right Option | Start or stop hands-free dictation. |
| Control + Shift + Right Option | Cancel the current recording without pasting. |
| Shift + Right Option | Paste the most recent successful transcript again. |
| Command + Right Option | Start or stop Command Mode. |

You can change these in Settings. For this release, shortcut options stay on Right Option combinations to avoid common macOS shortcut conflicts.

## Normal Dictation

To dictate into another app:

1. Open a text field in Notes, TextEdit, Mail, your browser, or another app.
2. Put the cursor where you want text to appear.
3. Press Right Option, or click `Mic Start Dictation` in the Openbridge menu.
4. Speak normally.
5. Press Right Option again, or stop from the Flow Bar.
6. Wait while Openbridge transcribes locally.
7. The text should paste into the active app.

If text does not paste, check Accessibility permission and make sure the cursor is still in a place that accepts text.

## Flow Bar

The Flow Bar is the floating status panel that appears while Openbridge records or processes.

It shows whether Openbridge is listening, processing, finished, cancelled, or in an error state.

Use the Flow Bar stop button to finish recording. Use cancel if you want to discard the recording without pasting.

If local transcription takes more than a moment, the Flow Bar should reassure you that Openbridge is saving audio, running the local speech model, cleaning the text, and preparing to paste.

## Hands-Free Dictation

Hands-free dictation is for longer recordings.

Use Control + Right Option or the Hands-Free button in the menu.

To stop hands-free dictation, press Control + Right Option again or use the Flow Bar stop button.

To discard the recording, press Control + Shift + Right Option or use cancel in the Flow Bar.

Openbridge has a safety limit for long recordings. It should warn before automatically stopping and starting transcription.

## Command Mode

Command Mode edits selected text.

Use it when you have text selected and want Openbridge to rewrite it.

Examples:

- "Make this shorter."
- "Make this more professional."
- "Turn this into bullet points."
- "Fix the grammar."
- "Translate this into clear English."

How to use it:

1. Select text in the active app.
2. Press Command + Right Option, or choose Command Mode in the Openbridge menu.
3. Say the edit instruction.
4. Press Command + Right Option again, or stop from the Flow Bar.
5. Openbridge uses a local MLX-backed text model to transform the selected text.
6. Openbridge replaces the selected text.

Command Mode needs selected text. If no text is selected, Openbridge should show an actionable error.

## Command Presets

Command presets are quick edit buttons for selected text. They use the same transformation path as Command Mode but do not require a spoken instruction.

Current presets:

- Concise
- Professional
- Friendly
- Translate
- Summarize
- Outline
- Fix Grammar

Use a preset by selecting text, opening the Openbridge menu or Settings, and choosing the preset.

## Speech Models

Openbridge uses local Whisper models for speech-to-text.

Current curated choices include:

- Whisper Tiny: fastest, lower accuracy.
- Whisper Base: balanced default for the first beta.
- Whisper Large v3: heavier, more accurate, slower.

English is the default transcription language. This reduces the chance that Whisper misdetects a short or noisy English recording as another language.

If the selected model is not installed yet, Openbridge can install it. Model downloads require network access. Once installed, the transcription itself runs locally on the Mac.

## Local AI Models

For speech-to-text, Openbridge uses Whisper through `mlx-whisper`.

On Apple silicon, Openbridge benefits from MLX, Apple's machine-learning framework for M-series chips.

For cleanup and rewriting, Openbridge uses Gemma through `mlx-lm` by default. Command Mode uses a local MLX-backed Gemma model for selected-text transformation. Transcription cleanup can also use the same local model when enabled. Ollama is only an optional fallback provider for source builds.

The important privacy point is precise: normal speech transcription is designed to run on your Mac. Some supporting actions, such as downloading a model or fetching a YouTube audio stream, can use the network.

## Transcription Cleanup

Openbridge can clean transcripts before pasting.

Settings include:

- Formatting cleanup
- Cleanup mode: Off, Fast, or Careful

Formatting cleanup makes transcripts more readable.

Cleanup mode can use an optional local text model to polish uncertain or rough transcripts.

Custom Dictionary is separate from cleanup mode. It stores local replacement rules for recurring words and phrases after transcription.

If an optional cleanup model is unavailable, Openbridge keeps the original transcript rather than treating that as fatal.

## Custom Dictionary

Custom Dictionary fixes recurring transcription mistakes after Openbridge has already transcribed the audio, before text is pasted.

Use it for names, organizations, product names, specialty terms, and phrases that come out wrong in the same way more than once.

To add a custom dictionary entry:

1. Open Openbridge Settings.
2. Expand `Custom dictionary`.
3. Make sure `Use custom dictionary` is on.
4. In `When Openbridge hears...`, enter the mistaken phrase.
5. In `Replace with...`, enter the text you want pasted.
6. Press `Add entry`.

Example:

- When Openbridge hears: "trishan panch"
- Replace with: "Trishan Panch"

Custom Dictionary entries are stored locally on this Mac at the file path shown in Settings.

Custom Dictionary does not teach Whisper a new word and does not improve raw speech recognition. It is a post-transcription correction step. That means Openbridge first gets a transcript from Whisper, then applies your saved replacements before paste.

Custom Dictionary is different from Snippets and cleanup mode:

- Custom Dictionary fixes recurring transcription mistakes inside normal dictated text.
- Snippets expand an entire dictated trigger phrase into longer saved text.
- Cleanup mode optionally uses local AI to polish formatting or rough transcript wording.

If you might literally dictate the mistaken phrase and do not want it replaced, do not add it as a Custom Dictionary entry.

## Spoken Formatting

Spoken formatting is an optional Settings feature for normal dictation.

When it is on, Openbridge converts a small set of clearly spoken phrases after transcription cleanup and before paste:

- "new line" becomes a line break
- "new paragraph" becomes a blank line
- "period" becomes `.`
- "comma" becomes `,`
- "question mark" becomes `?`

Example:

- If you dictate "hello comma world period"
- Openbridge pastes "hello, world."

This is deterministic post-processing, not a raw Whisper capability. Whisper may sometimes add punctuation by itself, but spoken formatting is the predictable rule-based version.

Spoken formatting is off by default. It does not run inside Command Mode instructions. The separate "press enter" command stays terminal-phrase-only.

Openbridge should not convert clear literal wording such as "the word period".

## Press Enter Voice Command

There is an optional setting called `Enable Press Enter voice command`.

When enabled, if a dictation ends with the phrase "press enter", Openbridge removes that final phrase from the pasted text and sends an Enter key after paste.

If "press enter" appears in the middle of a sentence, it should stay as normal dictated text.

This setting is off unless the user enables it.

## Microphone Settings

In Settings, the Microphone card lets you choose the input Openbridge should use.

You can choose System Default or a specific input device.

Speak once while Settings is open. The live meter should move. If it does not move, Openbridge is probably not receiving audio from the selected input.

Bluetooth microphones may need a moment to wake up. If a Bluetooth input behaves oddly, try speaking once, waiting briefly, or switching to a built-in or wired microphone for testing.

## Dictation History

Openbridge can save successful dictations locally on the Mac.

History includes transcript text and useful metadata such as time, model, duration, and source app when available.

Settings let you choose:

- Store normally
- Auto-delete after 24 hours
- Never store

On new installs, Openbridge keeps dictation history off until you choose a retention option. Existing users keep their previous setting.

Choosing Never store clears saved history after confirmation and keeps future dictations out of local history.

Even if history storage is off, Paste Last can still work in memory during the current app session.

Security note: saved history is local plaintext on this Mac. Settings shows the exact history file path. Do not dictate secrets or sensitive content unless you are comfortable with local storage, backups, and the destination app where text is pasted.

## Snippets

Snippets expand exact dictated trigger phrases into longer text.

In Settings, you can:

- add a trigger phrase
- add expansion text
- search snippets
- edit snippets
- delete snippets

Duplicate trigger phrases are rejected.

Example:

- Trigger phrase: "standard follow up"
- Expansion text: "Thank you. I will follow up with the next steps shortly."

When you dictate the exact trigger phrase, Openbridge pastes the expansion text instead.

## Audio And Video File Transcription

Openbridge can transcribe a local audio or video file.

In Settings, expand `Audio and video files`, choose a file, then wait while Openbridge extracts audio and transcribes it locally.

File transcription does not require Microphone, Accessibility, or Input Monitoring permissions because it does not record live audio or paste into another app. It does need the selected speech model and media processing support.

Release builds bundle `ffmpeg`. Source builds need a local `ffmpeg` installation.

When the transcript is ready, Openbridge can copy or save the result.

## YouTube Transcription

Openbridge includes beta YouTube transcription for supported public videos.

To try it:

1. Open Settings.
2. Expand `Audio and video files`.
3. Paste a YouTube video URL.
4. Press `Transcribe URL`.
5. Wait for Openbridge to fetch audio it can access, convert it, and transcribe locally.

This may fail for some videos. Common causes include sign-in requirements, region restrictions, live or post-live formats, members-only videos, age restrictions, unavailable audio formats, or YouTube changes that affect `yt-dlp`.

If YouTube transcription fails, download the audio or video in a browser and use local file transcription instead.

For longer videos, Openbridge should either complete the transcript or fail visibly with a helpful error. It should not silently return a misleading partial transcript.

## If YouTube Gets Stuck Or Loops

If a transcript starts normally and then repeats a phrase over and over, the speech model may have entered a repetition loop.

Openbridge now has checks to avoid returning obvious repeated-phrase output as a successful transcript.

Try:

1. A shorter clip.
2. Downloading the file and using local file transcription.
3. Checking whether the original video has long silence, music, or unclear audio.
4. Reporting the video URL and approximate duration as beta feedback.

## Settings

Settings is where you tune Openbridge after basic setup.

Always-visible Settings areas include:

- Permissions
- Microphone
- Speech model
- Transcription cleanup

Additional sections are collapsed behind chevrons:

- Shortcuts
- Command Mode presets
- Audio and video files
- Custom dictionary
- Spoken formatting
- Snippets
- Dictation history
- General app behavior
- Installed models
- App details

This layout keeps the most important setup controls visible while keeping less common controls available.

## General App Behavior

General settings include:

- Enable Press Enter voice command
- Launch at login

Launch at login lets Openbridge start automatically when you sign in to the Mac.

## Installed Models

The Installed models section shows which curated Whisper models are installed.

If a model is not installed, use the Speech model card to install or check the selected model.

Model downloads require network access. Local transcription uses the installed model on the Mac.

## App Details

The App details section shows:

- Version
- Bundle ID
- Minimum macOS

This is useful when sending beta feedback because it tells the developer exactly which build you are using.

## Privacy And Local Data

Openbridge is local-first.

What usually stays local:

- microphone recording during dictation
- transcription processing
- pasted transcript text
- saved dictation history, if enabled
- snippets
- custom dictionary entries
- spoken formatting command setting
- shortcut settings
- selected microphone and model settings

What may use the network:

- downloading local model files
- fetching supported YouTube audio streams
- sending beta feedback through email, chat, or another external tool

Openbridge does not need your audio or transcripts for normal local transcription. But you are responsible for your Mac, backups, clipboard, local files, and the apps where you paste text.

## Sensitive Or Clinical Use

Openbridge is beta software. It can make mistakes.

If you are a clinician or working with sensitive data:

- use synthetic or non-sensitive examples for testing
- review and correct output before using it
- do not send sensitive audio, transcripts, screenshots, logs, patient data, credentials, or private keys in beta feedback
- make your own decision about whether your local setup is appropriate for your organization

Openbridge is not a medical device, not clinical decision support, and not a compliance guarantee.

## Build Version Confusion

If you think you are running the wrong source version:

1. Open Openbridge Settings.
2. Open `App details`.
3. Check the version and build number.
4. In Terminal, run `git rev-parse HEAD` in the repository.
5. Quit any other Openbridge copy before running `make app-run` again.

macOS can keep an installed copy open while the source process starts. Confirm which process and source commit you intended to test.

## Common Troubleshooting

### I do not see Openbridge after opening it

Look in the menu bar near Wi-Fi, battery, and the clock. Openbridge is a menu bar app, so it may not open a large app window.

### The shortcut does nothing

Check Input Monitoring permission. Also check that Openbridge is running and that your shortcut has not been changed in Settings.

### Openbridge records but does not paste

Check Accessibility permission. Also make sure the cursor is in a text field in the active app.

### The microphone meter does not move

Open Settings, then Microphone. Choose the correct input and speak once. If the meter stays flat, try System Default, a built-in microphone, or a different input device.

### Permission buttons look like they did not work

Permission setup is a round trip. Open System Settings, turn Openbridge on, come back to Openbridge, and press `Check again`.

### The model says it is not installed

Use the Speech model card in Settings and press Install. The model download needs network access. After installation, dictation and media transcription can use the model locally.

### Command Mode says it needs selected text

Select text in another app first. Command Mode transforms selected text; it is not general chat.

### Command Mode does not rewrite text

Make sure the local text model is available. Command Mode uses an MLX-backed Gemma model by default, and source builds can optionally fall back to Ollama.

### File transcription says ffmpeg is missing

Release builds should bundle `ffmpeg`. Source builds require local `ffmpeg`. If you are running from source, install it with Homebrew or set `OPENBRIDGE_FFMPEG_PATH`.

### A YouTube video fails

Try a different public video, or download the audio/video manually and use local file transcription. Some YouTube videos require sign-in, cookies, region access, or formats that the current beta cannot fetch.

### The transcript is wrong

Try a clearer microphone, less background noise, a larger speech model, formatting cleanup, Custom Dictionary for recurring name or term mistakes, or manual review. Always review important output.

### Openbridge feels stuck during transcription

Give local transcription a little time, especially on longer audio or larger models. If it does not recover, cancel if possible, try a shorter recording, and send beta feedback with the model, source type, approximate duration, and what you saw.

## What To Send As Beta Feedback

Openbridge has a Beta feedback section in Settings under Support and diagnostics.

Use Send feedback to open an email draft to team@lunr.studio. Use Copy template if Mail is not configured or if you want to paste the template into another email app.

Openbridge does not send telemetry in the background. The feedback action does not attach audio, transcripts, screenshots, diagnostics, snippets, media files, or dictation history. If you want to include setup details, run System Check, press Copy, review the copied summary, and paste it into the email yourself.

Helpful beta feedback includes:

- what you were trying to do
- which app you were typing into
- the Openbridge version and build from App details
- the Mac model and macOS version
- which shortcut or button you used
- whether the issue involved dictation, Command Mode, permissions, media files, YouTube, or install
- what you expected
- what actually happened
- screenshots with sensitive information removed
- the YouTube URL only if it is safe to share
- whether you were running from Applications, Downloads, or a mounted DMG

Do not send sensitive audio, transcripts, screenshots, logs, patient data, proprietary code, credentials, or private keys.

## Questions This Help Should Answer Well

### How do I start dictation?

Put the cursor in a text field, press Right Option, speak, then press Right Option again. Openbridge transcribes locally and pastes the text into the active app.

### Why does Openbridge need Accessibility permission?

It needs Accessibility to paste text into the active app and to work with selected text for Command Mode.

### Why does Openbridge need Input Monitoring?

It needs Input Monitoring to catch keyboard shortcuts while you are using other apps.

### Why should I move Openbridge to Applications?

macOS permissions are tied to the exact app copy that asks for them. Moving Openbridge to Applications first prevents confusing permission behavior later.

### How do I transcribe a YouTube video?

Open Settings, expand Audio and video files, paste the YouTube URL, then press Transcribe URL. If it fails, download the file manually and use local file transcription.

### Is Openbridge private?

Openbridge is local-first. Normal transcription is designed to run on your Mac, and Openbridge does not need your audio or transcripts for normal use. Some support actions can use the network, such as model downloads, YouTube fetching, and external feedback channels.

### Can this Help assistant check my setup?

Yes, when you open Help from the Openbridge app. It can inspect a limited setup summary: permissions, install location, selected microphone, model readiness, local AI availability, shortcut bindings, history/privacy mode, and the current app status message.

It does not inspect audio, transcript text, selected text, snippet text, media file contents, or saved dictation history contents. If Help is opened without the app-provided setup summary, it can still explain where to check manually in Settings.
