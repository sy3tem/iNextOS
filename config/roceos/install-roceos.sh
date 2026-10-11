#!/bin/bash
#
# install-roceos.sh -- install the iStoreNext / RoceOS Web UI (backend + frontend)
#                      on a Debian-based arm64 (or amd64) system.
#
# Why this exists
# ---------------
# The iStoreNext Web UI is "roceos": a Go backend on 127.0.0.1:8080 plus a static
# SPA that nginx serves from /opt/roceos/www.  None of that is present in the
# public armbian-easepi build tree -- the build only carries branding glue
# (extensions/istorenext.sh + packages/bsp/istorenext/*).  The real payload is
# published on the vendor's OTA server and is what this script fetches:
#
#     http://update.roceos.com:14380/api/v1/updates/channels     (public, no auth)
#     http://update.roceos.com:14380/api/v1/updates/packages/<file>
#
# The file layout below is not guesswork: the `roceos` binary itself carries the
# shell script it uses to apply its own OTA update, and the mapping implemented
# here mirrors that script one-for-one (see the comments next to each copy).
#
# Usage
# -----
#   install-roceos.sh                       # install/upgrade on the running system
#   install-roceos.sh --root /path/to/sdcard   # install into an image (build time)
#   install-roceos.sh --list                # show channels offered by the server
#   install-roceos.sh --payload roceos-v2.9.5-arm64.tar.gz   # offline
#   install-roceos.sh --channel stable_arm --deps            # also apt-install extras
#
# Notes
#   * --root makes every path relative to that directory and skips all live
#     actions (no downloads into the target, no service start).  Downloads still
#     happen on the build host, which has network.
#   * Idempotent: an already-installed identical version is left alone unless
#     --force is given.  This keeps CI rebuilds cheap.
#
set -u

PROG="$(basename "$0")"

# --------------------------------------------------------------------------
# Defaults
# --------------------------------------------------------------------------
BASE_URL="${ROCEOS_BASE_URL:-http://update.roceos.com:14380}"
CHANNEL=""
ROOT="/"
PAYLOAD=""
WANT_LIST=0
WANT_DEPS=0
WANT_FORCE=0
WANT_ENABLE=1
PIN_VERSION=""
PIN_SHA256=""
GLUE_DIR=""
KEEP_TMP=0
ARCH_OVERRIDE=""
WANT_AI=1

usage() {
	cat <<'USAGE'
install-roceos.sh -- install the iStoreNext / RoceOS Web UI (backend + frontend).

  --channel <name>    channel to install (default: stable_arm on arm64,
                      stable on amd64)
  --base-url <url>    update server (default http://update.roceos.com:14380)
  --root <dir>        install into an image root instead of / (build time;
                      downloads still happen on the host)
  --payload <file>    use a local tarball instead of downloading
  --glue <dir>        glue/ directory to take nginx/unit/config files from
  --arch <a>          target architecture: aarch64 or x86_64 (default: $ARCH
                      if exported, else uname -m)
  --version <v>       expected version (informational)
  --sha256 <hash>     override the expected payload hash
  --list              list the channels the server offers, then exit
  --deps              best-effort install of extra Debian packages
  --force             reinstall even if the same version is already present
  --no-enable         do not enable the systemd units
  --skip-ai           install but do not enable roceos-ai (boards with no NPU,
                      e.g. RK3528; librkllmrt.so is the RK3588 runtime)
  --keep-tmp          keep the download/extract directory
  -h, --help          this text
USAGE
	exit "${1:-0}"
}

log() { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die() {
	printf '[%s] ERROR: %s\n' "$(date '+%H:%M:%S')" "$*" >&2
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
	--channel) CHANNEL="${2:-}"; shift 2 ;;
	--channel=*) CHANNEL="${1#*=}"; shift ;;
	--base-url) BASE_URL="${2:-}"; shift 2 ;;
	--base-url=*) BASE_URL="${1#*=}"; shift ;;
	--root) ROOT="${2:-}"; shift 2 ;;
	--root=*) ROOT="${1#*=}"; shift ;;
	--payload) PAYLOAD="${2:-}"; shift 2 ;;
	--payload=*) PAYLOAD="${1#*=}"; shift ;;
	--glue) GLUE_DIR="${2:-}"; shift 2 ;;
	--glue=*) GLUE_DIR="${1#*=}"; shift ;;
	--arch) ARCH_OVERRIDE="${2:-}"; shift 2 ;;
	--arch=*) ARCH_OVERRIDE="${1#*=}"; shift ;;
	--version) PIN_VERSION="${2:-}"; shift 2 ;;
	--version=*) PIN_VERSION="${1#*=}"; shift ;;
	--sha256) PIN_SHA256="${2:-}"; shift 2 ;;
	--sha256=*) PIN_SHA256="${1#*=}"; shift ;;
	--list) WANT_LIST=1; shift ;;
	--deps) WANT_DEPS=1; shift ;;
	--force) WANT_FORCE=1; shift ;;
	--no-enable) WANT_ENABLE=0; shift ;;
	--skip-ai) WANT_AI=0; shift ;;
	--keep-tmp) KEEP_TMP=1; shift ;;
	-h | --help) usage 0 ;;
	*) die "unknown argument: $1 (try --help)" ;;
	esac
