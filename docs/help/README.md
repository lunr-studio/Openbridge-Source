# Local Help Source

| File | Purpose |
| --- | --- |
| `OPENBRIDGE_HELP_KNOWLEDGE.md` | user-facing knowledge used by the local Help server |
| `OPENBRIDGE_HELP_SYSTEM_PROMPT.md` | safety and response instructions for the local model |

During source development, the Help button starts `scripts/openbridge_help_review_server.py` on `127.0.0.1` and opens the page in the user’s browser. The server reads these Markdown files from the repository.
