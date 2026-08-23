#!/usr/bin/env bash
#
# make-cert.sh — create (or verify) a stable, self-signed code-signing
# identity named "tmux-switcher-dev" in the login keychain.
#
# WHY THIS MATTERS:
# Ad-hoc signing (`codesign -s -`) derives the app's identity from its
# CDHash, which changes on every single rebuild. macOS Accessibility (TCC)
# grants are tied to that identity, so an ad-hoc-signed agent silently loses
# its Accessibility permission every time it's rebuilt — with no error, just
# a HUD that stops appearing. A self-signed certificate gives a stable
# *designated requirement* derived from the leaf certificate's identity
# instead of the binary's hash, so rebuilding the app does NOT invalidate
# the TCC grant. This script exists solely to make that identity durable.
#
# ON TRUST (and why this script no longer fails without it):
# Trusting the certificate is OPTIONAL and affects none of the above. The
# designated requirement codesign derives from it is a hash comparison
# against the leaf certificate --
#     identifier "..." and certificate leaf = H"<sha1>"
# -- which never walks a trust chain. An untrusted self-signed certificate
# therefore protects the Accessibility grant exactly as well as a trusted
# one. Trust only affects Gatekeeper assessment (`spctl`), which never runs
# on locally built code, because locally built code is never quarantined.
#
# So every check below uses `security find-identity` WITHOUT `-v`. The `-v`
# form lists only explicitly trusted certificates, and using it meant this
# script exited 1 -- printing a page of manual Keychain Access instructions
# -- on machines where the certificate was present, usable, and already
# signing apps correctly. `make sign` checks this same non-`-v` condition.
#
set -euo pipefail

IDENTITY_NAME="tmux-switcher-dev"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TRUST_TIMEOUT_SECS=8

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Idempotency check: if the identity already exists, we're done. Trust is
#    not part of the condition -- see ON TRUST above.
#
#    The here-string is not stylistic. Under `set -o pipefail`, `grep -q`
#    exits the instant it matches, the upstream `security` takes SIGPIPE, and
#    the pipeline reports failure precisely when the identity WAS found. That
#    only works today because the output fits in the pipe buffer, which is not
#    a property worth depending on.
# ---------------------------------------------------------------------------
if grep -q "\"${IDENTITY_NAME}\"" <<< "$(security find-identity -p codesigning 2>/dev/null || true)"; then
    log "Identity \"${IDENTITY_NAME}\" already exists in the keychain. Nothing to do."
    security find-identity -p codesigning
    exit 0
fi

