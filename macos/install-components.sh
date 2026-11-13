#!/bin/bash
# What "AI Sound Design Installer.app" runs (it sits in the app's Resources): installs or
# updates the parts chosen in its window. Part of github.com/ai-sound-design/installer.
# Also usable on its own:
#
#   AISD_COMPONENTS="backend webui plugin database" bash install-components.sh
#
#   backend    ai-services (github.com/ai-sound-design/ai-services, main), set up natively
#              by its install_mac.sh: Homebrew, the models, the background services
#   webui      github.com/ai-sound-design/ai-sound-webui (main), beside the services: set up
#              (and updated) by the services' installer, so it brings "backend" along
#   plugin     the newest release of github.com/ai-sound-design/ai-protools-aax (its .pkg)
#   database   the BBC Sound Effects index, through the setup service; "audio" with it also
#              downloads all of the archive's audio and builds the audio index
#
# AISD_DATA_DIR, AISD_SESSIONS_DIR, AISD_BBC_ARCHIVE, AISD_OWN_SOUNDS: the folders, passed
# on to install_mac.sh. AISD_SOURCE_DIR: a copy of ai-services to install instead of
# fetching main (a checkout under development).
#
# For the app it prints lines it reads: @@step <part> <running|done|failed|skipped>,
# @@status <text>, @@progress <0-100>, @@error <text>. Everything else is the log.
# Run again, it updates what is there; every step only does what is missing, and the
# sound database carries on where it stopped.
#
# The services' commit goes into ai-services/.mac/installed-from, which the app compares
# with GitHub to offer an update.

set -u
SERVICES_REPO="${AISD_SERVICES_REPO:-ai-sound-design/ai-services}"
SERVICES_REF="${AISD_SERVICES_REF:-main}"
PLUGIN_REPO="${AISD_PLUGIN_REPO:-ai-sound-design/ai-protools-aax}"
HOME_DIR="${AISD_HOME:-$HOME/AI Sound Design}"
INSTALLED="$HOME_DIR/ai-services"
PLUGIN="/Library/Application Support/Avid/Audio/Plug-Ins/AI Sound Design.aaxplugin"
PYTHON=/opt/homebrew/opt/python@3.12/bin/python3.12
TMP=""

at()   { printf '@@%s\n' "$*"; }
step() { printf '\n== %s\n' "$1"; }
ok()   { printf '   %s\n' "$1"; }
fail() {   # <message> [part]
    at "error $1"
    [ -n "${2:-}" ] && at "step $2 failed"
    [ -n "$TMP" ] && rm -rf "$TMP"
    exit 1
}
want() { case " ${AISD_COMPONENTS:-backend} " in *" $1 "*) return 0;; esac; return 1; }
tmpdir() { [ -n "$TMP" ] || TMP="$(mktemp -d -t ai-sound-design)"; }

[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail "This installer is for Macs with Apple Silicon (M1 or later)."
want audio && ! want database && AISD_COMPONENTS="${AISD_COMPONENTS:-} database"
# The web UI is set up and updated by the services' installer; the database needs them there
if ! want backend && { want webui || { want database && [ ! -f "$INSTALLED/mac/backend.py" ]; }; }; then
    AISD_COMPONENTS="${AISD_COMPONENTS:-} backend"
fi

# ── Backend services (and the web UI) ───────────────────────────────────────

if want backend; then
    at "step backend running"
    want webui && at "step webui running"
    if [ -n "${AISD_SOURCE_DIR:-}" ]; then
        SRC="$AISD_SOURCE_DIR"
        [ -f "$SRC/install_mac.sh" ] || fail "$SRC has no install_mac.sh." backend
        step "Backend services: from $SRC"
        COMMIT="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || true)"
        MODIFIED=0
        [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null || echo x)" ] && MODIFIED=1
        ORIGIN="$SRC"
    else
        step "Backend services: fetching $SERVICES_REPO ($SERVICES_REF) from GitHub"
        at "status Downloading the backend services from GitHub"
        tmpdir
        # The newest commit, then exactly that one: what is installed is known by its commit
        COMMIT="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/$SERVICES_REPO/commits/$SERVICES_REF" \
            | grep -o '"sha" *: *"[0-9a-f]\{40\}"' | head -1 | grep -o '[0-9a-f]\{40\}')" \
            || fail "GitHub could not be reached. Is this Mac online?" backend
        MODIFIED=0
        ORIGIN="$SERVICES_REPO"
        curl -fsSL -o "$TMP/ai-services.zip" "https://codeload.github.com/$SERVICES_REPO/zip/$COMMIT" \
            || fail "GitHub could not be reached. Is this Mac online?" backend
        ditto -x -k "$TMP/ai-services.zip" "$TMP/src" || fail "The download is damaged; try again." backend
        SRC="$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [ -f "$SRC/install_mac.sh" ] || fail "This version of ai-services ($SERVICES_REF) has no Mac installer yet." backend
    fi
    FLAGS=(--no-prompt)
    if want webui; then
        FLAGS+=(--webui on)
    elif [ ! -d "$INSTALLED/.mac/src/ai-sound-webui/dist" ] || grep -q -E '^MAC_WEBUI=0' "$INSTALLED/.env" 2>/dev/null; then
        FLAGS+=(--webui off)    # not there and not wanted; one that is there stays (and is updated)
    fi
    [ -n "${AISD_DATA_DIR:-}" ] && [ ! -f "$INSTALLED/.env" ] && FLAGS+=(--data-dir "$AISD_DATA_DIR")
    [ -n "${AISD_SESSIONS_DIR:-}" ] && FLAGS+=(--sessions "$AISD_SESSIONS_DIR")
    [ -n "${AISD_BBC_ARCHIVE:-}" ] && FLAGS+=(--bbc-archive "$AISD_BBC_ARCHIVE")
    [ -n "${AISD_OWN_SOUNDS:-}" ] && FLAGS+=(--own-sounds "$AISD_OWN_SOUNDS")
    # Always into ~/AI Sound Design/ai-services, where background services may run
    AISD_COPY=1 AISD_HOME="$HOME_DIR" bash "$SRC/install_mac.sh" "${FLAGS[@]}" \
        || fail "The backend services could not be installed; the details say where it stopped." backend
    mkdir -p "$INSTALLED/.mac"
    printf 'origin=%s\nref=%s\ncommit=%s\nmodified=%s\ninstalled=%s\n' "$ORIGIN" "$SERVICES_REF" "${COMMIT:-}" \
        "$MODIFIED" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALLED/.mac/installed-from"
    at "step backend done"
    want webui && at "step webui done"
