# OpenBridge application design

## Product and personality

OpenBridge is a local-first Mac app for meeting capture, transcription, local cleanup, optional cloud intelligence and voice typing into the app where work already lives. It has a main Dock window, a menu bar launchpad and a floating flow bar, plus a public tester/download site. Its audience includes clinicians, researchers, developers, writers and other professionals who want useful AI with control over where their words are processed.

**Quiet Premium Utility.** Calm, capable and easy to read. Use the homepage's cool white atmosphere, navy ink, clear type and restrained yellow microphone identity. The memorable promise is **Local AI, your control**. Typography, grouping and generous reading space carry the design; avoid decorative dashboards, oversized status boxes, gradients on action buttons and bubbly radius everywhere. Preserve the supplied microphone artwork.

The visible product wordmark is **Openbridge**, using `AppIdentity.displayName` in native brand headings. Render the supplied microphone artwork on a transparent background, without a white tile or decorative backing circle. Preserve its original paths and colors. The macOS application icon remains a separate OS asset.

## Typography

The application uses Instrument Sans for headings and body text, with Geist Mono for numeric metadata. The owner approved this source-release font change on 2026-10-23. Website typography remains independently maintained in the private website source. Native OS chrome remains native; system fonts are a fallback, not the approved brand typography.

| Role | Family and weight | Product size / line height | Use |
| --- | --- | --- | --- |
| Page title | Instrument Sans 700 | 28 / 35 | Main page title; 25 / 31.25 below 600px |
| Section title | Instrument Sans 700 | 20 / 25 | Major content groups and meeting headings |
| Card / pane heading | Instrument Sans 700 | 18 / 22.5; 16 / 20 | Cards; transcript, Research and flow bar panes |
| Menu heading | Instrument Sans 700 | 21 / 26.25 | Primary menu action heading |
| Reading text | Instrument Sans 400 | 16 / 27.2 | Meeting answers and help articles |
| Transcript passages | Instrument Sans 400 | 16 / 28 | Long-form transcript reading |
| Body copy | Instrument Sans 400–600 | 15 / 24 | Explanatory paragraphs |
| Controls | Instrument Sans 400–600 | 15 / 19.5 buttons; 15 / 21 inputs | Main actions, forms and local tabs |
| Metadata | Instrument Sans 400–600 | 13 / 19.5 | Secondary guidance, passage source labels and privacy summary |
| Numeric metadata | Geist Mono 400–500 | 13 / 19.5 in the small-text role; live timer 16px | Timestamps, timers and technical values |

- Sizes above are CSS pixels in the review prototype. Heading line height is 1.25; page-title tracking is -1px and other headings use -0.45px. Body tracking is normal. Use sentence case and do not shrink reading copy to fit crowded layouts.
- Bound transcript and article measure to approximately 64–72 characters. Keep source metadata in a separate column or line. Preserve comfortable paragraph spacing and selectable text.
- Main controls and local tabs are 15px. The separate review toolbar uses 13px. Compact badges, field hints, keyboard chips and flow detail use 12px; decorative navigation eyebrows use 11px. Essential instructions remain in a readable 13px-or-larger body/notice role, with a labelled action. Flow detail supplements its visible heading and action.
- Web marketing retains its approved 40–60px hero, 30–44px section headings, 18px introduction and 16–17px body scale.
- The native implementation bundles eight official original Instrument Sans and Geist Mono OTF assets under `Sources/OpenBridgeUI/Resources/Fonts`, retains OFL licenses and source hashes, and registers fonts lazily before rendering. Font tests verify bundled resolution. Keep a system fallback for missing fonts/glyphs. This clean repository contains no Satoshi binaries or private development history.

## Color and semantic tokens

Use names describing a role rather than a particular screen. Primary actions use navy with white text. Yellow supplies warmth and emphasis with dark text; blue supplies active selection and focus.