WORKDIR="$(mktemp -d)"
cleanup() {
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT
CERT_FILE="${WORKDIR}/tmux-switcher-dev.pem"

# A previous run may have imported the certificate already but failed to get
# it trusted (e.g. the manual Keychain Access step below hasn't been done
# yet). In that case, re-use the existing certificate instead of generating
# a fresh keypair every time this script is re-run — otherwise the keychain
# accumulates duplicate "tmux-switcher-dev" certificates, which then makes
# every `security ... -c tmux-switcher-dev` lookup ambiguous.
if security find-certificate -c "${IDENTITY_NAME}" -p "${LOGIN_KEYCHAIN}" > "${CERT_FILE}" 2>/dev/null \
    && [ -s "${CERT_FILE}" ]; then
    log "Found an existing \"${IDENTITY_NAME}\" certificate in the keychain, but no"
    log "usable identity for it (the private key may be missing). Re-using the"
    log "certificate rather than generating a duplicate."
else
    log "No existing \"${IDENTITY_NAME}\" certificate found. Creating one..."

    # ---------------------------------------------------------------------
    # 2. Generate a self-signed cert + key in a temp dir (trap-cleaned so the
    #    private key / .p12 never linger on disk outside of it).
    # ---------------------------------------------------------------------
    KEY_FILE="${WORKDIR}/tmux-switcher-dev.key"
    P12_FILE="${WORKDIR}/tmux-switcher-dev.p12"

    log "Generating self-signed code-signing certificate (RSA 2048, 10 years)..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/CN=${IDENTITY_NAME}" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning"

    # -----------------------------------------------------------------
    # 3. Package as PKCS#12 and import into the login keychain, trusting
    #    /usr/bin/codesign to use the key without prompting.
    #
    # NOTE ON THE PASSPHRASE: an empty PKCS#12 password was tried first
    # (as one might expect for a throwaway file), but on this machine's
    # OpenSSL 3.6.3 + macOS combination it reproducibly fails `security
    # import` with "MAC verification failed during PKCS12 import" — a
    # long-standing incompatibility between OpenSSL's and Apple's
    # handling of the empty-password case in the PKCS#12 MAC, independent
    # of cipher/MAC-algorithm choice (verified against -legacy, -nomac,
    # alternate -macalg, and -keypbe/-certpbe combinations; all fail the
    # same way with an empty password, all succeed with a non-empty one).
    # So a random, ephemeral passphrase is generated instead, used only
    # for the few seconds it takes to export+import, and never written
    # anywhere but this trap-cleaned temp dir or printed to any output.
    # -----------------------------------------------------------------
    P12_PASSPHRASE="$(openssl rand -base64 24)"

    log "Packaging as PKCS#12..."
    openssl pkcs12 -export -legacy \
        -inkey "${KEY_FILE}" \
        -in "${CERT_FILE}" \
        -out "${P12_FILE}" \
        -passout "pass:${P12_PASSPHRASE}"

    log "Importing into login keychain (${LOGIN_KEYCHAIN})..."
    security import "${P12_FILE}" \
        -k "${LOGIN_KEYCHAIN}" \
        -P "${P12_PASSPHRASE}" \
        -T /usr/bin/codesign \
        -T /usr/bin/security
    unset P12_PASSPHRASE
fi

# ---------------------------------------------------------------------------
# 4. Trust: attempted opportunistically, and NOT required. It only affects
#    Gatekeeper assessment (`spctl`); the stable designated requirement that
#    protects the Accessibility grant comes from the certificate itself, not
#    from any trust setting on it. See ON TRUST at the top.
#
# This cert is self-signed (issuer == subject), so the correct Security
# Trust Settings result type is "trustRoot" (using "trustAsRoot" on an
# already-self-signed cert fails immediately with a parameter error).
#
# `add-trusted-cert` on the user domain can still block on a GUI
# authorization dialog in some session contexts (observed firsthand: it
# hangs indefinitely rather than failing fast when there's no interactive
# Aqua session available to show that dialog). It's wrapped in a bounded
# timeout so this script can never hang forever — if trust doesn't resolve
# quickly, we fall through to printing manual instructions rather than
# leaving the user staring at a stuck terminal.
# ---------------------------------------------------------------------------
run_with_timeout() {
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "${secs}"; kill -9 "${pid}" 2>/dev/null ) &
    local watcher=$!
    local rc
    if wait "${pid}" 2>/dev/null; then rc=0; else rc=$?; fi
    kill "${watcher}" 2>/dev/null || true
    wait "${watcher}" 2>/dev/null || true
    return "${rc}"
}

log "Attempting to trust the certificate for code signing (user domain)..."
if run_with_timeout "${TRUST_TIMEOUT_SECS}" security add-trusted-cert -r trustRoot -p codeSign "${CERT_FILE}"; then
    log "Trust established in the user domain."
else
    log "Could not establish trust non-interactively within ${TRUST_TIMEOUT_SECS}s. Continuing."
    log "This is not a failure. Signing works without it, and so does the stable"
    log "designated requirement that protects the Accessibility grant -- see ON"
    log "TRUST at the top of this script. Trust only changes how \`spctl\` assesses"
    log "the app, and \`spctl\` never runs on locally built code."
    log "To set it anyway: Keychain Access > login > My Certificates >"
    log "\"${IDENTITY_NAME}\" > Trust > Code Signing > Always Trust."
fi

# ---------------------------------------------------------------------------
# 5. Verify. The condition being checked is "codesign can use this identity",
#    not "this identity is trusted" -- so, again, no `-v`. This is the exact
#    check `make sign` performs before it will sign anything.
# ---------------------------------------------------------------------------
log "Verifying the identity is available to codesign..."
if grep -q "\"${IDENTITY_NAME}\"" <<< "$(security find-identity -p codesigning 2>/dev/null || true)"; then
    log "Success. Current codesigning identities:"
    security find-identity -p codesigning
    exit 0
else
    warn "Identity \"${IDENTITY_NAME}\" was imported but does not show up via"
    warn "\`security find-identity -p codesigning\`. This usually means the keychain"
    warn "search list does not include ${LOGIN_KEYCHAIN}."
    warn "Current state:"
    security find-identity -p codesigning || true
    exit 1
fi
