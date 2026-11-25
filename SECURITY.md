# Security policy

Please report vulnerabilities privately via GitHub's
[private vulnerability reporting](https://docs.github.com/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
for this repository. Do not open a public issue.

Include the affected version, the transport/configuration and a minimal synthetic
reproduction. Never include real tokens, keys or personal data.

Until 1.0.0 only the latest pre-release receives fixes.

Security-relevant boundaries: exact envelope/schema validation, bounded work and queues,
continuation state integrity and cancellation ownership. See the Core's
[LIMITS](https://github.com/ThorFuchs/Swift-MCP-Server/blob/d892bd34add1ad067ae6f286bd74c824486d8c07/Docs/LIMITS.md)
and [MRTR/state](https://github.com/ThorFuchs/Swift-MCP-Server/blob/d892bd34add1ad067ae6f286bd74c824486d8c07/Docs/MRTR_AND_STATE.md)
contracts at the audited revision, and this package's [HTTP response lifecycle](Docs/HTTP_RESPONSE_LIFECYCLE.md)
and [client authorization](Docs/CLIENT_AUTHORIZATION.md).

Hosts own production TLS trust and credentials, token verification, token storage,
user-agent integration and the injected HTTP client's redirect/proxy/egress policy.
Treat authorization challenge values, stored authorization and diagnostic URLs as
sensitive. Use protected storage and avoid automatic redirects for credential-bearing
requests unless the host has explicitly reviewed and constrained that behavior.
The SDK is pre-release; head/static write deadlines, final consumer tests and
release-platform scope remain qualification gates.
