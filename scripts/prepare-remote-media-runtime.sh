#!/bin/bash
set -euo pipefail

if [[ "${SKIP_REMOTE_MEDIA_RUNTIME:-NO}" == "YES" ]]; then
    echo "Skipping remote media runtime bundle for this build."
    exit 0
fi

readonly YTDLP_VERSION="2026.10.26"
readonly YTDLP_SHA256="0f922c15ccc0b83eefa1c8bc9104e434318c4bf16e408e1ee93b7745a6efe0aa"
# QuickJS-NG solves yt-dlp's YouTube JS challenges in ~1.3 MB per arch (Deno was ~95 MB).
readonly QJS_VERSION="0.18.0"
readonly QJS_ARM64_SHA256="91fe89916d3b0a6c01c4dc8382a99c3c1fd91ecfc214aa81ca051902bcce590d"
readonly QJS_X86_64_SHA256="fa2c5dc78095daff566b32fab995ced12927875253b84216b91b834af2ef2b74"
readonly YTDLP_LICENSE_SHA256="7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c"
readonly YTDLP_THIRD_PARTY_LICENSES_SHA256="472aefe951c7db35e1657c1d13fd337140511ed6f2b329205105ad441c5a02b7"
readonly QJS_LICENSE_SHA256="96f73f9d2a16c21a36b418f06073be26e7d6d5e7c1bc99756b21a4f2c74ef171"

readonly TASK_CACHE_ROOT="${DERIVED_FILE_DIR}/RemoteMediaRuntime/${YTDLP_VERSION}-qjs-${QJS_VERSION}"
readonly TASK_DOWNLOADS="${TASK_CACHE_ROOT}/downloads"
readonly TASK_STAGED="${TASK_CACHE_ROOT}/staged"
readonly TASK_DESTINATION="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/RemoteMediaRuntime"

mkdir -p "${TASK_DOWNLOADS}" "${TASK_STAGED}" "${TASK_DESTINATION}"

verify_sha256() {
    local file_path="$1"
    local expected="$2"
    [[ -f "${file_path}" ]] || return 1
    [[ "$(/usr/bin/shasum -a 256 "${file_path}" | /usr/bin/awk '{print $1}')" == "${expected}" ]]
}

fetch_verified() {
    local url="$1"
    local destination="$2"
    local expected="$3"
    if ! verify_sha256 "${destination}" "${expected}"; then
        /usr/bin/curl --fail --location --retry 3 --output "${destination}" "${url}"
    fi
    verify_sha256 "${destination}" "${expected}" || {
        echo "Remote media runtime checksum mismatch: ${destination}" >&2
        exit 1
    }
}

fetch_verified \
    "https://github.com/yt-dlp/yt-dlp/releases/download/${YTDLP_VERSION}/yt-dlp_macos" \
    "${TASK_DOWNLOADS}/yt-dlp_macos" \
    "${YTDLP_SHA256}"

fetch_verified \
    "https://github.com/quickjs-ng/quickjs/releases/download/v${QJS_VERSION}/qjs-darwin-arm64" \
    "${TASK_DOWNLOADS}/qjs-arm64" \
    "${QJS_ARM64_SHA256}"

fetch_verified \
    "https://github.com/quickjs-ng/quickjs/releases/download/v${QJS_VERSION}/qjs-darwin-x86_64" \
    "${TASK_DOWNLOADS}/qjs-x86_64" \
    "${QJS_X86_64_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YTDLP_VERSION}/LICENSE" \
    "${TASK_DOWNLOADS}/yt-dlp-LICENSE.txt" \
    "${YTDLP_LICENSE_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YTDLP_VERSION}/THIRD_PARTY_LICENSES.txt" \
    "${TASK_DOWNLOADS}/yt-dlp-THIRD-PARTY-LICENSES.txt" \
    "${YTDLP_THIRD_PARTY_LICENSES_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/quickjs-ng/quickjs/v${QJS_VERSION}/LICENSE" \
    "${TASK_DOWNLOADS}/qjs-LICENSE.txt" \
    "${QJS_LICENSE_SHA256}"

if [[ ! -x "${TASK_STAGED}/qjs" ]]; then
    /usr/bin/lipo -create \
        "${TASK_DOWNLOADS}/qjs-arm64" \
        "${TASK_DOWNLOADS}/qjs-x86_64" \
        -output "${TASK_STAGED}/qjs"
fi

/bin/cp "${TASK_DOWNLOADS}/yt-dlp_macos" "${TASK_DESTINATION}/yt-dlp_macos"
/bin/cp "${TASK_STAGED}/qjs" "${TASK_DESTINATION}/qjs"
/bin/cp "${TASK_DOWNLOADS}/yt-dlp-LICENSE.txt" "${TASK_DESTINATION}/yt-dlp-LICENSE.txt"
/bin/cp "${TASK_DOWNLOADS}/yt-dlp-THIRD-PARTY-LICENSES.txt" "${TASK_DESTINATION}/yt-dlp-THIRD-PARTY-LICENSES.txt"
/bin/cp "${TASK_DOWNLOADS}/qjs-LICENSE.txt" "${TASK_DESTINATION}/qjs-LICENSE.txt"
/bin/chmod 755 "${TASK_DESTINATION}/yt-dlp_macos" "${TASK_DESTINATION}/qjs"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    # yt-dlp embeds a Python framework whose dynamically loaded extension modules do not
    # carry our Team ID. Keep this exception helper-scoped; the app and QuickJS retain
    # normal hardened-runtime library validation.
    readonly TASK_YTDLP_ENTITLEMENTS="${TASK_CACHE_ROOT}/yt-dlp-entitlements.plist"
    /usr/bin/plutil -create xml1 "${TASK_YTDLP_ENTITLEMENTS}"
    /usr/bin/plutil -insert 'com\.apple\.security\.cs\.disable-library-validation' \
        -bool true \
        "${TASK_YTDLP_ENTITLEMENTS}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --entitlements "${TASK_YTDLP_ENTITLEMENTS}" \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        "${TASK_DESTINATION}/yt-dlp_macos"
    # QuickJS is an interpreter without JIT, so it needs no hardened-runtime exception.
    /usr/bin/codesign \
        --force \
        --options runtime \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        "${TASK_DESTINATION}/qjs"

    # Fail the build if the signed helpers cannot execute their real runtime paths.
    "${TASK_DESTINATION}/yt-dlp_macos" --version >/dev/null
    [[ "$("${TASK_DESTINATION}/qjs" -e 'print(6 * 7)')" == "42" ]]
fi
