# Frozen synthetic goldens v1

`meetings.json` is the literal approved [EVAL fixture pack](../../../../EVAL.md#fixed-synthetic-fixture-pack).
`expectations.json` freezes normalized fact/citation and forbidden-claim grading.
`sync_today.txt` joins sync1/sync2 with a single ASCII space. `sync_today.wav` is
synthetic speech for future native capture tests: mono 16 kHz, signed 16-bit PCM.
`audio.json` records its actual hash, format, macOS/voice provenance and generation
command. Reproduction on a different OS/voice build may produce different bytes;
the checked-in hash is authoritative. Never silently replace the asset.

These files contain no real meeting or credentials. Actual ASR/native tests
remain unrun. Future real-service tests must map the logical fixture identities
to an isolated authorized namespace and retain that mapping; never seed a personal
library. Existing fixture edits require prior explicit human review and approval.
