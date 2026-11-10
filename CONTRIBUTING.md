# Contributing

Thanks for your interest! This project follows a lean process ([ADR-0001](Docs/ADR/0001-lean-process.md)).

1. Open an issue for larger changes first.
2. Work on a branch and open a pull request against `main`.
3. Requirements: macOS 27+, Swift 6.4 (Xcode 27). Run `Scripts/test.sh`. All tests must pass.
4. Add Swift Testing tests for changed behaviour, including error, cancellation and race paths.
5. Public API, dependency or platform changes need a short ADR in `Docs/ADR/`.
6. Keep the library domain-neutral, bounded by default and free of global side effects
   (no logging/metrics bootstrap, no signal handlers, no credential ownership).

By contributing you agree that your contribution is licensed under the Apache License 2.0.
