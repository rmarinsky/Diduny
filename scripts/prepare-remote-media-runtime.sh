#!/bin/bash
set -euo pipefail

if [[ "${SKIP_REMOTE_MEDIA_RUNTIME:-NO}" == "YES" ]]; then
    echo "Skipping remote media runtime bundle for this build."
    exit 0
fi

readonly YTDLP_VERSION="2026.06.09"
readonly YTDLP_SHA256="b82c3626952e6c14eaf654cc565866775ffd0b9ffb7021628ac59b42c2f4f244"
readonly DENO_VERSION="2.8.1"
readonly DENO_ARM64_SHA256="8154e2de0ee8c1cae31fa88e078724aaef0295fab9fd2ad6f8520389cee908f6"
readonly DENO_X86_64_SHA256="47473845e0522ba11dd279e3dd318e2d84ee200c56b8280594e0ae0b0f827460"
readonly YTDLP_LICENSE_SHA256="7e12e5df4bae12cb21581ba157ced20e1986a0508dd10d0e8a4ab9a4cf94e85c"
readonly YTDLP_THIRD_PARTY_LICENSES_SHA256="b085c65586a953cdb4b13c6390d63ec984d66912e4b6a19e66ba3582f2ed104b"
readonly DENO_LICENSE_SHA256="f62497fffecc0852960c8d3e6934b9db86d16396e9b604072e923892cae3a588"

readonly TASK_CACHE_ROOT="${DERIVED_FILE_DIR}/RemoteMediaRuntime/${YTDLP_VERSION}-${DENO_VERSION}"
readonly TASK_DOWNLOADS="${TASK_CACHE_ROOT}/downloads"
readonly TASK_UNPACKED="${TASK_CACHE_ROOT}/unpacked"
readonly TASK_STAGED="${TASK_CACHE_ROOT}/staged"
readonly TASK_DESTINATION="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/RemoteMediaRuntime"

mkdir -p "${TASK_DOWNLOADS}" "${TASK_UNPACKED}/arm64" "${TASK_UNPACKED}/x86_64" "${TASK_STAGED}" "${TASK_DESTINATION}"

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
    "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-aarch64-apple-darwin.zip" \
    "${TASK_DOWNLOADS}/deno-arm64.zip" \
    "${DENO_ARM64_SHA256}"

fetch_verified \
    "https://github.com/denoland/deno/releases/download/v${DENO_VERSION}/deno-x86_64-apple-darwin.zip" \
    "${TASK_DOWNLOADS}/deno-x86_64.zip" \
    "${DENO_X86_64_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YTDLP_VERSION}/LICENSE" \
    "${TASK_DOWNLOADS}/yt-dlp-LICENSE.txt" \
    "${YTDLP_LICENSE_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/yt-dlp/yt-dlp/${YTDLP_VERSION}/THIRD_PARTY_LICENSES.txt" \
    "${TASK_DOWNLOADS}/yt-dlp-THIRD-PARTY-LICENSES.txt" \
    "${YTDLP_THIRD_PARTY_LICENSES_SHA256}"

fetch_verified \
    "https://raw.githubusercontent.com/denoland/deno/v${DENO_VERSION}/LICENSE.md" \
    "${TASK_DOWNLOADS}/deno-LICENSE.md" \
    "${DENO_LICENSE_SHA256}"

if [[ ! -x "${TASK_STAGED}/deno" ]]; then
    /usr/bin/ditto -x -k "${TASK_DOWNLOADS}/deno-arm64.zip" "${TASK_UNPACKED}/arm64"
    /usr/bin/ditto -x -k "${TASK_DOWNLOADS}/deno-x86_64.zip" "${TASK_UNPACKED}/x86_64"
    /usr/bin/lipo -create \
        "${TASK_UNPACKED}/arm64/deno" \
        "${TASK_UNPACKED}/x86_64/deno" \
        -output "${TASK_STAGED}/deno"
fi

/bin/cp "${TASK_DOWNLOADS}/yt-dlp_macos" "${TASK_DESTINATION}/yt-dlp_macos"
/bin/cp "${TASK_STAGED}/deno" "${TASK_DESTINATION}/deno"
/bin/cp "${TASK_DOWNLOADS}/yt-dlp-LICENSE.txt" "${TASK_DESTINATION}/yt-dlp-LICENSE.txt"
/bin/cp "${TASK_DOWNLOADS}/yt-dlp-THIRD-PARTY-LICENSES.txt" "${TASK_DESTINATION}/yt-dlp-THIRD-PARTY-LICENSES.txt"
/bin/cp "${TASK_DOWNLOADS}/deno-LICENSE.md" "${TASK_DESTINATION}/deno-LICENSE.md"
/bin/chmod 755 "${TASK_DESTINATION}/yt-dlp_macos" "${TASK_DESTINATION}/deno"

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "NO" && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    # yt-dlp embeds a Python framework whose dynamically loaded extension modules do not
    # carry our Team ID. Keep this exception helper-scoped; the app and Deno retain
    # normal hardened-runtime library validation.
    readonly TASK_YTDLP_ENTITLEMENTS="${TASK_CACHE_ROOT}/yt-dlp-entitlements.plist"
    readonly TASK_DENO_ENTITLEMENTS="${TASK_CACHE_ROOT}/deno-entitlements.plist"
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
    # Deno embeds V8. Hardened runtime must explicitly allow its JIT or macOS
    # terminates the helper when V8 reserves executable memory.
    /usr/bin/plutil -create xml1 "${TASK_DENO_ENTITLEMENTS}"
    /usr/bin/plutil -insert 'com\.apple\.security\.cs\.allow-jit' \
        -bool true \
        "${TASK_DENO_ENTITLEMENTS}"
    /usr/bin/codesign \
        --force \
        --options runtime \
        --entitlements "${TASK_DENO_ENTITLEMENTS}" \
        --sign "${EXPANDED_CODE_SIGN_IDENTITY}" \
        "${TASK_DESTINATION}/deno"

    # Fail the build if the signed helpers cannot execute their real runtime paths.
    # Deno colorizes stdout even with NO_COLOR; strip ANSI before comparing.
    "${TASK_DESTINATION}/yt-dlp_macos" --version >/dev/null
    deno_probe="$(
        "${TASK_DESTINATION}/deno" eval 'console.log(6 * 7)' \
            | /usr/bin/sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' \
            | /usr/bin/tr -d '[:space:]'
    )"
    [[ "${deno_probe}" == "42" ]]
fi
