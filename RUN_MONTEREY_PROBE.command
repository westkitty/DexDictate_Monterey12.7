#!/bin/bash
# Run with: bash RUN_MONTEREY_PROBE.command [--no-mic] [--clean]
# This intentionally tests the exact DexDictate SwiftWhisper revision on CPU/Accelerate.

set -u
set -o pipefail

readonly SWIFTWHISPER_REVISION="deb1cb6a27256c7b01f5d3d2e7dc1dcc330b5d01"
readonly EXPECTED_PHRASE="The quick brown fox jumps over the lazy dog. This is a Monterey compatibility test."
readonly MIC_EXPECTED_PHRASE="Whisper microphone test on Monterey one two three four five"
readonly TINY_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin"
readonly BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
# SHA-256 values are the Hugging Face LFS object hashes for the two canonical files.
readonly TINY_SHA256="921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"
readonly BASE_SHA256="a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002"
readonly MIN_FREE_KB=4194304

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)"
cd "$SCRIPT_DIR" || {
    printf 'BLOCKED_SETUP: cannot enter the downloaded probe directory.\n' >&2
    exit 20
}
CACHE_ROOT="${HOME}/Library/Caches/DexDictateMontereyProbe"
MODEL_DIR="${CACHE_ROOT}/models"
AUDIO_DIR="${CACHE_ROOT}/audio"
LOG_DIR="${CACHE_ROOT}/logs"
REPORTS_DIR="${CACHE_ROOT}/reports"
NO_MIC=0
CLEAN=0

for argument in "$@"; do
    case "$argument" in
        --no-mic) NO_MIC=1 ;;
        --clean) CLEAN=1 ;;
        --help|-h)
            printf '%s\n' 'Usage: bash RUN_MONTEREY_PROBE.command [--no-mic] [--clean]'
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$argument" >&2
            exit 64
            ;;
    esac
done

# A Rosetta shell on Apple Silicon reports x86_64 and would invalidate the result.
ROSETTA_STATE="not-detected"
if [ "$(sysctl -in sysctl.proc_translated 2>/dev/null || printf '0')" = "1" ]; then
    if [ "${DEX_MONTEREY_PROBE_REEXEC:-0}" != "1" ]; then
        printf '%s\n' 'Rosetta-translated shell detected; re-executing natively as arm64.'
        DEX_MONTEREY_PROBE_REEXEC=1 exec /usr/bin/arch -arm64 /bin/bash "$0" "$@"
    fi
    ROSETTA_STATE="re-executed-natively-arm64"
fi

if [ "$CLEAN" = "1" ]; then
    # These are the only two locations this project creates. No user data is touched.
    rm -rf -- "$CACHE_ROOT" "$SCRIPT_DIR/.build"
    printf 'Removed probe cache and local SwiftPM build artifacts.\n'
    exit 0
fi

mkdir -p "$MODEL_DIR" "$AUDIO_DIR" "$LOG_DIR" "$REPORTS_DIR" || {
    printf 'BLOCKED_SETUP: cannot create the probe cache under ~/Library/Caches.\n' >&2
    exit 20
}

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
REPORT_DIR="${REPORTS_DIR}/${RUN_ID}"
mkdir -p "$REPORT_DIR" || exit 20
LOG_FILE="${REPORT_DIR}/probe.log"
TEXT_REPORT="${REPORT_DIR}/probe-report.txt"
JSON_REPORT="${REPORT_DIR}/probe-report.json"
exec > >(tee -a "$LOG_FILE") 2>&1

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
os_name="$(sw_vers -productName 2>/dev/null || printf unknown)"
os_version="$(sw_vers -productVersion 2>/dev/null || printf unknown)"
process_arch="$(uname -m 2>/dev/null || printf unknown)"
hardware_model="$(sysctl -n hw.model 2>/dev/null || printf unknown)"
cpu_brand="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf unknown)"
physical_ram="$(sysctl -n hw.memsize 2>/dev/null || printf unknown)"
developer_directory="$(xcode-select -p 2>/dev/null || printf unavailable)"
swift_version="$(swift --version 2>&1 | tr '\n' ' ' || true)"
clang_version="$(clang --version 2>&1 | head -1 || true)"
free_kb="$(df -Pk "$CACHE_ROOT" | awk 'NR == 2 { print $4 }')"

