# Security Policy

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability.

Use GitHub private vulnerability reporting for this repository when it is available under the **Security** tab. If that flow is unavailable, email **team@lunr.studio**.

Please include:

- the affected component: Swift app, Python engine, or source-development tooling
- the source commit or tag you tested
- reproduction steps and likely impact
- a suggested fix, if you have one

Do not send real transcripts, patient information, credentials, or other sensitive data. The maintainers aim to acknowledge a report within 72 hours.

## Scope

This policy covers the source in this repository. It does not cover third-party dependencies, model-provider services, unofficial forks, or a user’s local macOS configuration.

Openbridge is designed to process speech locally by default. Network activity includes user-requested media/model downloads and explicitly selected optional cloud cleanup/research providers; local transcription does not require those cloud features. Proposed shared Cloud functionality is documented separately and is not established by this source release. See [docs/PRIVACY_STORAGE_NETWORKING.md](docs/PRIVACY_STORAGE_NETWORKING.md).
