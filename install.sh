#!/usr/bin/env bash
#
# install.sh — one-shot installer for tmux-switcher.
#
#   curl -fsSL https://raw.githubusercontent.com/jekuari/tmux-switcher/main/install.sh | bash
#
# WHY BUILD FROM SOURCE RATHER THAN DOWNLOAD A BINARY:
# macOS quarantines anything a browser or curl marks as downloaded, and
# Gatekeeper then demands a Developer ID signature plus a notarization ticket
# before it will launch it. tmux-switcher has neither (that needs a paid Apple
# Developer Program membership), so a prebuilt download would be a dead end.
# Code compiled on the machine it runs on is never quarantined, so Gatekeeper
# never gets involved. That is the entire reason this script builds instead of
# unpacking.
#
# The app is then signed with a self-signed "tmux-switcher-dev" certificate.
# That is NOT about Gatekeeper -- it is about the Accessibility permission.
# Ad-hoc signing derives the app's identity from a hash of the binary, which
# changes on every rebuild, so macOS silently revokes the Accessibility grant
# each time you update. A certificate-anchored signature keeps the identity
# stable across rebuilds, so the grant survives.
#
# Environment variables:
#   TMUX_SWITCHER_VERSION   Install a specific release, e.g. v0.2.0.
#                           Defaults to the latest release, or the main branch
#                           if the project has not tagged one yet.
#   TMUX_SWITCHER_REF       Install a branch or commit instead of a release.
#   TMUX_SWITCHER_URL       Install from an arbitrary source tarball URL, for
#                           forks and mirrors. Skips the checksum lookup.
#   TMUX_SWITCHER_INSTALL_DIR
#                           Where to install the .app. Defaults to
#                           /Applications, falling back to ~/Applications
#                           automatically when /Applications is not writable.
#
# Everything is wrapped in main() and invoked on the very last line, so a
# truncated download cannot execute a half-read script.

set -euo pipefail

REPO="jekuari/tmux-switcher"
APP_NAME="TmuxSwitcher"
IDENTITY="tmux-switcher-dev"
INSTALL_DIR="${TMUX_SWITCHER_INSTALL_DIR:-/Applications}"
MIN_MACOS_MAJOR=14
REQUIRED_SDK_MAJOR=26

WORKDIR=""

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
    # guard still has to exist in the SDK at compile time. This is the one
    # requirement that cannot be worked around from here, so it is checked
    # up front rather than surfacing as a wall of compiler errors.
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

# Picks where the app lands. On a managed machine /Applications typically
# needs elevated privileges, so rather than failing -- or asking a piped-into-
# bash script to prompt for a sudo password -- this falls back to
# ~/Applications, which needs none. macOS treats that as a first-class app
# location: Login Items, the Privacy & Security > Accessibility list and
# LaunchServices all handle it identically, which is the whole reason the
# fallback is safe rather than a compromise.
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
    warn "${INSTALL_DIR} is not writable by $(id -un), so installing there would need sudo."
    warn "Falling back to ${fallback}, which does not."
    warn "macOS treats ~/Applications as a first-class location -- Login Items and the"
    warn "Accessibility list will show the app exactly the same way."
    warn "To install to ${INSTALL_DIR} anyway, use a checkout and elevate only the copy:"
    warn "    make install SUDO=sudo"
    INSTALL_DIR="${fallback}"
    mkdir -p "${INSTALL_DIR}" || die "Could not create ${INSTALL_DIR}."
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

    verify_checksum "$1"

    mkdir -p "${WORKDIR}/src"
    # --strip-components=1 drops the single top-level directory every GitHub
    # tarball and `git archive --prefix` tarball has, whatever it is named.
    tar xzf "${WORKDIR}/source.tar.gz" -C "${WORKDIR}/src" --strip-components=1

    [ -f "${WORKDIR}/src/Makefile" ] || die "The downloaded archive does not look like tmux-switcher (no Makefile inside)."
}

# Releases publish a SHA256SUMS asset. When one is available the tarball is
# verified against it; when it is not (a branch install, or a release predating
# the checksums file) the download falls back to TLS alone, and says so rather
# than implying an integrity check that did not happen.
verify_checksum() {
    local url="$1"
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

    actual="$(shasum -a 256 "${WORKDIR}/source.tar.gz" | awk '{print $1}')"
    if [ "${expected}" != "${actual}" ]; then
        die "Checksum mismatch for ${filename}.
    expected: ${expected}
    actual:   ${actual}
    Refusing to build. This is worth reporting."
    fi
    log "Integrity: sha256 verified against SHA256SUMS"
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
    if ! grep -q "Authority=${IDENTITY}" <<< "${signature}"; then
        warn "Could not confirm the signing authority is '${IDENTITY}'. Check: codesign -dvvv ${app}"
    fi

    log "Verified: ${app} is signed with a stable, certificate-anchored identity"
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
    check_toolchain
    check_tmux
    resolve_install_dir

    WORKDIR="$(mktemp -d)"
    trap cleanup EXIT

    local source url version label
    source="$(resolve_source)"
    url="${source%%|*}"
    version="$(printf '%s' "${source}" | cut -d'|' -f2)"
    label="${source##*|}"

    fetch_source "${url}" "${label}"
    ensure_identity
    build_and_install "${version}"
    verify_install
    print_next_steps
}

main "$@"