done

# Every filesystem path goes through here, so --root works uniformly.
P() { printf '%s%s' "${ROOT%/}" "$1"; }

# --------------------------------------------------------------------------
# Target architecture -> channel
# --------------------------------------------------------------------------
# This must not be read from `uname -m`: when the image is built in CI the host
# is x86_64 while the image being populated is arm64.  Armbian exports ARCH
# (arm64/amd64) for the target, so prefer that, then an explicit --arch.
norm_arch() {
	case "$1" in
	aarch64 | arm64) echo aarch64 ;;
	x86_64 | amd64) echo x86_64 ;;
	"") echo "" ;;
	*) echo "$1" ;;
	esac
}

if [ -n "$ARCH_OVERRIDE" ]; then
	TARGET_ARCH="$(norm_arch "$ARCH_OVERRIDE")"
elif [ -n "${ARCH:-}" ]; then
	TARGET_ARCH="$(norm_arch "$ARCH")"
else
	TARGET_ARCH="$(norm_arch "$(uname -m)")"
fi
log "target architecture: ${TARGET_ARCH:-unknown} (host $(uname -m))"

detect_channel() {
	case "$TARGET_ARCH" in
	aarch64) echo stable_arm ;;
	x86_64) echo stable ;;
	*) die "unsupported target architecture: ${TARGET_ARCH:-unknown}" ;;
	esac
}
[ -n "$CHANNEL" ] || CHANNEL="$(detect_channel)"

INSTALL_DIR="/opt/roceos"          # == P(INSTALL_DIR) below
MANIFEST_URL="$BASE_URL/api/v1/updates/channels"

# --------------------------------------------------------------------------
# Manifest helpers
# --------------------------------------------------------------------------
fetch() { # $1=url $2=dest
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 20 \
			--max-time 1800 -C - "$1" -o "$2"
	else
		wget -q --tries=5 --timeout=20 --continue -O "$2" "$1"
	fi
}

need_python() {
	command -v python3 >/dev/null 2>&1 ||
		die "python3 is required to parse the update manifest"
}

# Prints the entry for a channel as four lines: filename, sha256, size, version.
manifest_lookup() { # $1=channel
	need_python
	local tmp rc
	tmp="$(mktemp)"
	if ! fetch "$MANIFEST_URL" "$tmp"; then
		rm -f "$tmp"
		return 1
	fi
	python3 - "$tmp" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
c = d.get(sys.argv[2])
if not c:
    sys.exit(f"channel '{sys.argv[2]}' is not offered by the server")
print(c.get('filename', ''))
print(c.get('sha256', ''))
print(c.get('size', 0))
print(c.get('version', ''))
PY
	rc=$?
	rm -f "$tmp"
	return $rc
}

