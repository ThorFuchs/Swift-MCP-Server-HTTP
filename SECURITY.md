# Security policy

Please report vulnerabilities privately via GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository. Do not open a public issue.

Include the affected version, the transport/configuration and a minimal synthetic
reproduction. Never include real tokens, keys or personal data.

Until 1.0.0 only the latest pre-release receives fixes.

Security-relevant boundaries: exact envelope/schema validation, bounded work and queues,
continuation state integrity and cancellation ownership (see `Docs/LIMITS.md`,
`Docs/MRTR_AND_STATE.md`, `Docs/STDIO.md`).
