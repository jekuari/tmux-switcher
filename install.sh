#!/usr/bin/env bash
#
# install.sh — one-shot installer for tmux-switcher.
#
#   curl -fsSL https://raw.githubusercontent.com/jekuari/tmux-switcher/main/install.sh | bash
#
# Installs the Developer ID-signed, Apple-notarized build from the latest
# release: downloads the .dmg, mounts it, and copies the app out. No Swift
# toolchain needed for this path.
#
# If no signed release is published yet — or you set TMUX_SWITCHER_BUILD=1,
# TMUX_SWITCHER_REF, or TMUX_SWITCHER_URL — it falls back to building from
# source instead, via `make cert && make install`. That needs the Command
# Line Tools and the macOS 26 SDK, and produces a locally self-signed build
# (see "Building from source" in the README for why that identity is stable
# across your own rebuilds, even though it differs from the release build's).
#
# Environment variables:
#   TMUX_SWITCHER_VERSION   Install a specific release, e.g. v0.2.0.
#                           Defaults to the latest release.
#   TMUX_SWITCHER_BUILD     Set to any value to build from source even if a
#                           signed release is available.
#   TMUX_SWITCHER_REF       Build a branch or commit from source instead.
#   TMUX_SWITCHER_URL       Build from an arbitrary source tarball URL, for
#                           forks and mirrors. Skips the checksum lookup.
#   TMUX_SWITCHER_INSTALL_DIR
#                           Where to install the .app. /Applications (the
#                           default) makes it available to every user of the
#                           Mac; ~/Applications installs it for the current
#                           user only. When /Applications is not writable
#                           without admin rights, a per-user install is chosen
#                           automatically.
#
# Everything is wrapped in main() and invoked on the very last line, so a
# truncated download cannot execute a half-read script.

set -euo pipefail

REPO="jekuari/tmux-switcher"
APP_NAME="TmuxSwitcher"
EXEC_REL="Contents/MacOS/${APP_NAME}"
IDENTITY="tmux-switcher-dev"
INSTALL_DIR="${TMUX_SWITCHER_INSTALL_DIR:-/Applications}"
MIN_MACOS_MAJOR=14
REQUIRED_SDK_MAJOR=26

WORKDIR=""
STAGED=""
INSTALL_METHOD=""

# ---------------------------------------------------------------- output

