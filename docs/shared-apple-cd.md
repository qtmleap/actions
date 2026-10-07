# Shared Apple CI/CD

Use this public repository as the immutable source of common CI/CD code. App repositories keep their triggers, protected Environments, runner labels, concurrency, trusted check names and distribution adapters.

TestFlight accepts only the first attempt of a push produced by one merged same-repository PR into develop or master. Verify the exact source, first parent, trusted PR workflow attempt/jobs, clean checkout and live destination tip before credentials and again before upload. Ignore record-only merges. macOS 26 is the Musicfin/Kotatsu profile; other apps use macOS 27. Linux jobs use self-hosted Docker runners. Credentials remain step-scoped, signing is readonly and private package authorization ends before compilation.

Keep distribution contracts distinct: Kotatsu records tvOS and iOS separately; Connect creates a macOS draft and requires physical evidence to finalize those exact bytes; Qualia retains immutable DMG/R2 build or promotion, notarization, Sparkle and Cloudflare staging/production. Immerse remains an unsigned template without an App Store Connect registration.

Shared source must contain the identical four-app Ruby TestFlight engine and the strongest merge verifier, based on Connect/Qualia's explicit run-attempt/job linkage. Config and specialized lanes remain in consumers. Downloaded/native runtime content is verified against a full commit pin and file digests outside app source; no stale or local-copy fallback. Independent cleanup must retain failed recovery state and preserve successful upload receipts even after cleanup failure. No source commits or new uploads occur during migration.

User runner-label simplification: retain macos-26/macos-27 profiles, but caller runs-on uses only [self-hosted, macos-26] or [self-hosted, macos-27]. Remove redundant macOS/ARM64 labels; existing runtime toolchain validation remains.
