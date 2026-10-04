# Security

This is a local, unsandboxed desktop application with a loopback API, not a hosted multi-user service. Only run trusted source, Python environments, trained engines and model files. Do not forward port 8011 to a network or allow untrusted local processes to use it. Browser requests are rejected before endpoint processing, but native local clients are not authenticated.

Please use the repository's **Security → Report a vulnerability** feature if the maintainer has enabled private vulnerability reporting. If unavailable, open a minimal issue asking for a private reporting channel without exploit details, recordings, credentials or private logs. Do not post sensitive evidence publicly. There is no promised response SLA.

For maintainers before publication: enable private vulnerability reporting and GitHub secret scanning where available. Review all reachable Git history, not just the latest files. Exposed credentials require revocation as well as history cleanup; ignore rules alone do not remove committed data.