if [ -t 1 ]; then
    BOLD=$'\033[1m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; GREEN=$'\033[32m'; RESET=$'\033[0m'
else
    BOLD=""; RED=""; YELLOW=""; GREEN=""; RESET=""
fi

log()  { printf '%s==>%s %s\n' "${BOLD}" "${RESET}" "$*"; }
warn() { printf '%s!! %s %s\n' "${YELLOW}" "${RESET}" "$*" >&2; }
die()  { printf '%s!! %s %s\n' "${RED}" "${RESET}" "$*" >&2; exit 1; }

cleanup() {
    [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ] && rm -rf "${WORKDIR}"
    return 0
}

# ---------------------------------------------------------------- checks

check_platform() {
    [ "$(uname -s)" = "Darwin" ] || die "tmux-switcher is macOS-only (this is $(uname -s))."

    local version major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    if [ "${major}" -lt "${MIN_MACOS_MAJOR}" ]; then
        die "macOS ${MIN_MACOS_MAJOR} or newer is required (this is ${version})."
    fi
    log "macOS ${version}"
}

# Only needed on the build-from-source fallback — the default release
# download needs no Swift toolchain at all.
check_toolchain() {
    if ! xcode-select -p > /dev/null 2>&1; then
        die "No Swift toolchain found. Install the Command Line Tools first:
    xcode-select --install
Then re-run this installer."
    fi
    command -v swift > /dev/null 2>&1 || die "'swift' is not on PATH. Try: xcode-select --install"

    # tmux-switcher runs on macOS 14+, but *building* it needs the macOS 26
    # SDK: OverlayView.swift references NSGlassEffectView behind an
    # #available(macOS 26.0, *) check, and a symbol behind an availability
    # guard still has to exist in the SDK at compile time.
    local sdk major
    sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo "0")"
    major="${sdk%%.*}"
    if [ "${major}" -lt "${REQUIRED_SDK_MAJOR}" ]; then
        die "Building tmux-switcher needs the macOS ${REQUIRED_SDK_MAJOR} SDK, but the
    installed toolchain provides ${sdk}.

    Update the Command Line Tools (or Xcode) and try again:
      Software Update, or:  xcode-select --install

    The app itself still runs on macOS ${MIN_MACOS_MAJOR}+ -- this is a build-time
    requirement only, because the HUD's Liquid Glass code path references a
    macOS 26 API behind an availability check."
    fi
    log "Swift $(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1), macOS SDK ${sdk}"
}

check_tmux() {
    # Not fatal: the HUD is a visualizer for a tmux setup that is expected to
    # already exist, but installing it with no tmux at all is almost certainly
    # not what someone meant to do.
    command -v tmux > /dev/null 2>&1 || warn "tmux was not found on PATH. tmux-switcher will install, but it has nothing to visualize until tmux is installed and configured (see the README)."
}

# Picks where the app lands: /Applications (all users of the Mac) or
# ~/Applications (the current user only). Both are first-class app locations --
# Login Items, the Privacy & Security > Accessibility list and LaunchServices
# treat them identically -- so a per-user install is a real choice, not a
# lesser one. When /Applications needs admin rights the installer does not fail
# or prompt a piped-into-bash script for a password; it installs for the
# current user instead, which needs none.
resolve_install_dir() {
    if [ -n "${TMUX_SWITCHER_INSTALL_DIR:-}" ]; then
        if ! mkdir -p "${INSTALL_DIR}" 2>/dev/null; then
            die "Cannot create ${INSTALL_DIR} (from TMUX_SWITCHER_INSTALL_DIR)."
        fi
        log "Installing to ${INSTALL_DIR} (set via TMUX_SWITCHER_INSTALL_DIR)"
        return
    fi

    if [ -d "${INSTALL_DIR}" ] && [ -w "${INSTALL_DIR}" ]; then
        log "Installing to ${INSTALL_DIR}"
        return
    fi

    local fallback="${HOME}/Applications"
    log "${INSTALL_DIR} needs admin rights to write to, so installing for ${USER} only."
    log "Using ${fallback} -- a per-user install macOS treats identically: Login Items"
    log "and the Accessibility list show the app exactly the same way."
    log "To install to ${INSTALL_DIR} for all users instead, use a checkout and elevate"
    log "only the copy: make install SUDO=sudo"
    INSTALL_DIR="${fallback}"
    mkdir -p "${INSTALL_DIR}" || die "Could not create ${INSTALL_DIR}."
}

# Releases publish a SHA256SUMS asset. When one is available the download is
# verified against it; when it is not (a branch install, or a release
# predating the checksums file) it falls back to TLS alone, and says so
# rather than implying an integrity check that did not happen.
verify_checksum() {
    local url="$1" local_path="$2"
    local sums_url="${url%/*}/SHA256SUMS"
    local filename="${url##*/}"

    case "${url}" in
        *"/releases/download/"*) ;;
        *) log "Integrity: TLS only (installing from a branch, which has no published checksums)"; return 0 ;;
    esac

    if ! curl -fsSL --retry 2 -o "${WORKDIR}/SHA256SUMS" "${sums_url}" 2>/dev/null; then
        warn "No SHA256SUMS published for this release; relying on TLS alone."
        return 0
    fi

    local expected actual
    expected="$(sed -n "s/^\([0-9a-f]\{64\}\)  *${filename}$/\1/p" "${WORKDIR}/SHA256SUMS" | head -1)"
    if [ -z "${expected}" ]; then
        warn "SHA256SUMS does not list ${filename}; relying on TLS alone."
        return 0
    fi

    actual="$(shasum -a 256 "${local_path}" | awk '{print $1}')"
    if [ "${expected}" != "${actual}" ]; then
        die "Checksum mismatch for ${filename}.
    expected: ${expected}
    actual:   ${actual}
    Refusing to install. This is worth reporting."
    fi
    log "Integrity: sha256 verified against SHA256SUMS"
}

# --------------------------------------------------------- release download

