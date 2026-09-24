# Apollo 2.0.4 (104)

Ships the current React Tasks and Agenda surfaces in production. Includes sticky task category bands with 4.5px backdrop blur and a subtle full-width bottom rule, participant photos with one avatar per left-side event card, and the integrated navigation/loading refinements. Production identity, Sparkle feed/public key and macOS 26 minimum remain unchanged. Apollo and the bundled Apollo Review are distributed as universal arm64/x86_64 executables.

Validation uses the production compilation flags `APOLLO_TASKS_REACT` and `APOLLO_AGENDA_REACT`. `swift test --no-parallel` passed 261 XCTest tests (4 external integration tests skipped) and 33 Swift Testing tests, including 30 monthly layout reference cases. Both React builds run TypeScript checking before bundling.

The initial run found two stale assertions using the Board's former 258pt leading inset; the offset preservation test now checks the actual layout inset. No runtime behavior was changed for this correction. The initial concurrent Swift Testing run also observed delayed animation completion in the native Agenda fallback test. That test passed in isolation and the complete suite passed with `--no-parallel`; no claim of concurrent UI test stability is made.

Artifact signing, notarization, archive contents, production smoke checks and publication receipts are recorded in `release-2.0.4-audit.json` as those steps complete. External service end-to-end mutation flows and Intel hardware execution are not covered by the local smoke check.

Published on 2026-09-24 as the latest stable release: https://github.com/MarconiTeles/Apollo/releases/tag/v2.0.4. Both public downloads match the validated local SHA-256 hashes. The public Sparkle feed advertises 2.0.4 (104) with the validated signature, byte length and macOS 26 minimum; Pages deployment succeeded. App/DMG notarization, stapling, Gatekeeper, final archive contents and production Tasks/Agenda smoke checks passed. The actual in-place Sparkle installation was not exercised.