# e_machine of an ELF header is a little-endian uint16 at offset 18.
elf_machine() { # $1=file -> aarch64 | x86_64 | machine-N | not-an-elf
	if [ "$(dd if="$1" bs=1 count=4 2>/dev/null)" != "$(printf '\177ELF')" ]; then
		echo "not-an-elf"
		return
	fi
	local m
	m="$(od -An -tu2 -j18 -N2 "$1" 2>/dev/null | tr -d ' ')"
	case "$m" in
	183) echo aarch64 ;;
	62) echo x86_64 ;;
	*) echo "machine-$m" ;;
	esac
}

if [ "$WANT_LIST" = 1 ]; then
	need_python
	tmp="$(mktemp)"
	fetch "$MANIFEST_URL" "$tmp" || die "cannot reach $MANIFEST_URL"
	python3 - "$tmp" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
for k, v in d.items():
    if not v:
        print(f"{k:12s} -")
    else:
        print(f"{k:12s} v{v.get('version','?'):10s} "
              f"{v.get('size',0)/1048576:7.1f} MiB  {v.get('filename','')}")
PY
	rm -f "$tmp"
	exit 0
fi

# --------------------------------------------------------------------------
# Resolve the payload
# --------------------------------------------------------------------------
FILE=""
SHA=""
SIZE=""
VER=""
OFFLINE=0

if [ -n "$PAYLOAD" ]; then
	[ -f "$PAYLOAD" ] || die "payload not found: $PAYLOAD"
	OFFLINE=1
	FILE="$PAYLOAD"
	VER="${PIN_VERSION:-offline}"
	log "using offline payload: $PAYLOAD"
else
	log "resolving channel '$CHANNEL' from $MANIFEST_URL"
	MANIFEST_ENTRY="$(manifest_lookup "$CHANNEL")" ||
		die "cannot resolve channel '$CHANNEL' from $MANIFEST_URL"
	FILE="$(printf '%s\n' "$MANIFEST_ENTRY" | sed -n 1p)"
	SHA="$(printf '%s\n' "$MANIFEST_ENTRY" | sed -n 2p)"
	SIZE="$(printf '%s\n' "$MANIFEST_ENTRY" | sed -n 3p)"
	VER="$(printf '%s\n' "$MANIFEST_ENTRY" | sed -n 4p)"
	[ -n "$FILE" ] || die "server returned no filename for channel '$CHANNEL'"
	if [ -n "$PIN_VERSION" ] && [ "$PIN_VERSION" != "$VER" ]; then
		log "server is at v$VER but --version $PIN_VERSION was requested; continuing with v$VER"
	fi
	[ -n "$PIN_SHA256" ] && SHA="$PIN_SHA256"
	log "channel '$CHANNEL' -> $FILE (v$VER, $((SIZE / 1048576)) MiB)"
	[ -n "$SHA" ] || warn "server did not publish a sha256 for this channel"
fi

# --------------------------------------------------------------------------
# Skip when the target already carries this exact version
# --------------------------------------------------------------------------
INST_VJ="$(P "$INSTALL_DIR/version.json")"
if [ "$WANT_FORCE" = 0 ] && [ -n "$VER" ] && [ "$VER" != "offline" ] && [ -f "$INST_VJ" ]; then
	CUR="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INST_VJ" | head -1)"
	if [ "$CUR" = "$VER" ] && [ -f "$(P "$INSTALL_DIR/roceos")" ]; then
		log "roceos v$CUR is already installed under ${ROOT%/}; nothing to do (use --force to reinstall)"
		exit 0
	fi
fi