| Token | Value | Role |
| --- | --- | --- |
| `canvas` | `#F7F9FC` | Main workspace background |
| `surface` | `#FFFFFF` | Reading panes and grouped controls |
| `surfaceSelected` | `#E8EEF8` | Selected sidebar navigation |
| `surfaceGuided` | `#EDF3FF` | Guided state and cool accent surfaces |
| `ink` | `#142034` | Headings, body and primary actions |
| `inkMuted` | `#5D6C81` | Supporting text |
| `border` | `#E1E7EF` | Quiet decorative separators |
| `controlBorder` | `#7E8CA1` | Input boundaries where needed for recognition |
| `focus` / `link` | `#2367D8` | Keyboard focus, links and active state |
| `brandGold` | `#F6C84C` | Microphone identity and selective emphasis |
| `localInk` / `localSurface` | `#326D5C` / `#EFF6F3` | Local processing label; also success reassurance |
| `cloudInk` / `cloudSurface` | `#526079` / `#F3F5FA` | Optional cloud processing label |
| `warningInk` / `warningSurface` | `#855416` / `#FFF6E6` | Attention needed; use readable text and icon |
| `errorInk` / `errorSurface` | `#B33C3C` / `#FFF1F0` | Failure or destructive action |

The brand's brighter teal `#1AA39A`, green `#2F9D62` and coral `#EF8D6C` may be small graphics or indicator accents; use the darker semantic inks for readable status copy. Do not use color as the only distinction between local/cloud, selected/unselected or success/error.

The approved direction is light. This review does not add a new dark theme. Respect macOS accessibility settings and validate high-contrast/reduced-transparency behavior during native accessibility acceptance. Do not turn the prototype into an unapproved dark redesign when the OS is dark.

## Spacing, layout and components

- Base spacing unit: 4px. Scale: 4, 8, 12, 16, 24, 32, 48, 64. Use 24px main panel padding, 16px compact panel padding, 24–32px between major groups and 8–12px within a related control group.
- Radius: 6px controls, 12px panels, full radius only for selective status labels. Thin borders and a restrained shadow separate layers; avoid nested cards where a heading and divider suffice.
- Main window review sizes: 980×680, 1180×760 and 1480×900. The sidebar is 180px through 1100px, 204px at 1101–1399px and 220px from 1400px. Below 850px it is 160px; below 600px it becomes a labelled-for-accessibility 52px icon rail. Main action buttons have a 40px minimum height, with 34px icon buttons and review-toolbar controls. The Home header Start action is at least 42px tall.
- Narrow windows stack form columns and use explicit Transcript / Split / Research focus controls. Home presents Start meeting in the page heading, above the initial form scroll. During recording, the timer and Stop action stay in a bar sticky to the top of the scrolling area and outside the focus-switched transcript/Research panes; the page title may scroll away.
- Home uses a meeting form with a narrower setup summary; available width determines whether they sit beside one another. Library and History use aligned rows with readable titles, useful dates and accessible actions.
- Live transcript and Meeting Intelligence use a generous reading pane with a narrower answer rail, not equal competing cards. Source citations visibly connect answers to the retained Original transcript.
- Menu: about 500px wide, explicit bounded height with scrolling when required. Keep the primary action and readiness first; show app/settings/help/quit as secondary utilities. Use a small gold brand accent rather than a solid yellow hero.
- Flow bar: roughly 560–600px wide with content-driven height. Show phase, detail and next step with reachable Stop/Cancel. Avoid blank space that reads like a frozen notification.
- Use semantic components for buttons, form fields, navigation rows, tabs, processing labels, empty states, progress, inline messages and confirmation dialogs. Standardize their font, padding, border and focus rules across every surface.

## Navigation and complete product coverage

The approved sidebar has **Home, Meetings, Voice typing, Transcribe**, with **Settings and Help** anchored below. Local tabs expose detail only after entering a workflow. This replaces the 11-item always-visible sidebar while retaining the existing capabilities.

| Destination | Local pages | Behaviors to retain |
| --- | --- | --- |
| Home | Setup; recording as a state | Meeting name, capture mode, microphone, separate Cloud research and cleanup choices, workspace/retention, latest/recent meetings |
| Meetings | Library; meeting detail | Search, selection, recovery, named deletion; playback, Original/Cleaned, citations, copy/export, summaries/actions and Ask |
| Voice typing | Preferences, History, Text actions, Snippets, Dictionary | Dictation controls, shortcuts/reset, input, paste/Enter, hands-free, formatting/cleanup; retained dictations; selected-text transforms; snippet editing/testing; dictionary import/export |
| Transcribe | Files, YouTube | Input, local transcription progress, latest result, Copy and Save As |
| Settings | General, Models & performance, Cloud AI, Privacy & data, System Check | Launch/about; speech and cleanup model readiness/download/speed; provider/test/consent; data retention; permission requests/check-again and safe support summary |
| Help | Help overview and topics | Setup, paste recovery, file transcripts, privacy, local help and feedback/support |