# Sets STAGED and INSTALL_METHOD=release on success. Returns 1 (does not die)
# when a signed release isn't available or wasn't asked for, so the caller
# can fall back to building from source.
fetch_release_dmg() {
    [ -z "${TMUX_SWITCHER_BUILD:-}" ] || return 1
    [ -z "${TMUX_SWITCHER_REF:-}" ] || return 1
    [ -z "${TMUX_SWITCHER_URL:-}" ] || return 1

    log "Looking for a published release of ${REPO}"
    local tag
    tag="${TMUX_SWITCHER_VERSION:-}"
    if [ -z "${tag}" ]; then
        tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
    fi
    [ -n "${tag}" ] || return 1

    local version="${tag#v}"
    # Matches the asset name produced by .github/workflows/release.yml.
    local url="https://github.com/${REPO}/releases/download/${tag}/${APP_NAME}-${version}.dmg"

    log "Downloading ${APP_NAME}-${version}.dmg (${tag})"
    curl -fsSL --retry 3 -o "${WORKDIR}/release.dmg" "${url}" || return 1
    verify_checksum "${url}" "${WORKDIR}/release.dmg"

    local mount
    mount="$(hdiutil attach -nobrowse -readonly "${WORKDIR}/release.dmg" \
             | tail -1 | awk -F'\t' '{print $NF}')"
    [ -n "${mount}" ] || die "Could not mount the downloaded disk image."

    ditto "${mount}/${APP_NAME}.app" "${WORKDIR}/${APP_NAME}.app"
    hdiutil detach "${mount}" -quiet || true

    [ -d "${WORKDIR}/${APP_NAME}.app" ] || die "Disk image did not contain ${APP_NAME}.app."
    STAGED="${WORKDIR}/${APP_NAME}.app"
    INSTALL_METHOD="release"
}

install_staged_app() {
    local target="${INSTALL_DIR}/${APP_NAME}.app"

    if pgrep -f "${APP_NAME}.app/${EXEC_REL}" > /dev/null 2>&1; then
        log "Stopping the running copy"
        pkill -f "${APP_NAME}.app/${EXEC_REL}" || true
        sleep 1
    fi

    log "Installing to ${INSTALL_DIR}"
    rm -rf "${target}"
    ditto "${STAGED}" "${target}"
    xattr -dr com.apple.quarantine "${target}" 2>/dev/null || true

    local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    [ -x "${lsregister}" ] && "${lsregister}" -f "${target}" > /dev/null 2>&1 || true
}

# ---------------------------------------------------------------- source

# Prints "<url>|<strip-prefix>|<label>" for the source to install.
resolve_source() {
    if [ -n "${TMUX_SWITCHER_URL:-}" ]; then
        printf '%s|%s|%s' "${TMUX_SWITCHER_URL}" "" "${TMUX_SWITCHER_URL}"
        return
    fi

    if [ -n "${TMUX_SWITCHER_REF:-}" ]; then
        printf '%s|%s|%s' \
            "https://github.com/${REPO}/archive/${TMUX_SWITCHER_REF}.tar.gz" \
            "" \
            "ref ${TMUX_SWITCHER_REF}"
        return
    fi

    local tag="${TMUX_SWITCHER_VERSION:-}"
    if [ -z "${tag}" ]; then
        tag="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
            | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1 || true)"
    fi

    if [ -z "${tag}" ]; then
        # No tagged release yet (or the API is unreachable). The main branch is
        # a better answer than failing outright for a project this young.
        printf '%s|%s|%s' \
            "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" \
            "" \
            "main branch (no tagged release found)"
        return
    fi

    # Matches the asset name produced by .github/workflows/release.yml.
    printf '%s|%s|%s' \
        "https://github.com/${REPO}/releases/download/${tag}/tmux-switcher-${tag#v}.tar.gz" \
        "${tag#v}" \
        "${tag}"
}

fetch_source() {
    local url="$1" label="$2"

    log "Downloading ${label}"
    if ! curl -fsSL --retry 3 -o "${WORKDIR}/source.tar.gz" "${url}"; then
        die "Could not download ${url}
    Check the version exists, or set TMUX_SWITCHER_REF=main to build the latest source."
    fi

    verify_checksum "${url}" "${WORKDIR}/source.tar.gz"

    mkdir -p "${WORKDIR}/src"
    # --strip-components=1 drops the single top-level directory every GitHub
    # tarball and `git archive --prefix` tarball has, whatever it is named.
    tar xzf "${WORKDIR}/source.tar.gz" -C "${WORKDIR}/src" --strip-components=1

    [ -f "${WORKDIR}/src/Makefile" ] || die "The downloaded archive does not look like tmux-switcher (no Makefile inside)."
}

# ---------------------------------------------------------------- install

ensure_identity() {
    log "Ensuring the '${IDENTITY}' signing identity exists"

    # `make cert` is allowed to fail here, deliberately. Its final check uses
    # `security find-identity -v`, which lists only certificates that are
    # explicitly *trusted* -- and trust is not what matters. The designated
    # requirement codesign produces is a hash comparison against the leaf
    # certificate ("certificate leaf = H\"...\""); it never walks a trust
    # chain, so an untrusted self-signed cert protects the Accessibility grant
    # exactly as well as a trusted one. Trust only affects Gatekeeper
    # assessment, which never runs on locally built code. So the real
    # condition -- does the identity exist at all, which is what `make sign`
    # checks -- is tested directly instead of trusting the exit status.
    make -C "${WORKDIR}/src" cert || true

    # Note the here-string rather than a pipe into grep. Under `set -o
    # pipefail`, `grep -q` exits the instant it matches, the upstream command
    # takes SIGPIPE, and the pipeline reports failure *because* the match
    # succeeded -- so the naive form is wrong exactly when the identity exists.
    local identities
    identities="$(security find-identity -p codesigning 2>/dev/null || true)"
    if ! grep -q "\"${IDENTITY}\"" <<< "${identities}"; then
        die "Could not create the '${IDENTITY}' signing identity.
    Without it the app can only be ad-hoc signed, and macOS would revoke its
    Accessibility permission on every update. Run 'make cert' by hand in a
    checkout to see the full error."
    fi
}