os_status="PASS"
arch_status="PASS"
toolchain_status="NOT_RUN"
dependency_status="NOT_RUN"
build_status="NOT_RUN"
tiny_download_status="NOT_RUN"
base_download_status="NOT_RUN"
tiny_run1_status="NOT_RUN"
tiny_run2_status="NOT_RUN"
base_run1_status="NOT_RUN"
base_run2_status="NOT_RUN"
mic_status="SKIPPED"
mic_capture_status="SKIPPED"
mic_conversion_status="SKIPPED"
sidecar_status="NOT_RUN"
failure_stage=""
failure_message=""
final_verdict=""
exit_code=20
tiny_run1_json='null'
tiny_run2_json='null'
base_run1_json='null'
base_run2_json='null'
mic_json='null'
build_duration_ms=0
native_linkage="not-built"

json_quote() {
    printf '%s' "$1" | tr '\n\r\t' '   ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN { printf "\"" } { printf "%s", $0 } END { printf "\"" }'
}

print_box() {
    printf '%s\n' '============================================================'
    printf '%s\n' ' DEXDICTATE MONTEREY WHISPER PROBE'
    printf '%s\n' '============================================================'
    printf ' OS                 %s                 %s\n' "$os_version" "$os_status"
    printf ' ARCH               %s / %s        %s\n' "$process_arch" "$hardware_model" "$arch_status"
    printf ' TOOLCHAIN                                      %s\n' "$toolchain_status"
    printf ' SWIFTWHISPER PIN   %.12s...             %s\n' "$SWIFTWHISPER_REVISION" "$dependency_status"
    printf ' TINY DOWNLOAD                                  %s\n' "$tiny_download_status"
    printf ' TINY RUN #1                                   %s\n' "$tiny_run1_status"
    printf ' TINY RUN #2                                   %s\n' "$tiny_run2_status"
    printf ' BASE DOWNLOAD                                  %s\n' "$base_download_status"
    printf ' BASE RUN #1                                   %s\n' "$base_run1_status"
    printf ' BASE RUN #2                                   %s\n' "$base_run2_status"
    printf ' MICROPHONE                                     %s\n' "$mic_status"
    printf ' COREML SIDECAR                                 %s\n' "$sidecar_status"
    printf '%s\n' '------------------------------------------------------------'
    printf ' FINAL VERDICT      %s\n' "$final_verdict"
    printf '%s\n' '============================================================'
    printf 'Report:\n%s\n\nJSON:\n%s\n' "$TEXT_REPORT" "$JSON_REPORT"
}

