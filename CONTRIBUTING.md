# Contributing to Openbridge

Thank you for helping improve Openbridge. This repository is intentionally source-only: contributions should concern the macOS app, Python engine, resources, tests, licences, or contributor documentation.

## Set up

Follow the [README](README.md) on an Apple Silicon Mac:

```bash
python3.14 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-lock.txt
make test
make app-run
```

No signing or notarization credentials are needed. See the development guide for toolchain installation and expected results.

## Submit a change

1. Search existing issues first.
2. Fork the repository and branch from `main`.
3. Make one focused change and add or update tests.
4. Run `make test`.
5. Open a pull request explaining the problem, the change, and the evidence.

Useful branch names include `fix/short-description`, `feature/short-description`, and `docs/short-description`.

## Project boundaries

Please do not add:

- compiled apps, current or historical disk images, model weights, caches, or generated output
- signing, notarization, official packaging, upload, or distribution automation
- the marketing website, deployment configuration, or official download settings
- private planning, release evidence, credentials, or internal operational details

The maintainers handle official binaries in a separate private process.

## Development guidance

- Swift code lives in `Sources/OpenBridgeApp/`; follow Swift API design conventions.
- Python code lives in `openbridge_engine/`; follow PEP 8 and use type hints where practical.
- Keep the Python CLI output contract machine-readable because the Swift app consumes it.
- Update relevant docs when behaviour, setup, privacy, networking, or dependencies change.
- Never commit real transcripts or other sensitive user data as fixtures.

## Licensing

Openbridge uses Apache-2.0 Section 5 inbound=outbound licensing. Contributions intentionally submitted for inclusion are licensed under Apache-2.0; no separate CLA or DCO sign-off is currently required.

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) for community standards and [SECURITY.md](SECURITY.md) for private vulnerability reporting.