# --------------------------------------------------------------------------
# Download + verify
# --------------------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/roceos.XXXXXX")"
cleanup() { [ "$KEEP_TMP" = 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT

TARBALL="$FILE"
if [ "$OFFLINE" = 0 ]; then
	TARBALL="$TMP/$FILE"
	log "downloading $BASE_URL/api/v1/updates/packages/$FILE"
	fetch "$BASE_URL/api/v1/updates/packages/$FILE" "$TARBALL" ||
		die "download failed (see $BASE_URL/api/v1/updates/channels for available files)"
fi

GOT_SIZE="$(wc -c <"$TARBALL" | tr -d ' ')"
log "downloaded $((GOT_SIZE / 1048576)) MiB"
if [ -n "$SIZE" ] && [ "$SIZE" != "0" ] && [ "$GOT_SIZE" != "$SIZE" ]; then
	die "size mismatch: expected $SIZE bytes, got $GOT_SIZE"
fi

if [ -n "$SHA" ]; then
	log "verifying sha256"
	ACT="$(sha256sum "$TARBALL" | awk '{print $1}')"
	[ "$ACT" = "$SHA" ] || die "sha256 mismatch!
  expected $SHA
  actual   $ACT"
	log "sha256 OK"
else
	ACT=""
fi

# --------------------------------------------------------------------------
# Extract
# --------------------------------------------------------------------------
log "extracting"
mkdir -p "$TMP/x"
if ! tar -xzf "$TARBALL" -C "$TMP/x"; then
	die "extraction failed (not a gzip tarball?)"
fi

# The tarball has a single top-level directory, e.g. roceos-v2.9.5-arm64/.
EXTRACT_DIR="$(find "$TMP/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [ -z "$EXTRACT_DIR" ] || [ ! -f "$EXTRACT_DIR/bin/roceos" ]; then
	die "unexpected payload layout: missing bin/roceos"
fi

# Refuse to install a foreign-architecture backend: the whole point of the
# channel split (stable vs stable_arm) is that these are prebuilt per arch.
ELF_ARCH="$(elf_machine "$EXTRACT_DIR/bin/roceos")"
case "$TARGET_ARCH" in
aarch64 | x86_64) WANT_ARCH="$TARGET_ARCH" ;;
*) WANT_ARCH="" ;;
esac
if [ -n "$WANT_ARCH" ] && [ "$ELF_ARCH" != "$WANT_ARCH" ]; then
	die "payload binaries are $ELF_ARCH but the target is $TARGET_ARCH; wrong channel?"
fi
log "payload architecture: $ELF_ARCH"

# An offline payload still states its version; pick it up so that both the
# idempotency check and the report stay accurate.
if [ -f "$EXTRACT_DIR/version.json" ]; then
	PV="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$EXTRACT_DIR/version.json" | head -1)"
	[ -n "$PV" ] && VER="$PV"
fi

# Offline payloads only reveal their version here, so repeat the short-circuit:
# skipping the copy keeps the image rebuild cheap.
if [ "$WANT_FORCE" = 0 ] && [ -n "$VER" ] && [ -f "$INST_VJ" ] &&
	[ -f "$(P "$INSTALL_DIR/roceos")" ]; then
	CUR="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$INST_VJ" | head -1)"
	if [ "$CUR" = "$VER" ]; then
		log "roceos v$CUR is already installed under ${ROOT%/}; nothing to do (use --force to reinstall)"
		exit 0
	fi
fi

# --------------------------------------------------------------------------
# Lay out the payload
# (mirrors the OTA script embedded in the roceos binary)
# --------------------------------------------------------------------------
log "installing into ${ROOT%/}${INSTALL_DIR}"
mkdir -p \
	"$(P "$INSTALL_DIR")" \
	"$(P "$INSTALL_DIR/www")" \
	"$(P "$INSTALL_DIR/data")" \
	"$(P /opt/roceos-ai)" \
	"$(P /opt/roceos-vision)" \
	"$(P /etc/systemd/system)" \
	"$(P /etc/nginx/sites-available)" \
	"$(P /etc/nginx/sites-enabled)" \
	"$(P /etc/nginx/ssl)" \
	"$(P /storage)"