write_reports() {
    cat > "$TEXT_REPORT" <<EOF
DEXDICTATE MONTEREY WHISPER PROBE
Timestamp: $timestamp

Machine preflight
  OS: $os_name $os_version ($os_status)
  Process architecture: $process_arch ($arch_status)
  Hardware model: $hardware_model
  CPU: $cpu_brand
  Physical RAM bytes: $physical_ram
  Free disk KiB: $free_kb (minimum: $MIN_FREE_KB)
  Rosetta state: $ROSETTA_STATE
  Developer directory: $developer_directory
  Swift: $swift_version
  Clang: $clang_version

Dependency and build
  SwiftWhisper revision: $SWIFTWHISPER_REVISION ($dependency_status)
  Build: $build_status (${build_duration_ms} ms)
  Native linkage: $native_linkage

Assets
  Tiny URL: $TINY_URL
  Tiny SHA-256: $TINY_SHA256 ($tiny_download_status)
  Base URL: $BASE_URL
  Base SHA-256: $BASE_SHA256 ($base_download_status)
  CoreML encoder sidecar: $sidecar_status (intentionally absent)

Deterministic phrase
  Expected: $EXPECTED_PHRASE
  Tiny run #1: $tiny_run1_status
  Tiny run #2: $tiny_run2_status
  Base run #1: $base_run1_status
  Base run #2: $base_run2_status

Microphone
  Overall: $mic_status
  Capture: $mic_capture_status
  16 kHz mono conversion: $mic_conversion_status
  Expected diagnostic phrase: $MIC_EXPECTED_PHRASE

Evidence checklist
  A OS identity: $os_status
  B Apple Silicon architecture: $arch_status
  C local Apple toolchain: $toolchain_status
  D exact SwiftPM revision resolution: $dependency_status
  E compile: $build_status
  F Tiny model load: $tiny_run1_status
  G Tiny correct transcription: $tiny_run1_status
  H Tiny repeated transcription: $tiny_run2_status
  I Base model load: $base_run1_status
  J Base correct transcription: $base_run1_status
  K Base repeated transcription: $base_run2_status
  L microphone capture: $mic_capture_status
  M microphone conversion: $mic_conversion_status
  N microphone transcription: $mic_status
  O no CoreML encoder sidecar: $sidecar_status
  P timing/stability: Tiny #1/#2 and Base #1/#2 result JSON below

Final verdict: $final_verdict
Failure stage: $failure_stage
Failure message: $failure_message

Tiny run #1 JSON: $tiny_run1_json
Tiny run #2 JSON: $tiny_run2_json
Base run #1 JSON: $base_run1_json
Base run #2 JSON: $base_run2_json
Microphone JSON: $mic_json
EOF

    printf '{\n' > "$JSON_REPORT"
    printf '  "timestamp": %s,\n' "$(json_quote "$timestamp")" >> "$JSON_REPORT"
    printf '  "os_name": %s,\n' "$(json_quote "$os_name")" >> "$JSON_REPORT"
    printf '  "os_version": %s,\n' "$(json_quote "$os_version")" >> "$JSON_REPORT"
    printf '  "architecture": %s,\n' "$(json_quote "$process_arch")" >> "$JSON_REPORT"
    printf '  "hardware_model": %s,\n' "$(json_quote "$hardware_model")" >> "$JSON_REPORT"
    printf '  "cpu": %s,\n' "$(json_quote "$cpu_brand")" >> "$JSON_REPORT"
    printf '  "physical_ram_bytes": %s,\n' "$(json_quote "$physical_ram")" >> "$JSON_REPORT"
    printf '  "free_disk_kib": %s,\n' "$(json_quote "$free_kb")" >> "$JSON_REPORT"
    printf '  "rosetta_state": %s,\n' "$(json_quote "$ROSETTA_STATE")" >> "$JSON_REPORT"
    printf '  "developer_directory": %s,\n' "$(json_quote "$developer_directory")" >> "$JSON_REPORT"
    printf '  "swift_version": %s,\n' "$(json_quote "$swift_version")" >> "$JSON_REPORT"
    printf '  "clang_version": %s,\n' "$(json_quote "$clang_version")" >> "$JSON_REPORT"
    printf '  "swiftwhisper_revision": %s,\n' "$(json_quote "$SWIFTWHISPER_REVISION")" >> "$JSON_REPORT"
    printf '  "build": {"status": %s, "duration_ms": %s, "native_linkage": %s},\n' "$(json_quote "$build_status")" "$build_duration_ms" "$(json_quote "$native_linkage")" >> "$JSON_REPORT"
    printf '  "models": {"tiny": {"url": %s, "sha256": %s, "status": %s, "size_bytes": %s}, "base": {"url": %s, "sha256": %s, "status": %s, "size_bytes": %s}},\n' \
        "$(json_quote "$TINY_URL")" "$(json_quote "$TINY_SHA256")" "$(json_quote "$tiny_download_status")" "$(wc -c < "$MODEL_DIR/ggml-tiny.en.bin" 2>/dev/null || printf 0)" \
        "$(json_quote "$BASE_URL")" "$(json_quote "$BASE_SHA256")" "$(json_quote "$base_download_status")" "$(wc -c < "$MODEL_DIR/ggml-base.en.bin" 2>/dev/null || printf 0)" >> "$JSON_REPORT"
    printf '  "tiny": {"run_1": %s, "run_2": %s},\n' "$tiny_run1_json" "$tiny_run2_json" >> "$JSON_REPORT"
    printf '  "base": {"run_1": %s, "run_2": %s},\n' "$base_run1_json" "$base_run2_json" >> "$JSON_REPORT"
    printf '  "microphone": {"status": %s, "capture_status": %s, "conversion_status": %s, "result": %s},\n' "$(json_quote "$mic_status")" "$(json_quote "$mic_capture_status")" "$(json_quote "$mic_conversion_status")" "$mic_json" >> "$JSON_REPORT"
    printf '  "coreml_sidecar_present": %s,\n' "$( [ "$sidecar_status" = "ABSENT_INTENTIONALLY" ] && printf false || printf true)" >> "$JSON_REPORT"
    printf '  "final_verdict": %s,\n' "$(json_quote "$final_verdict")" >> "$JSON_REPORT"
    printf '  "failure_stage": %s,\n' "$(json_quote "$failure_stage")" >> "$JSON_REPORT"
    printf '  "failure_message": %s\n' "$(json_quote "$failure_message")" >> "$JSON_REPORT"
    printf '}\n' >> "$JSON_REPORT"
}

