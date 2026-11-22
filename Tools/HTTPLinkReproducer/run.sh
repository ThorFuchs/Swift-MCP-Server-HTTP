#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail

variant=${1:-published}
backend=${2:-swiftbuild}
case "$variant" in baseline|published) ;; *) printf 'Usage: bash run.sh [baseline|published] [swiftbuild|native] [output-root]\n' >&2; exit 2 ;; esac
case "$backend" in swiftbuild|native) ;; *) printf 'Unknown build backend: %s\n' "$backend" >&2; exit 2 ;; esac
if [[ $(uname -s) != Darwin ]]; then
    printf 'This probe runner targets the observed macOS linker failure.\n' >&2
    exit 2
fi
for tool in swift xcrun xcodebuild sw_vers python3 shasum; do
    command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 2; }
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
output_root=${3:-"$HOME/MCP-Link-Probes"}
mkdir -p "$output_root"
output=$(mktemp -d "$output_root/$variant-$backend-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")
evidence="$output/evidence"
mkdir -p "$output/package" "$evidence/logs"
printf 'Evidence directory: %s\n' "$evidence"
outcome=setup_incomplete
trap 'result=$?; printf "outcome=%s\nexit_code=%s\n" "$outcome" "$result" > "$evidence/summary.txt"' EXIT
cp "$script_dir/Package.swift" "$output/package/Package.swift"
cp -R "$script_dir/Sources" "$output/package/Sources"
if [[ $variant == baseline ]]; then
    python3 - "$output/package/Package.swift" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = '.package(url: "https://github.com/swift-server/swift-http-server.git", exact: "0.5.0", traits: []),'
new = '.package(url: "https://github.com/swift-server/swift-http-server.git", revision: "0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9", traits: []),'
assert text.count(old) == 1, "Unexpected probe manifest; refusing replacement"
p.write_text(text.replace(old, new))
PY
fi
cp "$output/package/Package.swift" "$evidence/Package.swift"
cp -R "$output/package/Sources" "$evidence/Sources"

export SDKROOT
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
{
    date -u
    sw_vers
    uname -m
    xcode-select -p
    xcodebuild -version
    swift --version
    xcrun --sdk macosx --show-sdk-version
    printf 'variant=%s\nbackend=%s\nSDKROOT=%s\n' "$variant" "$backend" "$SDKROOT"
    shasum -a 256 "$output/package/Package.swift"
    sysctl -n hw.model hw.ncpu hw.memsize
} >"$evidence/host.txt" 2>&1
swift build --help >"$evidence/swift-build-help.txt" 2>&1
printf 'configuration\tproduct\tbuild_exit_code\tverification_exit_code\tclassification\n' >"$evidence/results.tsv"
if swift package --package-path "$output/package" resolve >"$evidence/logs/resolve.log" 2>&1; then
    printf 'resolve\tall\t0\t0\tresolved\n' >>"$evidence/results.tsv"
else
    status=$?
    printf 'resolve\tall\t%s\t0\tsetup_failure\n' "$status" >>"$evidence/results.tsv"
    outcome=resolution_failed
    printf 'Dependency resolution failed; see %s/logs/resolve.log\n' "$evidence" >&2
    exit "$status"
fi
cp "$output/package/Package.resolved" "$evidence/Package.resolved"
shasum -a 256 "$evidence/Package.resolved" >"$evidence/lock-sha256.txt"

failures=0
for configuration in debug release; do
    for product in ConnectionTransferProbe ConnectionDropProbe ReaderDropProbe ReaderCollectProbe; do
        case "$product" in
            ConnectionTransferProbe) symbol=transferConnection ;;
            ConnectionDropProbe) symbol=rejectOrTransferConnection ;;
            ReaderDropProbe) symbol=dropReader ;;
            ReaderCollectProbe) symbol=collectReader ;;
        esac
        log="$evidence/logs/$configuration-$product.log"
        if swift build --package-path "$output/package" --scratch-path "$output/build-$configuration" \
            --build-system "$backend" --configuration "$configuration" --jobs 2 --product "$product" -v >"$log" 2>&1; then
            status=0
        else
            status=$?
        fi
        verification=0
        classification=build_failed_without_matching_metadata
        if [[ $status -eq 0 ]]; then
            if binary_dir=$(swift build --package-path "$output/package" --scratch-path "$output/build-$configuration" \
                --build-system "$backend" --configuration "$configuration" --show-bin-path \
                2>"$evidence/logs/$configuration-$product-bin-path.log"); then
                binary="$binary_dir/lib$product.dylib"
                printf '%s\n' "$binary" >>"$evidence/binaries.txt"
                if [[ -f "$binary" ]] && xcrun nm -gU "$binary" >"$evidence/logs/$configuration-$product-exports.txt" 2>&1 \
                    && grep -Fq "$symbol" "$evidence/logs/$configuration-$product-exports.txt"; then
                    classification=linked_and_export_verified
                else
                    verification=1
                    classification=artifact_or_export_verification_failed
                fi
            else
                verification=$?
                classification=bin_path_query_failed
            fi
        elif python3 - "$log" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text(errors="replace")
marker = "Undefined symbols for architecture"
if marker not in text:
    raise SystemExit(1)
text = text[text.index(marker):]
pattern = r'type metadata accessor for NIOHTTPServer\.(?:NIOHTTPServer\.)?(?:Connection\.HTTPProtocol|Reader\.State(?:\.Reading)?)"'
raise SystemExit(0 if re.search(pattern, text) else 1)
PY
        then
            classification=matching_undefined_metadata
        fi
        if [[ $status -ne 0 || $verification -ne 0 ]]; then failures=$((failures + 1)); fi
        printf '%s\t%s\t%s\t%s\t%s\n' "$configuration" "$product" "$status" "$verification" "$classification" >>"$evidence/results.tsv"
        printf '[%s/%s] %s: build=%s verification=%s %s\n' "$variant" "$backend" "$configuration-$product" "$status" "$verification" "$classification"
        if [[ $status -ne 0 || $verification -ne 0 ]]; then
            tail -n 35 "$log"
            for detail in "$evidence/logs/$configuration-$product-bin-path.log" "$evidence/logs/$configuration-$product-exports.txt"; do
                if [[ -s "$detail" ]]; then tail -n 10 "$detail"; fi
            done
        fi
    done
done
if ! cmp -s "$output/package/Package.resolved" "$evidence/Package.resolved"; then
    cp "$output/package/Package.resolved" "$evidence/Package.final.resolved"
    printf 'dependency-drift\tall\t0\t1\tdependency_drift\n' >>"$evidence/results.tsv"
    failures=$((failures + 1))
fi
printf 'Results: %s/results.tsv\n' "$evidence"
printf 'Failed builds or verifications: %s\n' "$failures"
outcome=probe_failures_recorded
if (( failures != 0 )); then exit 1; fi
outcome=all_probe_products_linked_not_a_fix_claim
