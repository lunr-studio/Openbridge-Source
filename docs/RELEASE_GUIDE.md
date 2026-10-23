# Source Publication Guide

Openbridge source publication is independent from production of an official signed application.

## Candidate gate

Before publication:

1. Confirm the candidate commit contains only the approved source allowlist.
2. Run `make test` on the candidate commit.
3. Complete the clean-Mac contributor exercise.
4. Confirm source CI and Python CodeQL pass on that exact commit.
5. Review the licence, third-party notices, model identifiers, FFmpeg obligations, privacy/networking documentation, contribution guide, and security-reporting path.
6. Obtain the maintainer’s source-publication approval.

## History gate

Search every branch and tag, not just the working tree. `git rev-list --objects --all` must not reveal:

- website or deployment files
- compiled applications, disk images, or model weights
- signing, notarization, upload, or official distribution operations
- private release evidence, internal planning, archives, or rights-uncertain media

## Publish

After the approval gate:

1. Make the repository public.
2. Create annotated tag `source-v1` on the approved commit.
3. Push the tag.
4. Do not create or attach a compiled release asset.

An annotated tag records a human-readable source milestone. It is not a promise that a binary was produced from that commit.

## Verify externally

From an unauthenticated environment, clone the public URL and follow the README. Verify build/test, documentation links, issue forms, licence access, contribution guidance, and private vulnerability reporting.