finish() {
    write_reports
    print_box
    exit "$exit_code"
}

block_setup() {
    failure_stage="$1"
    failure_message="$2"
    final_verdict="BLOCKED_SETUP"
    exit_code=20
    finish
}

echo "DEXDICTATE MONTEREY WHISPER PROBE — preflight"
echo "OS: $os_name $os_version; process architecture: $process_arch; hardware: $hardware_model"

case "$os_version" in
    12.7.6) ;;
    12.*) os_status="TARGET_OS_MISMATCH" ;;
    1[3-9].*|[2-9][0-9].*) os_status="NOT_MONTEREY_DIAGNOSTIC_ONLY" ;;
    *)
        os_status="UNSUPPORTED"
        failure_stage="os"
        failure_message="macOS versions earlier than Monterey 12 are unsupported for this experiment."
        final_verdict="UNSUPPORTED_TARGET"
        exit_code=30
        finish
        ;;
esac

if [ "$process_arch" != "arm64" ]; then
    arch_status="UNSUPPORTED"
    failure_stage="architecture"
    failure_message="The process is not native arm64. This cannot prove the Apple Silicon Monterey target."
    final_verdict="UNSUPPORTED_TARGET"
    exit_code=30
    finish
fi

if [ "$free_kb" -lt "$MIN_FREE_KB" ]; then
    block_setup "disk-space" "Only ${free_kb} KiB is free; this probe requires at least ${MIN_FREE_KB} KiB before build and model download."
fi

if [ "$developer_directory" = "unavailable" ] || ! command -v swift >/dev/null 2>&1 || ! command -v clang >/dev/null 2>&1; then
    toolchain_status="MISSING"
    xcode-select --install >/dev/null 2>&1 || true
    block_setup "toolchain" "Apple Command Line Tools are unavailable. Complete Apple's installer, then rerun this script."
fi
toolchain_status="PASS"

if ! swift --version >/dev/null 2>&1 || ! clang --version >/dev/null 2>&1; then
    toolchain_status="FAILED"
    block_setup "toolchain" "Swift or clang did not run even though a developer directory was selected."
fi

if [ -d "$MODEL_DIR" ] && find "$MODEL_DIR" -name '*-encoder.mlmodelc' -print -quit | grep -q .; then
    sidecar_status="PRESENT_REJECTED"
    failure_stage="coreml-sidecar"
    failure_message="A Core ML encoder sidecar exists in the probe model directory; this CPU/Accelerate experiment refuses it."
    final_verdict="BLOCKED_SETUP"
    exit_code=20
    finish
fi
sidecar_status="ABSENT_INTENTIONALLY"

build_start="$(date +%s)"
if swift package resolve && grep -q "$SWIFTWHISPER_REVISION" "$SCRIPT_DIR/Package.resolved" 2>/dev/null; then
    dependency_status="PASS"
else
    dependency_status="FAILED"
    block_setup "swiftpm-resolution" "SwiftPM could not resolve the exact required SwiftWhisper revision."
