# DexDictate Monterey Whisper Probe

Determine whether DexDictate's exact SwiftWhisper/whisper.cpp path works on an Apple Silicon Mac running macOS Monterey 12.7.6, before porting the real app. This is a disposable command-line probe, not DexDictate.

Run from the repository root (including an unzipped GitHub download):

```bash
bash RUN_MONTEREY_PROBE.command
```

It needs no sudo, Homebrew, Python, Node, CMake, Docker, or package manager. It uses Apple's developer toolchain, Swift Package Manager, AVFoundation, `say`, and `afconvert`. macOS may ask for microphone access; say the prompted phrase while it records.

The probe downloads only the official whisper.cpp GGML English models: Tiny (about 75 MiB) and Base (about 142 MiB). Files are SHA-256 verified before use and cached at `~/Library/Caches/DexDictateMontereyProbe/`; no Core ML encoder sidecar is downloaded or accepted. Every run creates `probe.log`, `probe-report.txt`, and `probe-report.json` under that cache's `reports/` directory.

Useful options:

```bash
bash RUN_MONTEREY_PROBE.command --no-mic
bash RUN_MONTEREY_PROBE.command --clean
```

`--no-mic` still runs the full deterministic Tiny and Base engine test, twice each. `--clean` removes only this probe's cache and this repository's `.build` directory.

Exit codes: `0` full GO, `2` partial GO/caveat, `20` setup blocked, `30` unsupported target, `40` exact-stack build incompatibility, `50` Tiny runtime/transcription failure, `60` other native runtime failure.

Verdicts are deliberately narrow:

- `GO_TINY_BASE`: both models pass twice; microphone also passes if attempted.
- `GO_TINY_ONLY`: Tiny passes twice; Base requires investigation.
- `ENGINE_GO_MIC_BLOCKED`: deterministic engine tests pass, but live microphone validation did not.
- `BLOCKED_SETUP`: a toolchain, network, disk, asset-integrity, or fixture prerequisite prevented a meaningful engine test.
- `UNSUPPORTED_TARGET`, `NO_GO_BUILD`, and `NO_GO_TINY_RUNTIME`: stop signals at their respective stages.

A successful run on macOS 13 or later is diagnostic only. It is not proof of Monterey compatibility; only a real Monterey 12.x Apple Silicon result is.
