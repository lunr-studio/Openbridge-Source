# Source boundary and provenance

This repository starts with a new root commit containing the reviewed application source snapshot. It has no parent link to private development history, branches or pull requests.

It includes Swift application/UI source, the Python engine and command-line entry points, build inputs, licensed resources, source tests and synthetic fixtures, development helpers, and contributor documentation. Project copyright and third-party attribution are retained in LICENSE, NOTICE and THIRD_PARTY_NOTICES.md.

Excluded are website/deployment source, current or historical app/DMG files, private development history, Satoshi font binaries, model weights, generated environments, signing/notarization/upload scripts, internal plans and private release evidence.

Public source can be compiled without signing credentials. A separate private distribution process may record the public source commit it builds; its tooling, credentials and binary artifacts do not enter this repository.

The retained legacy Mac proof definitions are unchanged test-contract inputs. They require private host/account controls, are not public CI gates, and their workflow is disabled during repository preparation. No private self-hosted runner is attached.