install -m 755 "$EXTRACT_DIR/bin/roceos" "$(P "$INSTALL_DIR/roceos")"
install -m 755 "$EXTRACT_DIR/bin/roceos-guard" "$(P "$INSTALL_DIR/roceos-guard")"

# roceos-apigw is deliberately x86_64 in *both* channels: it does not run here,
# it is uploaded to an x86_64 relay host by the "one-click deploy" flow.
# Install it, but never try to execute it.
install -m 755 "$EXTRACT_DIR/bin/roceos-apigw" "$(P "$INSTALL_DIR/roceos-apigw")"

# The NVR inference service.  /opt/roceos-vision is created now so systemd never
# fails with status=200/CHDIR for a directory that does not exist yet.
install -m 755 "$EXTRACT_DIR/bin/roceos-vision" "$(P "$INSTALL_DIR/roceos-vision")"

# Frontend.  Vendor ARM images use /opt/roceos/web; x86 and the public glue use
# /opt/roceos/www.  Our nginx site points at /opt/roceos/www, so keep www unless
# a pre-existing web/ says this box was provisioned by the vendor OTA script.
WEB_DST="$INSTALL_DIR/www"
[ -d "$(P "$INSTALL_DIR/web")" ] && WEB_DST="$INSTALL_DIR/web"
log "frontend -> $WEB_DST"
cp -rf "$EXTRACT_DIR/www/." "$(P "$WEB_DST")/"

[ -f "$EXTRACT_DIR/version.json" ] &&
	install -m 644 "$EXTRACT_DIR/version.json" "$(P "$INSTALL_DIR/version.json")"
[ -f "$EXTRACT_DIR/manifest.json" ] &&
	install -m 644 "$EXTRACT_DIR/manifest.json" "$(P "$INSTALL_DIR/manifest.json")"
[ -f "$EXTRACT_DIR/required-packages.json" ] &&
	install -m 644 "$EXTRACT_DIR/required-packages.json" "$(P "$INSTALL_DIR/required-packages.json")"

# arm64-only extras.
if [ "$ELF_ARCH" = aarch64 ]; then
	[ -f "$EXTRACT_DIR/assets/roceos-ai-server.py" ] &&
		install -m 755 "$EXTRACT_DIR/assets/roceos-ai-server.py" "$(P /opt/roceos-ai/server.py)"
	[ -f "$EXTRACT_DIR/assets/librkllmrt.so" ] &&
		install -m 755 "$EXTRACT_DIR/assets/librkllmrt.so" "$(P /opt/roceos-ai/librkllmrt.so)"
	[ -f "$EXTRACT_DIR/assets/roceos-search.py" ] &&
		install -m 755 "$EXTRACT_DIR/assets/roceos-search.py" "$(P /usr/local/bin/roceos-search)"
fi

# Optional side components shipped by some builds.
[ -f "$EXTRACT_DIR/bin/sing-box" ] &&
	install -m 755 "$EXTRACT_DIR/bin/sing-box" "$(P /usr/local/bin/sing-box)"

# systemd units that the payload itself ships.
for u in roceos-guard roceos-vision roceos-ai; do
	src="$EXTRACT_DIR/systemd/$u.service"
	[ -f "$src" ] || continue
	install -m 644 "$src" "$(P "/etc/systemd/system/$u.service")"
done

# --------------------------------------------------------------------------
# Glue: nginx site, TLS material, main unit, config.yaml
# --------------------------------------------------------------------------
# Prefer a vendored glue/ directory so builds and repairs are reproducible;
# fall back to fetching each file from the public deploy repo.
#   * next to this script (build host: config/roceos/glue)
#   * /usr/local/share/roceos/glue (how the image ships it)
if [ -z "$GLUE_DIR" ]; then
	for cand in "$(dirname "$0")/glue" /usr/local/share/roceos/glue; do
		if [ -d "$cand" ]; then
			GLUE_DIR="$(cd "$cand" && pwd)"
			break
		fi
	done
