# Git privacy and publication boundaries

The local Git-email blocker was resolved on 2026-10-04 with owner authorization. Seven commits and the annotated `v3.4.5` tag were rewritten only for email identity and the resulting parent/target hashes. Commit trees, messages, names, dates, ordering and branch structure were preserved. Uncommitted source and index contents were preserved. There were no signatures on the rewritten commits/tag.

Repository-scoped future identity:

```text
user.name = ninja8170
user.email = 65178017+ninja8170@users.noreply.github.com
user.useConfigOnly = true
```

The numeric account ID was verified using GitHub's public account API. Global Git configuration is unchanged. Local Git configuration does not travel with clones; contributors should configure their own public-safe identity. Command-line/environment identity overrides must also use a public-safe address.

All 108 reachable Git objects were scanned case-insensitively for the old private email, with zero matches. A scan of every stored object, repository files and Git metadata also found zero. Old reflogs and the stale fetch cache were removed, and unreachable original objects were pruned after making a private recovery backup outside the repository. Never publish that backup or copy it into this checkout.

## Remote remains unsanitized

No push, force-push, fetch, remote change or publication was performed. Local `main`, the local tracking snapshot `origin/main`, symbolic `origin/HEAD`, and `v3.4.5` now resolve to sanitized history. Matching local tracking refs do **not** demonstrate synchronization with GitHub: the remote still has the old history.

Do not fetch/pull from the unsanitized remote or change its visibility to public. Fetching can restore the original private-email commits locally. Separately approve a publication/remediation plan after the final release audit. Publishing a fresh sanitized repository avoids carrying this remote's existing private history forward; changing an existing remote requires considering retained refs, cached commits and server-side history, not just branch tips.