fi
if swift build -c release; then
    build_status="PASS"
else
    build_status="FAILED"
    build_duration_ms=$(( ($(date +%s) - build_start) * 1000 ))
    failure_stage="build"
    failure_message="The exact SwiftWhisper package failed to compile on this configured machine. See probe.log."
    final_verdict="NO_GO_BUILD"
    exit_code=40
    finish
fi
build_duration_ms=$(( ($(date +%s) - build_start) * 1000 ))
BIN="$SCRIPT_DIR/.build/release/MontereyWhisperProbe"
if [ ! -x "$BIN" ]; then
    build_status="FAILED"
    failure_stage="build-output"
    failure_message="SwiftPM reported success but did not create MontereyWhisperProbe."
    final_verdict="NO_GO_BUILD"
    exit_code=40
    finish
fi
native_linkage="$(otool -L "$BIN" 2>&1 | tr '\n' ' ')"

download_model() {
    local name="$1"
    local url="$2"
    local expected_sha="$3"
    local destination="$MODEL_DIR/$name"
    local temporary="$destination.partial"
    local actual_sha
    if [ -f "$destination" ]; then
        actual_sha="$(shasum -a 256 "$destination" | awk '{print $1}')"
        if [ "$actual_sha" = "$expected_sha" ]; then
            printf 'Reusing verified %s.\n' "$name"
            return 0
        fi
        printf 'Rejecting corrupt cached %s.\n' "$name"
        rm -f -- "$destination"
    fi
    printf 'Downloading %s from the official whisper.cpp model endpoint.\n' "$name"
    if ! curl --fail --location --retry 2 --continue-at - --output "$temporary" "$url"; then
        rm -f -- "$temporary"
        return 10
    fi
    if [ ! -s "$temporary" ]; then
        rm -f -- "$temporary"
        return 11
    fi
    actual_sha="$(shasum -a 256 "$temporary" | awk '{print $1}')"
    if [ "$actual_sha" != "$expected_sha" ]; then
        rm -f -- "$temporary"
        return 12
    fi
    mv -f -- "$temporary" "$destination"
}

if download_model "ggml-tiny.en.bin" "$TINY_URL" "$TINY_SHA256"; then
    tiny_download_status="PASS"
else
    download_failure=$?
    tiny_download_status="FAILED"
    [ "$download_failure" = "12" ] && block_setup "tiny-model-hash" "Tiny model download completed but its SHA-256 did not match the pinned official digest."
    block_setup "tiny-model-network" "Tiny model download failed before a valid SHA-256-verified file was available."
fi
if download_model "ggml-base.en.bin" "$BASE_URL" "$BASE_SHA256"; then
    base_download_status="PASS"
else
    download_failure=$?
    base_download_status="FAILED"
    [ "$download_failure" = "12" ] && block_setup "base-model-hash" "Base model download completed but its SHA-256 did not match the pinned official digest."
    block_setup "base-model-network" "Base model download failed before a valid SHA-256-verified file was available."
fi

FIXTURE_AIFF="${AUDIO_DIR}/deterministic-speech.aiff"
FIXTURE_WAV="${AUDIO_DIR}/deterministic-speech-16k-mono.wav"
rm -f -- "$FIXTURE_AIFF" "$FIXTURE_WAV"
if ! say -o "$FIXTURE_AIFF" "$EXPECTED_PHRASE" || ! afconvert -f WAVE -d LEI16@16000 -c 1 "$FIXTURE_AIFF" "$FIXTURE_WAV"; then
    block_setup "audio-fixture" "Built-in say or afconvert could not create the deterministic 16 kHz mono WAV fixture."
fi
if [ ! -s "$FIXTURE_WAV" ] || ! afinfo "$FIXTURE_WAV" 2>&1 | grep -Eq '16000|16,000'; then
    block_setup "audio-fixture-validation" "The deterministic fixture is missing, empty, or not visibly 16 kHz."
fi

