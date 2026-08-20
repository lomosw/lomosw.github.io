#!/usr/bin/env bash
#
# One-click installer for lomod (lomorage's personal photo backup backend) on macOS.
#
# Intended to be run the same way Claude Code's own installer is:
#
#     curl -fsSL https://lomosw.lomorage.com/macos/install.sh | bash
#
# This is a secondary, advanced/CLI install path -- mirrors installers/windows/install.ps1.
# The primary recommended macOS install is still the LomoAgent GUI installer (LomoAgentOSX,
# see en/mac.html on lomosw.github.io); this script installs the bare lomod backend with no
# GUI/tray/onboarding, for users who'd rather script it.
#
# Everything here runs at the current user's permission level -- no sudo, no admin rights, no
# system LaunchDaemon. It installs into ~/Library/Application Support, autostarts via a
# per-user LaunchAgent (RunAtLoad only, no KeepAlive -- so `lomorage-stop.sh` actually stops
# it until next login or a manual restart, same as the Windows Startup-folder shortcut rather
# than a supervised service), and defaults to a single local backup folder with mDNS disabled
# so first run doesn't trigger a macOS firewall prompt.
#
# Safe to re-run: it stops any already-running lomod, replaces the install directory, and
# restarts it, so this script also serves as a manual repair/reinstall/update path pending a
# scheduled self-update wired on top of cmd/lomoupg.
#
# Flags (all optional; env vars of the same name in SCREAMING_SNAKE_CASE also work):
#   --install-dir <dir>    Where lomod and its bundled dependencies (vips/ffmpeg dylibs,
#                           exiftool) are installed. Default: ~/Library/Application Support/Lomorage/lomod
#   --data-dir <dir>       Where photos/videos and the sqlite catalog are stored (the "single
#                           local folder" desktop mode -- no Samba/USB-mount/mDNS features).
#                           Default: ~/Pictures/Lomorage
#   --release-url <url>    Where to fetch the release manifest (see installers/release.json.example
#                           for the schema). Default: https://lomorage.com/release.json -- the
#                           same production manifest LomoAgent's own updater uses, but this
#                           script reads its own 'macos-cli-<arch>' key, never the 'darwin' key
#                           LomoAgent itself uses, so the two installers' release info can
#                           never collide.
#   --manifest-key <key>   Which top-level key of the release manifest to read. Default:
#                           macos-cli-arm64 or macos-cli-amd64, chosen from `uname -m`.
#   --port <port>          Default: 8000
#   --no-browser           Skip auto-opening the default browser to the local setup UI after install.
#
# LOMOD_CHINA=1  Route the release tarball download through https://gfw.lomorage.com/<url>
#                instead of directly from GitHub Releases -- same accelerator proxy already used
#                for the zh download links on lomosw.github.io (LomoAgentWin/LomoAgentOSX/
#                Android/pi-gen etc), since GitHub Releases asset downloads are often slow or
#                unreachable from mainland China otherwise. Mirrors installers/windows/
#                install.ps1's $env:LOMOD_CHINA. Only the tarball download is affected -- the
#                release manifest fetch (--release-url) already goes to lomorage.com's own
#                domain, not GitHub. No --china flag (env var only): this script is normally
#                invoked as `curl | bash`, which has no clean way to pass flags through the pipe,
#                but a var set on the right-hand command of a pipeline is visible to it:
#                    curl -fsSL https://lomosw.lomorage.com/mac/install.sh | LOMOD_CHINA=1 bash
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-${HOME}/Library/Application Support/Lomorage/lomod}"
DATA_DIR="${DATA_DIR:-${HOME}/Pictures/Lomorage}"
RELEASE_URL="${RELEASE_URL:-https://lomorage.com/release.json}"
MANIFEST_KEY="${MANIFEST_KEY:-}"
PORT="${PORT:-8000}"
NO_BROWSER="${NO_BROWSER:-}"
CHINA="${LOMOD_CHINA:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --release-url) RELEASE_URL="$2"; shift 2 ;;
        --manifest-key) MANIFEST_KEY="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --no-browser) NO_BROWSER=1; shift ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

LABEL="com.lomorage.lomod"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

step() { printf '\033[36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!!\033[0m %s\n' "$1" >&2; }
fail() { printf '\033[31mInstall failed:\033[0m %s\n' "$1" >&2; exit 1; }

case "$(uname -s)" in
    Darwin) ;;
    *) fail "this installer is for macOS only" ;;
esac

ARCH_RAW="$(uname -m)"
case "${ARCH_RAW}" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="amd64" ;;
    *) warn "unrecognized architecture '${ARCH_RAW}', assuming amd64"; ARCH="amd64" ;;
esac
if [[ -z "${MANIFEST_KEY}" ]]; then
    MANIFEST_KEY="macos-cli-${ARCH}"
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required to parse the release manifest but wasn't found (install Xcode Command Line Tools: xcode-select --install)"
fi