fi

fetch_glue() { # $1=relative path, $2=dest, $3=mode
	local rel="$1" dst="$2"
	if [ -n "$GLUE_DIR" ] && [ -f "$GLUE_DIR/$rel" ]; then
		install -D -m "${3:-644}" "$GLUE_DIR/$rel" "$dst"
		return 0
	fi
	local url="https://raw.githubusercontent.com/jjm2473/istorenext-deploy-files/main/$rel"
	log "  glue fallback: fetching $rel from the deploy repo"
	fetch "$url" "$dst" || return 1
	chmod "${3:-644}" "$dst"
}

log "installing glue (from ${GLUE_DIR:-the deploy repo})"
fetch_glue rootfs/etc/systemd/system/roceos.service "$(P /etc/systemd/system/roceos.service)" 644 ||
	warn "could not install roceos.service"
fetch_glue rootfs/etc/nginx/sites-available/roceos.conf "$(P /etc/nginx/sites-available/roceos.conf)" 644 ||
	warn "could not install roceos.conf"
fetch_glue rootfs/etc/nginx/ssl/roceos.crt "$(P /etc/nginx/ssl/roceos.crt)" 644 ||
	warn "could not install roceos.crt"
fetch_glue rootfs/etc/nginx/ssl/roceos.key "$(P /etc/nginx/ssl/roceos.key)" 600 ||
	warn "could not install roceos.key"
# config.yaml is only seeded once: roceos rewrites it at runtime.
if [ ! -f "$(P "$INSTALL_DIR/config.yaml")" ]; then
	fetch_glue rootfs/opt/roceos/config.yaml "$(P "$INSTALL_DIR/config.yaml")" 644 ||
		warn "could not install config.yaml"
fi

# nginx: the RoceOS site claims "listen 80 default_server" (and 443), so the
# distro's own default site has to go or nginx refuses to start with
# "duplicate default server".
#
# It must be moved OUT of sites-enabled entirely -- nginx includes
# sites-enabled/* regardless of extension, so merely renaming it to
# default.disabled-by-roceos inside that directory keeps it loaded and the
# collision persists.  Move it next to its original under sites-available
# (which is not included) so nothing is lost.
if [ -e "$(P /etc/nginx/sites-enabled/default)" ]; then
	mv -f "$(P /etc/nginx/sites-enabled/default)" \
		"$(P /etc/nginx/sites-available/default.disabled-by-roceos)" 2>/dev/null ||
		rm -f "$(P /etc/nginx/sites-enabled/default)"
	log "disabled the distro nginx default site"
fi
# Clean up the broken shape produced by earlier revisions of this script.
if [ -e "$(P /etc/nginx/sites-enabled/default.disabled-by-roceos)" ]; then
	mv -f "$(P /etc/nginx/sites-enabled/default.disabled-by-roceos)" \
		"$(P /etc/nginx/sites-available/default.disabled-by-roceos)" 2>/dev/null ||
		rm -f "$(P /etc/nginx/sites-enabled/default.disabled-by-roceos)"
	log "cleaned up a stale disabled default site"
fi
ln -sf /etc/nginx/sites-available/roceos.conf "$(P /etc/nginx/sites-enabled/roceos.conf)"

# /storage is where roceos keeps user data; nginx (www-data) must be able to
# traverse it.  This mirrors the vendor OTA script's permission fix.
chmod 755 "$(P /storage)"