There are **16 main clickable destinations**, plus **onboarding, menu and flow bar**: **19 review surfaces**. Loading, empty, blocked, error, confirmation and success variants are states rather than extra navigation entries.

- Dictionary changes apply across OpenBridge, including meeting and file transcription. Label that scope and link to Dictionary from Home options and Transcribe details.
- Text actions rename the existing Transforms page; they rewrite selected text in any app and do not require a prior dictation.
- Transcribe owns the latest media result. Do not imply an existing persistent file-transcript library or place file results inside dictation History. Home may show a compact link to the latest result.
- Settings has one coherent hierarchy. Menu Settings and Cmd-, should reach that same hierarchy in a later native implementation. Preserve controls previously only in the all-in-one Settings window, especially Cleanup mode, support/feedback and version information.
- Privacy & data keeps dictation-history retention distinct from individual meeting retention. Editing a policy must explain its actual scope.
- Onboarding introduces the main window and menu bar, guides permission round trips, explains model readiness and allows an explicit local history choice. Do not confuse first-run setup with the separate DMG-to-Applications installation guide.

## Behavior, processing and voice

- Keep Home as the recording/configuration surface and Meetings as the saved library. Preserve the recording lifetime and the existing navigation guard while capture starts, records and finalizes.
- Capture is segment-based during recording. Cleanup runs after Stop; Original remains available. Show current progress honestly rather than fabricating per-word latency or an exact percentage the engine does not expose.
- Cloud research is independent of Off/Local/Cloud transcript cleanup. Show the processing choice alongside the relevant action. Cloud research sends the typed question and relevant authorized transcript excerpts; cloud cleanup sends transcript text. Do not imply cloud audio transcription.
- Meeting Intelligence supports typed questions about the current meeting and permitted saved meetings. Access choices remain explicit. Show waiting for recent audio/transcription/previous questions and retain readable answers while later requests run.
- Distinguish “From this meeting” or “From your meetings” evidence from “Additional explanation” based on model knowledge. Every meeting citation must point to the relevant Original passage. Do not demonstrate automatic spoken wake questions, web search or sources outside approved scope.
- Dictation may retain recognized text even when insertion needs attention. Say what was saved and where the user can copy/paste it; do not label uncertain delivery as success or suggest an automatic retry that could duplicate or submit text.
- Use plain phases such as “Listening privately”, “Preparing your transcript” and “Ready to paste”. Model IDs, paths, checksums and raw diagnostics belong in Settings/support detail, not the normal recording flow.
- Local processing means the stated step stays on the Mac. Optional cloud actions must identify the configured provider and applicable consent. Preserve existing provider-privacy and charge disclosures without turning every screen into a warning panel.

## Interaction, accessibility and motion

- Normal text must meet WCAG AA 4.5:1 contrast; large text and necessary control boundaries/focus indicators must meet 3:1. Verify actual rendered combinations, including selected/disabled/hover states; a pale decorative border is not a sufficient sole input boundary.
- Every input has a visible associated label, every icon-only action has an accessible name, every control is keyboard reachable and keyboard focus is visible. Tabs support arrow/Home/End navigation; dialogs have a clear title, constrained focus, Escape/Cancel and focus restoration.
- Long titles, filenames and model/provider names wrap without hiding primary actions. Browser review supports 200% text/zoom and narrow layouts without horizontal page overflow.
- Empty states describe the first useful action; blocked states name the unmet requirement and a route to fix it. Loading states state the current step. Failure states preserve useful text and offer the existing recovery path. Success states state the observed outcome.
- Destructive confirmations name the affected records/data and default to Cancel. Research/provider failure must not hide or stop a meeting's capture controls. Prototype deletion only changes synthetic samples.
- Motion is functional: 80–120ms press feedback and 160–220ms state transitions, ease-out arrivals and ease-in-out movement. No scroll gates, hidden reveal content or forced scroll resets. Respect `prefers-reduced-motion`; use static state indicators when reduced motion is enabled.
