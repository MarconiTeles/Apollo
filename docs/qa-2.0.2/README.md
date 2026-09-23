# Apollo 2.0.2 (100)

This release promotes the AppKit board viewport and the validated native task viewport. The task list uses explicit viewport sizing at the SwiftUI boundary and recycles a bounded pool of native rows without removing their controls from the window. Native scroll phases retain hover suppression through the momentum tail. The window refresh request follows the window across displays.

Production uses AppKit by default. Fixture data, synthetic scrolling, diagnostic appearance switches and the task scroll probe are restricted to APOLLO_DEV. Production identity, Keychain namespace, Sparkle feed/key and the bundled Apollo Review workflow remain unchanged.

Validation before packaging: `swift test` passed 222 XCTest tests (4 external tests skipped) and 12 Swift Testing tests. Tests cover board ordering/parity, bounded viewport recycling, row identity, group collapse, text geometry, native controls and scroll activity deadlines. The task viewport kept at most 47 views with 5,000 tasks. The validated DEV was physically evaluated on the built-in 120 Hz display; the user reported near-perfect scroll. Display-link statistics are callback measurements, not presented-frame FPS.

Release artifacts, source commit, signing, notarization and publication receipts are recorded separately in the release audit after each step succeeds.

Publication verified on 2026-09-23: [Apollo 2.0.2](https://github.com/MarconiTeles/Apollo/releases/tag/v2.0.2) is the latest public release. The public Sparkle feed advertises build 100, macOS 26.0, and the verified archive signature and length. Both public downloads match the local SHA-256 hashes. App and DMG notarization, stapling, Gatekeeper assessments, nested Review and final archive contents passed. See [release audit](release-2.0.2-audit.json). This release was smoke-tested from the packaged app; the existing /Applications installation was not replaced.
