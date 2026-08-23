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
set -euo pipefail

IDENTITY_NAME="tmux-switcher-dev"
LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TRUST_TIMEOUT_SECS=8

log()  { printf '==> %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 1. Idempotency check: if the identity already exists AND is trusted, we're
#    done.
# ---------------------------------------------------------------------------
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
    log "Identity \"${IDENTITY_NAME}\" already exists in the keychain. Nothing to do."
    security find-identity -v -p codesigning
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
    log "Found an existing (untrusted) \"${IDENTITY_NAME}\" certificate already in the keychain."
    log "Re-using it and retrying the trust step, instead of generating a new one."
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
# 4. Trust: try the non-interactive user-domain form first. Trusting for
#    code signing is what lets `codesign` build a stable designated
#    requirement from this cert without a GUI prompt on every use.
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
TRUST_OK=0
if run_with_timeout "${TRUST_TIMEOUT_SECS}" security add-trusted-cert -r trustRoot -p codeSign "${CERT_FILE}"; then
    TRUST_OK=1
    log "Trust established in the user domain."
else
    warn "Non-interactive trust (user domain) did not succeed within ${TRUST_TIMEOUT_SECS}s"
    warn "(it may be waiting on a GUI authorization dialog this session can't show)."
    warn "The admin-domain form (security add-trusted-cert -d ...) requires sudo and is not attempted automatically here."
fi

if [ "${TRUST_OK}" -ne 1 ]; then
    cat >&2 <<EOF

------------------------------------------------------------------------------
MANUAL STEP REQUIRED: trust the "${IDENTITY_NAME}" certificate
------------------------------------------------------------------------------
Automatic, non-interactive trust could not be established. The certificate
and private key ARE now in your login keychain and codesign can already use
them, but without explicit trust for code signing, macOS treats signatures
made with it as coming from an unverified source, and \`security
find-identity -v -p codesigning\` will not list it as valid — which this
build's \`make sign\` step checks for. To finish, grant trust manually:

  1. Open Keychain Access (Applications > Utilities > Keychain Access).
  2. Select the "login" keychain in the sidebar, "My Certificates" category.
  3. Find the certificate named "${IDENTITY_NAME}".
  4. Double-click it to open its info panel.
  5. Expand the "Trust" section.
  6. Set "Code Signing" to "Always Trust".
  7. Set the top-level "When using this certificate" pop-up to "Always Trust"
     if you want to be extra sure.
  8. Close the panel; enter your password if prompted.

Why this matters: this trust setting is what gives the certificate a stable
designated requirement macOS will keep honoring across rebuilds — which is
the entire point of using a real certificate instead of ad-hoc signing. It
is what protects your Accessibility permission grant from being silently
revoked every time you rebuild the app.
------------------------------------------------------------------------------

EOF
fi

# ---------------------------------------------------------------------------
# 5. Verify.
# ---------------------------------------------------------------------------
log "Verifying identity is now available to codesign..."
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"${IDENTITY_NAME}\""; then
    log "Success. Current codesigning identities:"
    security find-identity -v -p codesigning
    exit 0
else
    warn "Identity \"${IDENTITY_NAME}\" was imported but is not showing up via"
    warn "\`security find-identity -v -p codesigning\`. This usually means the"
    warn "manual trust step above still needs to be completed, or the keychain"
    warn "search list does not include ${LOGIN_KEYCHAIN}."
    warn "Current state:"
    security find-identity -v -p codesigning || true
    exit 1
fi