run_file_probe() {
    local label="$1"
    local model="$2"
    local result_file="$REPORT_DIR/${label}.json"
    local output_file="$REPORT_DIR/${label}.stdout.txt"
    if "$BIN" transcribe --model "$model" --audio "$FIXTURE_WAV" --expected "$EXPECTED_PHRASE" --result "$result_file" > "$output_file" 2>&1; then
        cat "$output_file" >&2
        cat "$result_file"
        return 0
    fi
    cat "$output_file" >&2
    [ -f "$result_file" ] && cat "$result_file" || printf 'null'
    return 1
}

if tiny_run1_json="$(run_file_probe tiny-run-1 "$MODEL_DIR/ggml-tiny.en.bin")"; then tiny_run1_status="PASS"; else tiny_run1_status="FAIL"; fi
if tiny_run2_json="$(run_file_probe tiny-run-2 "$MODEL_DIR/ggml-tiny.en.bin")"; then tiny_run2_status="PASS"; else tiny_run2_status="FAIL"; fi
if [ "$tiny_run1_status" != "PASS" ] || [ "$tiny_run2_status" != "PASS" ]; then
    base_run1_status="NOT_RUN_TINY_FAILED"
    base_run2_status="NOT_RUN_TINY_FAILED"
    failure_stage="tiny-runtime"
    failure_message="Tiny did not transcribe the clean deterministic fixture reliably. See result JSON and probe.log."
    final_verdict="NO_GO_TINY_RUNTIME"
    exit_code=50
    finish
fi

if base_run1_json="$(run_file_probe base-run-1 "$MODEL_DIR/ggml-base.en.bin")"; then base_run1_status="PASS"; else base_run1_status="FAIL"; fi
if base_run2_json="$(run_file_probe base-run-2 "$MODEL_DIR/ggml-base.en.bin")"; then base_run2_status="PASS"; else base_run2_status="FAIL"; fi

if [ "$NO_MIC" = "1" ]; then
    mic_status="SKIPPED_BY_FLAG"
    mic_capture_status="SKIPPED_BY_FLAG"
    mic_conversion_status="SKIPPED_BY_FLAG"
else
    printf '%s\n' 'MICROPHONE TEST'
    printf 'When recording begins, clearly say: "%s"\n' "$MIC_EXPECTED_PHRASE"
    printf '%s\n' 'Recording begins in three seconds and lasts seven seconds.'
    sleep 3
    mic_result_file="$REPORT_DIR/microphone.json"
    if "$BIN" microphone --model "$MODEL_DIR/ggml-tiny.en.bin" --seconds 7 --expected "$MIC_EXPECTED_PHRASE" --result "$mic_result_file"; then
        mic_json="$(cat "$mic_result_file")"
        mic_status="PASS"
        mic_capture_status="PASS"
        mic_conversion_status="PASS"
    else
        mic_json="$( [ -f "$mic_result_file" ] && cat "$mic_result_file" || printf null )"
        mic_status="BLOCKED_OR_FAILED"
        case "$mic_json" in
            *MIC_PERMISSION_BLOCKED*) mic_capture_status="PERMISSION_BLOCKED"; mic_conversion_status="NOT_RUN" ;;
            *conversion*) mic_capture_status="PASS"; mic_conversion_status="FAILED" ;;
            *) mic_capture_status="FAILED_OR_UNAVAILABLE"; mic_conversion_status="NOT_REACHED" ;;
        esac
    fi
fi

if [ "$base_run1_status" = "PASS" ] && [ "$base_run2_status" = "PASS" ]; then
    if [ "$mic_status" = "PASS" ] || [ "$mic_status" = "SKIPPED_BY_FLAG" ]; then
        final_verdict="GO_TINY_BASE"
        exit_code=0
    else
        final_verdict="ENGINE_GO_MIC_BLOCKED"
        exit_code=2
        failure_stage="microphone"
        failure_message="Deterministic Tiny and Base engine tests passed, but live microphone validation did not."
    fi
else
    final_verdict="GO_TINY_ONLY"
    exit_code=2
    failure_stage="base-runtime"
    failure_message="Tiny passed twice; Base did not pass twice. A Tiny-only Monterey path remains technically viable."
fi

finish