fi

# ── Pro Tools plugin ────────────────────────────────────────────────────────

if want plugin; then
    at "step plugin running"
    step "Pro Tools plugin: the newest release of $PLUGIN_REPO"
    RELEASE="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$PLUGIN_REPO/releases/latest")" \
        || fail "GitHub could not be reached. Is this Mac online?" plugin
    TAG="$(printf '%s' "$RELEASE" | grep -o '"tag_name" *: *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    URL="$(printf '%s' "$RELEASE" | grep -o '"browser_download_url" *: *"[^"]*"' | sed 's/.*"\(https[^"]*\)"$/\1/' \
        | grep -i 'mac.*\.pkg$' | head -1)"
    [ -n "$URL" ] || fail "The plugin release $TAG has no macOS installer." plugin
    HAVE="$(defaults read "$PLUGIN/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
    if [ -n "$HAVE" ] && { [ "v$HAVE" = "$TAG" ] || [ "$HAVE" = "$TAG" ]; } && [ "${AISD_FORCE_PLUGIN:-0}" != 1 ]; then
        ok "version $HAVE is installed, the newest"
    else
        [ -n "$HAVE" ] && ok "installed: $HAVE, newest: $TAG"
        at "status Downloading the plugin $TAG"
        tmpdir
        curl -fL --progress-bar -o "$TMP/plugin.pkg" "$URL" || fail "The plugin download failed; try again." plugin
        echo
        at "status Installing the plugin (macOS asks for this Mac's password)"
        at "progress -"
        osascript - "$TMP/plugin.pkg" <<'APPLESCRIPT' >/dev/null || fail "The plugin was not installed (no password given?)." plugin
on run argv
    do shell script "/usr/sbin/installer -pkg " & quoted form of (item 1 of argv) & " -target /" ¬
        with prompt "AI Sound Design installs its Pro Tools plugin." with administrator privileges
end run
APPLESCRIPT
        HAVE="$(defaults read "$PLUGIN/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)"
        [ -n "$HAVE" ] || fail "The plugin's installer ran, but the plugin is not in Pro Tools' plug-in folder." plugin
        ok "installed: version $HAVE"
        pgrep -x "Pro Tools" >/dev/null && ok "Pro Tools is open: quit and reopen it to load the new plugin."
    fi
    at "step plugin done"
fi

[ -n "$TMP" ] && rm -rf "$TMP" && TMP=""

# ── Sound database ──────────────────────────────────────────────────────────

if want database; then
    at "step database running"
    step "Sound database"
    [ -x "$PYTHON" ] && [ -f "$INSTALLED/mac/backend.py" ] || fail "The backend services are not installed; choose them as well." database
    ARGS=(database)
    want audio && ARGS+=(--audio)
    AISD_GUI=1 "$PYTHON" "$INSTALLED/mac/backend.py" "${ARGS[@]}" \
        || fail "The sound database could not be loaded completely; Try Again carries on where it stopped." database
    at "step database done"
fi
exit 0