build_and_install() {
    local version="$1"
    local -a make_args=(-C "${WORKDIR}/src" install "INSTALL_DIR=${INSTALL_DIR}")
    [ -n "${version}" ] && make_args+=("VERSION=${version}")

    log "Building and installing to ${INSTALL_DIR} (this takes a minute)"
    if ! make "${make_args[@]}"; then
        die "Build or install failed. The output above has the details."
    fi
    INSTALL_METHOD="source"
}

build_from_source() {
    if [ -n "${TMUX_SWITCHER_BUILD:-}" ]; then
        log "Building from source (TMUX_SWITCHER_BUILD is set)"
    else
        log "No signed release published — building from source"
    fi

    check_toolchain

    local source url version label
    source="$(resolve_source)"
    url="${source%%|*}"
    version="$(printf '%s' "${source}" | cut -d'|' -f2)"
    label="${source##*|}"

    fetch_source "${url}" "${label}"
    ensure_identity
    build_and_install "${version}"
}

verify_install() {
    local app="${INSTALL_DIR}/${APP_NAME}.app"
    [ -d "${app}" ] || die "Expected ${app} to exist after install, but it does not."

    # Captured once and matched with here-strings, for the pipefail/SIGPIPE
    # reason described in ensure_identity.
    local signature
    signature="$(codesign -dvvv "${app}" 2>&1 || true)"

    if grep -q '^Signature=adhoc' <<< "${signature}"; then
        die "${app} ended up ad-hoc signed. Its Accessibility permission would be
    revoked on every update. This is a bug -- please report it."
    fi

    if [ "${INSTALL_METHOD}" = "release" ]; then
        if ! grep -q 'Authority=Developer ID Application' <<< "${signature}"; then
            warn "Could not confirm the signing authority is a Developer ID certificate. Check: codesign -dvvv ${app}"
        fi
        log "Verified: ${app} is signed with a Developer ID, Apple-notarized identity"
    else
        if ! grep -q "Authority=${IDENTITY}" <<< "${signature}"; then
            warn "Could not confirm the signing authority is '${IDENTITY}'. Check: codesign -dvvv ${app}"
        fi
        log "Verified: ${app} is signed with a stable, certificate-anchored identity"
    fi
}

print_next_steps() {
    cat <<EOF

${GREEN}${BOLD}tmux-switcher is installed.${RESET}

${BOLD}1. Grant Accessibility access${RESET} (required -- the HUD cannot work without it)

   System Settings > Privacy & Security > Accessibility > enable ${APP_NAME}

   You should only ever need to do this once. The app is signed with a stable
   identity, so updating it will not revoke the grant.

${BOLD}2. Make sure tmux sets the window title to the session name${RESET}

   Without this the HUD never appears -- deliberately, since it has no way to
   anchor the list to where you actually are. In your tmux.conf:

     set -g set-titles on
     set -g set-titles-string "#S"

${BOLD}3. Launch it${RESET}

     open "${INSTALL_DIR}/${APP_NAME}.app"

   To start it automatically at login, add it under
   System Settings > General > Login Items.

${BOLD}Optional:${RESET} tmux hooks that keep the session cache warm are printed above.
Configuration lives in ~/.config/tmux-switcher/config.json (hot-reloaded on
save); every key is optional. See the README for the full list.

To uninstall:  pkill -x ${APP_NAME}; rm -rf ${INSTALL_DIR}/${APP_NAME}.app

EOF
}

# ---------------------------------------------------------------- main

main() {
    printf '\n%stmux-switcher installer%s\n\n' "${BOLD}" "${RESET}"

    check_platform
    check_tmux
    resolve_install_dir

    WORKDIR="$(mktemp -d)"
    trap cleanup EXIT

    if fetch_release_dmg; then
        install_staged_app
    else
        build_from_source
    fi

    verify_install
    print_next_steps
}

main "$@"
