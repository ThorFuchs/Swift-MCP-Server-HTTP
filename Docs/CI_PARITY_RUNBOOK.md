# Two-Mac reproducibility runbook · Swift MCP HTTP

Scope: [HTTP #22](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/22), HTTP #13, #20 and #21. This procedure diagnoses **macOS host**, **Xcode/Swift toolchain**, **actual SwiftPM dependency graph**, and **Debug vs Release behavior**. It changes no production source, test assertion, deadline, transport guarantee, or published package dependency.

## Three immutable source snapshots

| Snapshot | Exact HTTP commit | Question |
| --- | --- | --- |
| `baseline` | `104386cb2aef22594c4854dafd71a12519a5ed16` | Original optimized `HTTPProtocol` linker error |
| `pr20` | `2c4f9e540f879c1d6c88fbb294b965da38c0a066` | Connection-ownership v3: Debug and referee green, Release stalled writer fails |
| `pr21` | `748f0fb99ac9bdad0ae2ef73e128a6c4d7d8942a` | Published `swift-http-server` 0.5.0: optimized Reader/Connection metadata link errors |

**Critical:** HTTP still depends on Core `branch: "main"`. Its committed `Package.resolved` may refer to an older Core commit than today's `main`. A fresh `swift package resolve` can therefore move Core. **Compare `dependencies.txt` (both root and fixture) and `dependency-drift.diff` before drawing a MacBook-vs-Studio conclusion.** If effective pins differ, the two results do *not* compare the same graph.

## Prepare each physical Mac

1. Make sure the Mac Studio and MacBook Pro have the intended **Xcode 27 / Swift 6.4** toolchain installed and selected. Both are now on macOS 27.3 beta builds, but do not assume their *exact* build numbers or Xcode selections match. Verify using `sw_vers -productVersion`, `sw_vers -buildVersion`, `xcodebuild -version`, `xcode-select -p` and `swift --version`. The script records all of these automatically.
2. Do not run Core, HTTP or SwiftNIO builds **simultaneously on the same machine** during the comparison. Two different registered Actions runners can execute on the same physical Mac without coordinating resource usage.
3. Make a **new** tools clone. The parity script then performs a **second independent fresh HTTP clone for each snapshot/run**, checks out its immutable SHA detached and retains logs outside the source directory. Do not reuse an old `.build` directory.

### MacBook Pro

```bash
git clone --branch ci/mac-host-parity-2026-11-22 \
  https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git \
  ~/Swift-MCP-HTTP-Parity-Tools
cd ~/Swift-MCP-HTTP-Parity-Tools

bash Scripts/ci-parity-run.sh pr20 macbook focused
bash Scripts/ci-parity-run.sh pr21 macbook focused
```

### Mac Studio

```bash
git clone --branch ci/mac-host-parity-2026-11-22 \
  https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git \
  ~/Swift-MCP-HTTP-Parity-Tools
cd ~/Swift-MCP-HTTP-Parity-Tools

bash Scripts/ci-parity-run.sh pr20 studio focused
bash Scripts/ci-parity-run.sh pr21 studio focused
```

Each `focused` run uses `-j 2` and performs fresh root Debug/Release builds, optimized **server and client fixture links**, and **three unchanged Debug plus three unchanged Release iterations** of **both** `nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership` and `nativeHTTPConnectionCeilingRejectsOvershootAndRecovers`. Every step has its own log and actual exit code. A failed fixture link does not hide independent test results.

Optionally also test `baseline` as a third independent source snapshot. After the focused runs, execute a fresh `full` pass for the desired snapshot on each machine; `full` repeats the focused checks and adds SDK/fixture suites plus the **original official server and client MCP referee** in both Debug and Release. Full requires Node/npm.

```bash
# Run only on the named machine; do not run both on one computer.
bash Scripts/ci-parity-run.sh pr20 macbook full
bash Scripts/ci-parity-run.sh pr20 studio full
```

## Outputs and comparison

Every call creates an **additional unique** directory at `~/MCP-CI-Parity/<machine>-<snapshot>-<UTC>-XXXXXX/` containing:

- `host.txt`: macOS **build** and version, arm64 hardware model (not serial), Swift/Xcode/SDK paths and versions, disk and host load.
- `source.txt`: exact commit checked out and whether the resolved graph has drifted from the recorded commit.
- `dependencies.txt` and `dependency-drift.diff`: effective SwiftNIO, Core, Swift HTTP Server and Swift-JSON SHAs in **both** root/fixture SwiftPM graphs.
- `results.tsv`: all commands and exit codes; `stalled-traces.txt`: raw `STALLED_WRITER` observables across trials; `logs/`: detailed compiler/linker/test logs.
- `report.tar.gz`: a portable bundle of evidence without the clone or build caches. **Review logs before publicly attaching**; full conformance output can contain test request data.

An unchanged HTTP source SHA is **not sufficient** if Core's mutable dependency moved. Compare actual dependency SHA lines, Xcode and `sw_vers -buildVersion` before comparing test outcomes.

### What each outcome means

- Identical undefined ARM64 metadata symbols on both Macs under identical toolchain and effective graph: **cross-module/compiler/library code issue**, not slow hardware.
- Release fails but Debug passes on both under equal dependencies: **optimizer-dependent lifecycle/observability defect** to investigate. Do not loosen the assertion or deadline.
- Failure only when Core and HTTP builds share the same host: plausible **resource contention**; repeat in isolation first.
- Failure only on one host: check OS beta **build**, active Xcode, SDK, security settings, disk, services and actual resolved graph; do not infer a hardware fault before controls pass.

## Optional explicit host routing in GitHub Actions

A manual `host-parity.yml` workflow is included on the diagnostics branch. After this branch has been reviewed and merged into the repo **default branch**, it can be run from **Actions → macOS host parity (manual) → Run workflow**.

**Before using the workflow**, add a unique custom label to the *specific* HTTP runner in **Settings → Actions → Runners**: `mcp-macbook` on the MacBook Pro runner, `mcp-studio` on the Mac Studio runner, and retain their normal `self-hosted` / `macOS` / `macos-27` labels. Do not apply both labels to one runner. If the Studio is not registered to the HTTP repo, it needs registration first. These runner-admin actions cannot be performed by a documentation/CI PR.

The new workflow is **manual only**, does not alter existing release CI or enable automatic expensive parity runs, and will target its chosen host by label. The two local commands above are available **immediately**, without merging the diagnostic branch or changing runner labels.

## Reporting

Attach or share the two `host.txt`, `source.txt`, `dependencies.txt`, `results.tsv` and failing test logs to [HTTP #22](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/22). Separately track optimized link failures in HTTP #13 and SwiftNIO early-EOF in HTTP #12. No release, merge or tagging is authorized by this diagnostic alone.
