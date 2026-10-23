# Engine Testing

The Python engine is the contract layer used by the Swift app and command-line entry points.

```bash
make python-test
make swift-check
make test
```

Current tests cover deterministic formatting, vocabulary handling, model lookup, JSON success/error responses, command-mode boundaries, local Help behaviour, storage permissions, and older local-data compatibility.

The tests should remain fast, deterministic, and independent of model downloads. Full inference and macOS UI flows are manual clean-Mac exercises because they require hardware, permissions, or large upstream model files.

When adding an engine command:

1. Keep stdout machine-readable.
2. Send diagnostics to stderr.
3. Add a unit test for success and failure envelopes.
4. Verify Swift remains compatible with the JSON contract.