# --------------------------------------------------------------------------
# Enable units (deterministic symlinks -- no systemctl needed, so this also
# works when installing into a mounted image)
# --------------------------------------------------------------------------
if [ "$WANT_ENABLE" = 1 ]; then
	WANTS="$(P /etc/systemd/system/multi-user.target.wants)"
	mkdir -p "$WANTS"
	for u in roceos roceos-guard roceos-vision roceos-ai; do
		[ -f "$(P "/etc/systemd/system/$u.service")" ] || continue
		if [ "$u" = roceos-ai ]; then
			# librkllmrt.so is the RK3588 RKNPU2 runtime; boards without an NPU
			# (RK3528 among them) would just crash-loop it, so leave it installed
			# but disabled unless --skip-ai was not given AND the arch matches.
			[ "$ELF_ARCH" = aarch64 ] || continue
			[ "$WANT_AI" = 1 ] || {
				log "roceos-ai left disabled (--skip-ai)"
				continue
			}
		fi
		ln -sf "/etc/systemd/system/$u.service" "$WANTS/$u.service"
	done
	log "enabled: roceos roceos-guard roceos-vision"
fi

# --------------------------------------------------------------------------
# Live install: make nginx actually pick up the new site
# --------------------------------------------------------------------------
# Without this the daemon keeps serving whatever it was started with (in
# practice: the distro "Welcome to nginx!" page) until someone reloads it by
# hand.  Fail loudly instead of leaving a half-working box behind.
if [ "$ROOT" = "/" ] && command -v nginx >/dev/null 2>&1; then
	if nginx -t >/dev/null 2>&1; then
		if command -v systemctl >/dev/null 2>&1; then
			systemctl reload nginx 2>/dev/null ||
				systemctl restart nginx 2>/dev/null ||
				warn "could not reload nginx; run 'systemctl reload nginx' by hand"
		fi
		log "nginx reloaded with the roceos site"
	else
		warn "nginx configuration test FAILED -- nothing was reloaded."
		warn "fix the error below, then run 'systemctl reload nginx':"
		nginx -t 2>&1 | sed 's/^/    /' >&2 || true
	fi
fi

# --------------------------------------------------------------------------
# Optional: Debian-installable runtime dependencies
# --------------------------------------------------------------------------
if [ "$WANT_DEPS" = 1 ] && [ "$ROOT" = "/" ]; then
	# Only packages that exist in Debian.  Entries marked "repo: roceos" or
	# "repo: jellyfin" in required-packages.json come from repositories that are
	# not reachable (repo.roceos.com currently serves an ICP block page), so they
	# are skipped rather than failing the whole install.
	DEPS="python3-flask hdparm traceroute mtr-tiny whois bind9-dnsutils
	      avahi-utils arp-scan wireless-regdb v4l-utils usbutils pciutils
	      rfkill iw ethtool pptp-linux xl2tpd openvpn strongswan-charon
	      strongswan-starter imagemagick dkms gcc"
	log "installing optional runtime dependencies (best effort)"
	# shellcheck disable=SC2086
	apt-get update -qq || true
	# shellcheck disable=SC2086
	apt-get install -y --no-install-recommends $DEPS || warn "some dependencies could not be installed"
	warn "skipped (unreachable repos): accel-ppp roceos-xunlei roceos-libndpi jellyfin-ffmpeg7 libreoffice-*-nogui"
fi

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------
{
	echo "roceos_version=${VER:-unknown}"
	echo "channel=$CHANNEL"
	echo "filename=$(basename "$FILE")"
	echo "sha256=${SHA:-unverified}"
	echo "sha256_actual=${ACT:-}"
	echo "installed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "arch=$ELF_ARCH"
} >"$(P "$INSTALL_DIR/.installed-by-iNextOS")"

log "done: roceos v${VER:-?} installed under ${ROOT%/}"
if [ "$ROOT" = "/" ]; then
	log "start it with: systemctl start roceos roceos-guard roceos-vision"
	log "then open http://<device-ip>/ (nginx 80 -> /opt/roceos/www, /api/ -> 127.0.0.1:8080)"
else
	log "image install: units are enabled via symlinks; nginx will serve the UI on first boot"
fi
exit 0