sha256_hex() {
    shasum -a 256 "$1" | awk '{print $1}'
}

manifest_field() {
    printf '%s' "${MANIFEST_JSON}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
platform = data.get(sys.argv[1])
if not platform:
    sys.exit(1)
val = platform.get(sys.argv[2])
if val is None:
    sys.exit(1)
print(val)
' "${MANIFEST_KEY}" "$1"
}

stop_existing_lomod() {
    local stop_script="${INSTALL_DIR}/lomorage-stop.sh"
    if [[ -x "${stop_script}" ]]; then
        step "Stopping any running lomod"
        "${stop_script}" || true
        sleep 1
    fi
}

register_autostart() {
    mkdir -p "$(dirname "${PLIST_PATH}")"
    cat > "${PLIST_PATH}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/lomorage-start.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
}

wait_for_lomod() {
    local timeout=30 start_ts now_ts
    start_ts="$(date +%s)"
    while true; do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/mount" 2>/dev/null; then
            return 0
        fi
        now_ts="$(date +%s)"
        if (( now_ts - start_ts >= timeout )); then
            return 1
        fi
        sleep 0.5
    done
}

trap 'fail "unexpected error on line $LINENO"' ERR

step "Fetching release manifest from ${RELEASE_URL}"
MANIFEST_JSON="$(curl -fsSL "${RELEASE_URL}")" || fail "could not fetch ${RELEASE_URL}"

PLATFORM_URL="$(manifest_field URL)" || fail "release manifest at ${RELEASE_URL} has no usable '${MANIFEST_KEY}' entry (expected URL/SHA256/Version fields, see installers/release.json.example)"
PLATFORM_SHA256="$(manifest_field SHA256)" || fail "release manifest entry '${MANIFEST_KEY}' is missing SHA256"
PLATFORM_VERSION="$(manifest_field Version)" || fail "release manifest entry '${MANIFEST_KEY}' is missing Version"

stop_existing_lomod

DOWNLOAD_URL="${PLATFORM_URL}"
CHINA_SUFFIX=""
if [[ -n "${CHINA}" ]]; then
    DOWNLOAD_URL="https://gfw.lomorage.com/${PLATFORM_URL}"
    CHINA_SUFFIX=" via gfw.lomorage.com proxy"
fi

step "Downloading lomod ${PLATFORM_VERSION}${CHINA_SUFFIX}"
TMP_DIR="$(mktemp -d -t lomorage-macos)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TMP_TARBALL="${TMP_DIR}/lomorage-macos-${PLATFORM_VERSION}.tar.gz"
curl -fsSL -o "${TMP_TARBALL}" "${DOWNLOAD_URL}" || fail "download of ${DOWNLOAD_URL} failed"

# lowercase via tr, not bash 4's ${var,,}: macOS ships bash 3.2 (Apple stopped updating bash
# at the last GPLv2 release), which doesn't support that expansion.
ACTUAL_SHA256="$(sha256_hex "${TMP_TARBALL}" | tr 'A-Z' 'a-z')"
EXPECTED_SHA256="$(printf '%s' "${PLATFORM_SHA256}" | tr 'A-Z' 'a-z')"
if [[ "${ACTUAL_SHA256}" != "${EXPECTED_SHA256}" ]]; then
    fail "downloaded file does not match the expected SHA256 in the release manifest.
expected: ${EXPECTED_SHA256}
actual:   ${ACTUAL_SHA256}
This could mean a corrupted download or a tampered release -- aborting."
fi

step "Installing to ${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
tar -xzf "${TMP_TARBALL}" -C "${INSTALL_DIR}"
chmod +x "${INSTALL_DIR}/lomod" "${INSTALL_DIR}/lomorage-start.sh" "${INSTALL_DIR}/lomorage-stop.sh"

printf '%s' "${PLATFORM_VERSION}" > "${INSTALL_DIR}/version.txt"

mkdir -p "${DATA_DIR}"
cat > "${INSTALL_DIR}/lomod.args" <<ARGS
LOMOD_ARGS=(--base "${DATA_DIR}" --exe-dir "${INSTALL_DIR}" --no-mdns --port ${PORT})
ARGS

step "Registering autostart (per-user, no admin required)"
register_autostart

step "Starting lomod"
if wait_for_lomod; then
    echo ""
    echo -e "\033[32mlomorage is running: http://localhost:${PORT}\033[0m"
    echo "  install dir: ${INSTALL_DIR}"
    echo "  data dir:    ${DATA_DIR}"
    echo "  it will start automatically next time you log in"
    echo "  to stop it, run: ${INSTALL_DIR}/lomorage-stop.sh"
    if [[ -z "${NO_BROWSER}" ]]; then
        open "http://localhost:${PORT}" || true
    fi
else
    warn "lomod was installed and launched, but didn't respond on http://localhost:${PORT} within 30s. Check that nothing else is using that port, or run ${INSTALL_DIR}/lomod directly from a terminal to see its output."
fi
