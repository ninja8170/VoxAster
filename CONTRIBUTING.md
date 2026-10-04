# Contributing

Use macOS 14+ on Apple Silicon and Python 3.12. Follow README setup, then run `./test.command` and `git diff --check` before proposing changes. Tests never require private recordings. Keep model/package pins explicit; dependency changes need their own validation and licence review.

Keep changes small, preserve native model versus app-level control boundaries, and never pass unknown directions to synthesis. Cover meaningful request/engine/persistence regressions. Describe what changed, why, checks run and any listening validation still needed in a pull request.

Do not commit model files, voice samples, environment folders, logs, secrets, drafts, outputs or local paths. Contributions to original app code are under the repository MIT licence; keep third-party notices and identify imported material. Use issues for reproducible non-sensitive bugs and feature discussion. See SECURITY.md for sensitive reports.
