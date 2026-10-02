#!/usr/bin/env bash
#
# get-isos.sh - download FreeBSD, Slackware and Void Linux ISOs
#
# Usage:
#   ./get-isos.sh [-d DEST_DIR] [-n] [freebsd] [slackware] [void] [all]
#
#   -d DIR   download directory (default: ./isos)
#   -n       skip checksum verification
#   no target given = all three
#
# Env overrides:
#   FREEBSD_VER   (default 15.1)
#   FREEBSD_ISO   (default FreeBSD-<ver>-RELEASE-amd64-disc1.iso)
#                 e.g. -dvd1.iso, -bootonly.iso, or .img for memstick
#   VOID_ISO      pin a specific Void image filename; otherwise the newest
#                 xfce glibc image is auto-detected from the mirror
#
set -euo pipefail

DEST="./isos"
VERIFY=1

FREEBSD_VER="${FREEBSD_VER:-15.1}"
FREEBSD_ISO="${FREEBSD_ISO:-FreeBSD-${FREEBSD_VER}-RELEASE-amd64-disc1.iso}"
FREEBSD_BASE="https://download.freebsd.org/releases/amd64/amd64/ISO-IMAGES/${FREEBSD_VER}"
FREEBSD_SUMS="CHECKSUM.SHA256-FreeBSD-${FREEBSD_VER}-RELEASE-amd64"

SLACK_BASE="https://mirrors.slackware.com/slackware/slackware-iso/slackware64-15.0-iso"
SLACK_ISO="slackware64-15.0-install-dvd.iso"

VOID_BASE="https://repo-default.voidlinux.org/live/current"
VOID_FALLBACK="void-live-x86_64-20250202-xfce.iso"
VOID_ISO="${VOID_ISO:-}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m  %s\n' "$*" >&2; exit 1; }

# ---- pick a downloader -----------------------------------------------------
if command -v curl >/dev/null 2>&1; then
    fetch()     { curl -fL --retry 3 --retry-delay 2 -C - -o "$2" "$1"; }
    fetch_txt() { curl -fsL --retry 3 "$1"; }
elif command -v wget >/dev/null 2>&1; then
    fetch()     { wget -c --tries=3 -O "$2" "$1"; }
    fetch_txt() { wget -qO- --tries=3 "$1"; }
else
    die "need curl or wget installed"
fi

# ---- checksum helpers ------------------------------------------------------
hash_of() {  # hash_of ALGO FILE
    case "$1" in
        sha256) if command -v sha256sum >/dev/null 2>&1; then sha256sum "$2" | awk '{print $1}'
                else shasum -a 256 "$2" | awk '{print $1}'; fi ;;
        md5)    if command -v md5sum >/dev/null 2>&1; then md5sum "$2" | awk '{print $1}'
                else md5 -q "$2"; fi ;;
    esac
}

verify() {  # verify ALGO FILE EXPECTED
    local algo="$1" file="$2" want="$3" got
    if [[ -z "$want" ]]; then warn "no checksum found for $(basename "$file"); skipping verify"; return 0; fi
    log "Verifying $algo for $(basename "$file")"
    got="$(hash_of "$algo" "$file")"
    if [[ "$got" == "$want" ]]; then
        log "OK  $got"
    else
        die "$algo MISMATCH for $file (expected $want, got $got)"
    fi
}

download() {  # download URL FILE  (skips if already present and non-empty & verified later)
    local url="$1" out="$2"
    log "Downloading $(basename "$out")"
    log "  from $url"
    fetch "$url" "$out"
}

# ---- per-OS routines -------------------------------------------------------
get_freebsd() {
    local out="$DEST/$FREEBSD_ISO" sums want=""
    download "$FREEBSD_BASE/$FREEBSD_ISO" "$out"
    if (( VERIFY )); then
        sums="$(fetch_txt "$FREEBSD_BASE/$FREEBSD_SUMS" || true)"
        # format: SHA256 (file) = hash
        want="$(awk -v f="($FREEBSD_ISO)" '$2==f {print $NF}' <<<"$sums")"
        verify sha256 "$out" "$want"
    fi
}

get_slackware() {
    local out="$DEST/$SLACK_ISO" sums want=""
    download "$SLACK_BASE/$SLACK_ISO" "$out"
    if (( VERIFY )); then
        # format: hash  file
        sums="$(fetch_txt "$SLACK_BASE/$SLACK_ISO.md5" || true)"
        want="$(awk '{print $1; exit}' <<<"$sums")"
        verify md5 "$out" "$want"
    fi
}

get_void() {
    local iso="$VOID_ISO" out sums want=""
    if [[ -z "$iso" ]]; then
        log "Looking for newest Void xfce (glibc) live image"
        iso="$(fetch_txt "$VOID_BASE/" 2>/dev/null \
               | grep -oE 'void-live-x86_64-[0-9]{8}-xfce\.iso' | sort -u | tail -n1 || true)"
        if [[ -z "$iso" ]]; then
            warn "auto-detect failed; falling back to $VOID_FALLBACK"
            iso="$VOID_FALLBACK"
        fi
    fi
    out="$DEST/$iso"
    download "$VOID_BASE/$iso" "$out"
    if (( VERIFY )); then
        # format: hash  file
        sums="$(fetch_txt "$VOID_BASE/sha256sum.txt" || true)"
        want="$(awk -v f="$iso" '$2==f {print $1}' <<<"$sums")"
        verify sha256 "$out" "$want"
    fi
}

# ---- args ------------------------------------------------------------------
targets=()
while (( $# )); do
    case "$1" in
        -d) [[ $# -ge 2 ]] || die "-d needs a directory"; DEST="$2"; shift 2 ;;
        -n) VERIFY=0; shift ;;
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        freebsd|slackware|void) targets+=("$1"); shift ;;
        all) targets=(freebsd slackware void); shift ;;
        *) die "unknown argument: $1 (try -h)" ;;
    esac
done
(( ${#targets[@]} )) || targets=(freebsd slackware void)

mkdir -p "$DEST"
log "Saving to $(cd "$DEST" && pwd)"

for t in "${targets[@]}"; do
    "get_$t"
done

log "Done."
ls -lh "$DEST"
