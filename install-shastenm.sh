#!/usr/bin/env bash
# =============================================================================
# install-shastenm.sh  (Void Linux / Slackware 15 / FreeBSD 14)
# Installs shastenm's dotfiles-bsd environment on all three OSes.
# spectrwm (+ dzen2/dmenu-solarized/xtitle and their sxhkd/nitrogen/picom
# support stack) is Void- and FreeBSD-only. Slackware deliberately does NOT
# get spectrwm — it gets dotfiles-bsd's CLI environment (bash/tmux/nvim/zk/
# starship) layered on top of its own stock XFCE session instead.
#
# IMPORTANT: This script should live at the ROOT of the dotfiles-bsd repo
# (next to .bashrc, .config/, .tmux/, etc) but will also self-clone
# dotfiles-bsd if run standalone (see resolve_dotfiles_src).
#
# OS handling:
#   - Void Linux : xbps-install, deploys dotfiles via `stow --adopt`,
#                   builds spectrwm from source, full WM stack
#   - Slackware 15: slackpkg (mirror + GPG bootstrapped from scratch, since
#                   a fresh Slackware install has NEITHER configured) for
#                   whatever's in the official repos; SlackBuilds.org (via a
#                   real sbo_install() helper, see below) for a few desktop
#                   apps not in the repos (gimp/l3afpad/pavucontrol/
#                   zathura/fastfetch). No stow (not packaged by default) —
#                   dotfiles are symlinked directly. NO spectrwm/dzen2/
#                   dmenu/xtitle build — Slackware stays on its stock XFCE.
#   - FreeBSD 14 : pkg (bootstrapped from scratch), BSD make for spectrwm's
#                   native top-level Makefile, gmake for GNU-only tools,
#                   dotfiles symlinked directly (matches Slackware approach),
#                   builds spectrwm from source, full WM stack
#
# Based on: smothermonethan2002 / shastenm custom forks
#           gitlab.com/smothermonethan2002/dotfiles-bsd
#           gitlab.com/smothermonethan2002/spectrwm
#           gitlab.com/smothermonethan2002/dotfile-installation
#
# Usage: bash install-shastenm.sh
# =============================================================================

set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; RST='\033[0m'
info()  { echo -e "${BLU}[INFO]${RST}  $*"; }
ok()    { echo -e "${GRN}[OK]${RST}    $*"; }
warn()  { echo -e "${YLW}[WARN]${RST}  $*"; }
die()   { echo -e "${RED}[ERR]${RST}   $*" >&2; exit 1; }
step()  { echo -e "\n${CYN}══════ $* ══════${RST}"; }

# ─── Paths & Variables ───────────────────────────────────────────────────────
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DIR

WORK_DIR="$HOME/.local/share/shastenm-build"
CONFIG_DIR="$HOME/.config"
SPECTRWM_CONF_DEST="$HOME/.config/spectrwm"

# OS_ID: void | slackware | freebsd — set by detect_os()
OS_ID=""
# MAKE_GNU: which make binary to use for GNU-only Makefiles (dzen2/dmenu/xtitle)
MAKE_GNU="make"

# Repos
REPO_BIN="https://gitlab.com/cuauhtlios/bin.git"
REPO_SPECTRWM="https://github.com/conformal/spectrwm.git"
REPO_DMENU="https://gitlab.com/shastenm/dmenu-solarized.git"
REPO_XTITLE="https://github.com/baskerville/xtitle.git"
REPO_WALLPAPER="https://gitlab.com/smothermonethan2002/wallpaper.git"
REPO_SPECTRWM_CFG="https://gitlab.com/smothermonethan2002/spectrwm.git"
REPO_DOTFILES_INSTALLATION="https://gitlab.com/smothermonethan2002/dotfile-installation.git"
REPO_DOTFILES_BSD="https://gitlab.com/smothermonethan2002/dotfiles-bsd.git"

# CONFIRMED URL — taken directly from nvim-configs' own install.sh
# ("git clone https://gitlab.com/shastenm/nvim-configs.git") inside the
# real dotfiles-bsd checkout. No more guessing between namespaces.
REPO_NVIM_CONFIGS="https://gitlab.com/shastenm/nvim-configs.git"

# NOTE: libbsd/libmd source-build helpers exist further down but are
# currently unused — Slackware no longer builds spectrwm (see
# install_slackware), and Void/FreeBSD get libbsd via their package
# managers. Left in place in case Slackware+spectrwm support returns.
LIBBSD_TARBALL_URL="https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz"
LIBMD_TARBALL_URL="https://archive.hadrons.org/software/libmd/libmd-1.1.0.tar.xz"

DOTFILES_SRC=""
NVIM_CONFIGS_DEPLOYED=""

# ─── Helpers ─────────────────────────────────────────────────────────────────
check_cmd() { command -v "$1" >/dev/null 2>&1; }

clone_repo() {
    local url="$1" dest="$2"
    if [ -d "$dest" ]; then
        info "Already exists, skipping: $dest"
    else
        info "Cloning $url → $dest"
        git clone "$url" "$dest" || die "Failed to clone $url"
    fi
}

remove_conflicts() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        info "Removing conflict: $path"
        if ! rm -rf "$path" 2>/dev/null; then
            warn "Plain rm -rf failed on $path — retrying after chmod"
            chmod -R u+rwX "$path" 2>/dev/null || true
            rm -rf "$path" || warn "Still couldn't remove $path — check for mounts/immutable files and remove manually"
        fi
    fi
}

# ─── Resilient per-package installs ─────────────────────────────────────────
# ROOT CAUSE of the "pkg-config: not found" / "gcc: not found" failures:
# xbps-install (and pkg install) treat a package LIST as one atomic
# transaction. If even ONE name in that list doesn't exist in the repo
# pool (e.g. 'waybar' on some Void mirrors), the ENTIRE transaction is
# refused and NOTHING in the list gets installed — not just the bad name.
# That's why gcc/pkg-config/X11-devel never landed even though the log
# only ever complained about 'waybar'. The old `2>&1 | grep -v "already
# installed" || true` pattern then silently swallowed that failure.
#
# Fix: install every package ONE AT A TIME. A bad name only costs that
# one package, not the whole batch — and required build packages are
# checked afterward so we die loudly (with the real list of what's
# missing) instead of failing confusingly three steps later in a
# compile log.
void_pkg_installed()     { xbps-query "$1" >/dev/null 2>&1; }
void_pkg_install()       { sudo xbps-install -y "$1" >/dev/null 2>&1; }

freebsd_pkg_installed()  { pkg info -e "$1" >/dev/null 2>&1; }
freebsd_pkg_install()    { sudo pkg install -y "$1" >/dev/null 2>&1; }

slackware_pkg_installed() { ls /var/log/packages/"$1"-* >/dev/null 2>&1; }
slackware_pkg_install()   { sudo slackpkg install "$1" >/dev/null 2>&1; }

# install_pkgs_resilient <installed_fn> <install_fn> <required|optional> pkg...
install_pkgs_resilient() {
    local installed_fn="$1" install_fn="$2" mode="$3"; shift 3
    local failed=()
    for p in "$@"; do
        "$installed_fn" "$p" && continue
        "$install_fn" "$p" || failed+=("$p")
    done
    if [ "${#failed[@]}" -gt 0 ]; then
        if [ "$mode" = "required" ]; then
            die "Required packages failed to install (spectrwm/dzen2 builds WILL fail without these): ${failed[*]}"
        else
            warn "Optional packages not available/failed (not fatal, continuing): ${failed[*]}"
        fi
    fi
}

# ─── Detect OS ───────────────────────────────────────────────────────────────
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "${ID:-}" in
            void) OS_ID="void" ;;
            slackware) OS_ID="slackware" ;;
            *) OS_ID="" ;;
        esac
    fi

    if [ -z "$OS_ID" ] && [ "$(uname -s)" = "FreeBSD" ]; then
        OS_ID="freebsd"
    fi

    if [ -z "$OS_ID" ]; then
        warn "Couldn't confidently detect OS — defaulting to Void Linux"
        OS_ID="void"
    fi

    info "Target OS: $OS_ID"

    # GNU-Makefile build tool (dzen2 / dmenu-solarized / xtitle all use
    # plain GNU Makefiles regardless of OS). On FreeBSD, base 'make' is
    # BSD make and chokes on these, so prefer gmake there.
    if [ "$OS_ID" = "freebsd" ] && check_cmd gmake; then
        MAKE_GNU="gmake"
    else
        MAKE_GNU="make"
    fi
}

# ─── Locate (or fetch) the dotfiles-bsd source tree ──────────────────────────
resolve_dotfiles_src() {
    if [ -f "$DIR/.bashrc" ] && [ -d "$DIR/.config" ]; then
        DOTFILES_SRC="$DIR"
        info "Running from inside a dotfiles-bsd checkout: $DOTFILES_SRC"
    else
        warn "$DIR doesn't look like a dotfiles-bsd checkout (no .bashrc/.config here)"
        mkdir -p "$WORK_DIR"
        clone_repo "$REPO_DOTFILES_BSD" "$WORK_DIR/dotfiles-bsd"
        DOTFILES_SRC="$WORK_DIR/dotfiles-bsd"
        info "Using freshly cloned dotfiles-bsd: $DOTFILES_SRC"
    fi
    export DOTFILES_SRC
}

# =============================================================================
# ─── Setup Functions (OS-agnostic) ───────────────────────────────────────────
# =============================================================================

setup_fonts() {
    step "Installing fonts"
    mkdir -p "$HOME/.local/share/fonts/"

    local candidates=(
        "$WORK_DIR/dotfiles-installation/spectrwm/fonts"
        "$WORK_DIR/dotfiles-installation/fonts"
        "$WORK_DIR/dotfiles-installation/assets/fonts"
    )
    local fonts_src=""
    for c in "${candidates[@]}"; do
        if [ -d "$c" ] && find "$c" -iname "*.ttf" -o -iname "*.otf" 2>/dev/null | grep -q .; then
            fonts_src="$c"
            break
        fi
    done

    if [ -n "$fonts_src" ]; then
        cp -r "$fonts_src"/* "$HOME/.local/share/fonts/" 2>/dev/null || true
        fc-cache -fv
        ok "Fonts installed from $fonts_src"
        return
    fi

    warn "No fonts found in dotfiles-installation — falling back to downloading SauceCodePro Nerd Font directly"
    local tmp_zip="$WORK_DIR/SauceCodePro.zip"
    mkdir -p "$WORK_DIR"
    if curl -fL "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/SauceCodePro.zip" -o "$tmp_zip"; then
        mkdir -p "$HOME/.local/share/fonts/SauceCodePro"
        if unzip -oq "$tmp_zip" -d "$HOME/.local/share/fonts/SauceCodePro"; then
            fc-cache -fv
            ok "SauceCodePro Nerd Font installed directly from GitHub releases"
        else
            warn "Failed to unzip SauceCodePro.zip — install fonts manually"
        fi
    else
        warn "Failed to download SauceCodePro Nerd Font — install manually from nerdfonts.com"
    fi
}

setup_bin() {
    step "Setting up ~/.local/bin"
    mkdir -p "$HOME/.local/bin"
    if [ -d "$WORK_DIR/bin" ]; then
        cp -r "$WORK_DIR/bin/"* "$HOME/.local/bin/"
        ok "bin installed from $REPO_BIN"
    else
        warn "No bin/ directory cloned — skipping"
    fi
    # CONFIRMED from the real dotfiles-bsd checkout: it DOES ship its own
    # .local/bin (osc52copy, zed, rtcqs/rtcqs_gui, distrobox-*, fsg* helper
    # scripts) and .bash/void.sh (xbps aliases: ins/info/rmv/plist/search/
    # update) — these get deployed separately by setup_dotfiles(), not here.
    # (Earlier version of this comment claimed the opposite; that was wrong.)
}

# ─── Deploy dotfiles-bsd: stow on Void, direct symlinks on Slackware/FreeBSD ─
setup_dotfiles() {
    [ -f "$DOTFILES_SRC/.bashrc" ] || die "dotfiles-bsd source invalid at $DOTFILES_SRC — aborting."

    if [ "$OS_ID" = "void" ]; then
        _setup_dotfiles_stow
    else
        _setup_dotfiles_symlink
    fi

    [ -f "$HOME/.bash/void.sh" ] || warn "No .bash/void.sh in this dotfiles-bsd snapshot — Void xbps aliases (ins/info/rmv/plist/search/update) won't be available regardless of OS until it's added back upstream"
}

_setup_dotfiles_stow() {
    step "Deploying dotfiles-bsd with stow (from $DOTFILES_SRC)"

    # stow --adopt merges directories safely (only touches conflicting
    # files, never wipes a whole top-level dir like .config/.local), which
    # matters since dotfiles-bsd ships top-level .config and .local that
    # also hold unrelated user data.
    mkdir -p "$CONFIG_DIR" "$HOME/.local/bin" "$HOME/.local/share"

    cd "$DOTFILES_SRC"
    stow -t "$HOME" --adopt \
        --ignore='install-shastenm\.sh' \
        --ignore='README\.md' \
        --ignore='\.git$' \
        --ignore='.*\.bak$' \
        . || die "stow failed"
    cd "$HOME"
    git -C "$DOTFILES_SRC" checkout . 2>/dev/null || true
    ok "Dotfiles deployed via stow from $DOTFILES_SRC"
}

# Slackware has no GNU stow package, and shastenm's own Slackware/FreeBSD
# installer scripts never used stow either — direct symlinking of
# dotfiles-bsd + nvim-configs (via sm-nvim-switcher) is the documented
# approach. This mimics stow's "merge directories, don't replace them"
# behavior by hand, walking one level into .config so unrelated existing
# config dirs (xfce4, etc.) are left alone.
_setup_dotfiles_symlink() {
    step "Symlinking dotfiles-bsd directly into \$HOME (no stow — $OS_ID)"
    mkdir -p "$HOME/.config" "$HOME/.local/bin"

    cd "$DOTFILES_SRC"
    for item in .[!.]* ..?*; do
        [ -e "$item" ] || continue
        case "$item" in
            install-shastenm.sh|README.md|.git|.gitignore|*.bak) continue ;;
            .config|.local)
                # Merge one level deep instead of symlinking the whole
                # top-level dir wholesale. This matters most for .local:
                # $WORK_DIR ($HOME/.local/share/shastenm-build) lives inside
                # it and is already populated with real clones by the time
                # this runs — wholesale-symlinking .local would mv that real
                # data out of the way and replace $HOME/.local with a
                # symlink into the dotfiles repo, which then resolves
                # $WORK_DIR somewhere else entirely (and can even ELOOP if
                # the repo's own .local has symlinks built assuming `stow`).
                for sub in "$item"/*; do
                    [ -e "$sub" ] || continue
                    local base target
                    base=$(basename "$sub")
                    target="$HOME/$item/$base"
                    mkdir -p "$HOME/$item"
                    if [ -e "$target" ] && [ ! -L "$target" ]; then
                        mv "$target" "$target.bak.$(date +%s)"
                    elif [ -L "$target" ]; then
                        rm -f "$target"
                    fi
                    ln -sfn "$DOTFILES_SRC/$item/$base" "$target"
                    info "Linked $item/$base"
                done
                ;;
            *)
                local target="$HOME/$item"
                if [ -e "$target" ] && [ ! -L "$target" ]; then
                    mv "$target" "$target.bak.$(date +%s)"
                elif [ -L "$target" ]; then
                    rm -f "$target"
                fi
                ln -sfn "$DOTFILES_SRC/$item" "$target"
                info "Linked $item"
                ;;
        esac
    done
    cd "$HOME"
    ok "Dotfiles symlinked directly from $DOTFILES_SRC ($OS_ID style, no stow)"
}

# ─── Activate a default nvim config from dotfiles-bsd's nvim-configs ───────
setup_nvim_configs() {
    step "Activating default nvim config"

    # CONFIRMED from the real dotfiles-bsd repo: ~/.config/nvim-configs is
    # NOT a separate thing this script needs to clone/deploy — it's already
    # bundled directly inside dotfiles-bsd's own .config/ (astro, dev, kick,
    # lazy, markdown, nvchad, nvim, writing, zeeno, plus the real
    # sm-nvim-switcher, sm-devjump, sm-sessionizer scripts and a `neovim`
    # file defining switch-astro/switch-dev/etc aliases). setup_dotfiles()
    # already deployed all of that. There is no separate nvim-configs repo
    # to clone here, and no separate "daily driver" nvim config outside of
    # nvim-configs either — his real sm-nvim-switcher always does
    # `rm -f ~/.config/nvim && ln -s ~/.config/nvim-configs/<name> ~/.config/nvim`,
    # so ~/.config/nvim is ALWAYS just whichever named config was last
    # selected. There's no "auto" restore concept in his real script — that
    # was an invented feature from an earlier, wrong assumption about his
    # setup and has been removed.
    local configs_dir="$HOME/.config/nvim-configs"
    local switcher="$configs_dir/sm-nvim-switcher"

    if [ ! -d "$configs_dir" ]; then
        warn "~/.config/nvim-configs not found after dotfiles deploy — check setup_dotfiles output above"
        return 1
    fi
    if [ ! -f "$switcher" ]; then
        warn "sm-nvim-switcher not found at $switcher — can't activate a default config"
        return 1
    fi
    chmod +x "$switcher" 2>/dev/null || true

    if [ -e "$HOME/.config/nvim" ] || [ -L "$HOME/.config/nvim" ]; then
        info "~/.config/nvim already exists — leaving your current selection alone (switch anytime with switch-astro/switch-dev/switch-lazy/switch-nvchad/switch-kick/switch-writing/switch-zeeno/switch-nvim)"
        NVIM_CONFIGS_DEPLOYED="astro dev kick lazy markdown nvchad nvim writing zeeno"
        return 0
    fi

    # First install on this machine — activate a sensible default so plain
    # `nvim` works immediately. astro (his AstroNvim-based "Development
    # Mode", per his own README) is the one he describes as his main
    # workhorse IDE config, so that's the default here.
    if "$switcher" astro; then
        ok "Activated 'astro' as the default nvim config (~/.config/nvim -> $configs_dir/astro)"
        NVIM_CONFIGS_DEPLOYED="astro dev kick lazy markdown nvchad nvim writing zeeno"
    else
        warn "sm-nvim-switcher astro failed — run it manually: $switcher astro"
        return 1
    fi
}

# ─── Setup spectrwm config from his spectrwm config repo ──────────────────────
# CONFIRMED: this repo was renamed on his GitLab from spectrwm-bsd -> spectrwm
# (same file layout — autostart.sh/baraction.sh/chinese_chars/conky/dzen2/
# scripts/spectrwm.conf/sxhkdrc — just dropped the "-bsd" suffix). Cloned to
# $WORK_DIR/spectrwm-config here, NOT $WORK_DIR/spectrwm, since that name is
# already used below for the separate upstream conformal/spectrwm WM source
# clone (see _build_spectrwm) — same new repo name, two different things.
setup_spectrwm_config() {
    step "Deploying spectrwm config from his spectrwm (config) repo"
    mkdir -p "$SPECTRWM_CONF_DEST"

    local cfg_src="$WORK_DIR/spectrwm-config"
    if [ ! -d "$cfg_src" ]; then
        warn "spectrwm config dir not found at $cfg_src — cloning it now instead of failing"
        clone_repo "$REPO_SPECTRWM_CFG" "$cfg_src"
    fi
    [ -d "$cfg_src" ] || die "spectrwm config dir still not found after clone attempt: $cfg_src"

    [ -f "$cfg_src/spectrwm.conf" ]    && cp "$cfg_src/spectrwm.conf"    "$SPECTRWM_CONF_DEST/"
    [ -f "$cfg_src/baraction.sh" ]     && cp "$cfg_src/baraction.sh"     "$SPECTRWM_CONF_DEST/"
    [ -f "$cfg_src/autostart.sh" ]     && cp "$cfg_src/autostart.sh"     "$SPECTRWM_CONF_DEST/"
    [ -f "$cfg_src/sxhkdrc" ]          && cp "$cfg_src/sxhkdrc"          "$SPECTRWM_CONF_DEST/"
    [ -f "$cfg_src/chinese_chars" ]    && cp "$cfg_src/chinese_chars"    "$SPECTRWM_CONF_DEST/" 2>/dev/null || true

    [ -d "$cfg_src/dzen2"  ]           && cp -r "$cfg_src/dzen2"          "$SPECTRWM_CONF_DEST/"
    [ -d "$cfg_src/scripts" ]          && cp -r "$cfg_src/scripts"       "$SPECTRWM_CONF_DEST/"
    # CONFIRMED real bug: conky/ was never deployed here even though
    # autostart.sh runs `conky -c ~/.config/spectrwm/conky/spectr-keys.conf &`
    # directly — that path would silently not exist without this.
    [ -d "$cfg_src/conky"  ]           && cp -r "$cfg_src/conky"          "$SPECTRWM_CONF_DEST/"

    chmod +x "$SPECTRWM_CONF_DEST/baraction.sh" 2>/dev/null || true
    chmod +x "$SPECTRWM_CONF_DEST/autostart.sh" 2>/dev/null || true
    chmod +x "$SPECTRWM_CONF_DEST/chinese_chars" 2>/dev/null || true
    [ -d "$SPECTRWM_CONF_DEST/scripts" ] && chmod +x "$SPECTRWM_CONF_DEST/scripts/"* 2>/dev/null || true

    # CONFIRMED real regression from the spectrwm-bsd -> spectrwm rename: the
    # CPU/mem functions in baraction.sh went from FreeBSD-native (`top -d1
    # | grep "CPU:"`, sysctl hw.physmem/vm.stats.vm.v_free_count) to pure
    # Linux (`top -bn1 | grep "Cpu(s)"`, `free -h`) — neither `top -bn1`'s
    # output format nor `free` exist on FreeBSD at all, so as deployed
    # verbatim (which is what "exact" means here) the bar's CPU/mem fields
    # will show blank or garbled on FreeBSD. This is NOT patched — the real
    # repo is Linux-only here now — just surfaced so it's not a mystery.
    if [ "$OS_ID" = "freebsd" ]; then
        warn "baraction.sh's CPU/mem functions are Linux-only in the current (renamed) spectrwm repo (top -bn1 / free -h) — they won't report correctly on FreeBSD as shipped. Deployed as-is to match his real repo exactly; the rest of the bar (battery/network/etc) is unaffected."
    fi

    # CONFIRMED real regression, same rename: chinese_chars' shebang changed
    # from #!/usr/local/bin/bash (the correct FreeBSD path for a
    # pkg-installed bash) to #!/bin/bash, which doesn't exist on stock
    # FreeBSD — bash there only lives at /usr/local/bin/bash. Rather than
    # silently leave baraction.sh's `~/.config/spectrwm/chinese_chars` call
    # failing with "no such file or directory" on every bar refresh, this
    # adds the one symlink that makes his real file work as shipped. This
    # IS an addition beyond his repo's own files (there is no such symlink
    # in the real repo) — flagged as exactly that, not presented as "his".
    if [ "$OS_ID" = "freebsd" ] && [ ! -e /bin/bash ] && [ -x /usr/local/bin/bash ]; then
        info "Added (not from his repo): /bin/bash -> /usr/local/bin/bash symlink, since chinese_chars now hardcodes #!/bin/bash"
        ln -sf /usr/local/bin/bash /bin/bash 2>/dev/null || warn "Couldn't symlink /bin/bash -> /usr/local/bin/bash (need root?) — chinese_chars will fail its shebang on FreeBSD until this exists"
    fi

    # CONFIRMED real bug: dzen2/bar and dzen2/menu/rdmenu are invoked
    # directly (toggle-panel does `eval "~/.config/spectrwm/dzen2/bar &"`,
    # sxhkdrc binds rdmenu to a keychord) but neither they nor
    # dzen2/scripts/docs and dzen2/scripts/dots (both launched via
    # `sh ~/.config/spectrwm/dzen2/scripts/...` from dzen2/bar's own
    # ^ca() click handlers) were ever chmod +x'd after deploy. Without
    # this the panel toggle and every dzen2 click-menu silently no-op.
    [ -f "$SPECTRWM_CONF_DEST/dzen2/bar" ]              && chmod +x "$SPECTRWM_CONF_DEST/dzen2/bar"
    [ -f "$SPECTRWM_CONF_DEST/dzen2/menu/rdmenu" ]      && chmod +x "$SPECTRWM_CONF_DEST/dzen2/menu/rdmenu"
    [ -f "$SPECTRWM_CONF_DEST/dzen2/menu/submenu.py" ]  && chmod +x "$SPECTRWM_CONF_DEST/dzen2/menu/submenu.py"
    [ -f "$SPECTRWM_CONF_DEST/dzen2/scripts/docs" ]     && chmod +x "$SPECTRWM_CONF_DEST/dzen2/scripts/docs"
    [ -f "$SPECTRWM_CONF_DEST/dzen2/scripts/dots" ]     && chmod +x "$SPECTRWM_CONF_DEST/dzen2/scripts/dots"

    # KNOWN QUIRK IN THE REAL REPO (left as-is, not "fixed" — the point is
    # to match what's actually there): dzen2/menu/rdmenu itself reads
    # $HOME/.config/bspwm/panel/menu/submenu.yaml — a leftover bspwm path
    # from an earlier iteration of his setup, not $HOME/.config/spectrwm/.
    # rdmenu will error "YAML file not found" on a clean spectrwm-only
    # install unless that path exists, so it's symlinked here rather than
    # silently left broken:
    if [ -f "$SPECTRWM_CONF_DEST/dzen2/menu/submenu.yaml" ]; then
        mkdir -p "$HOME/.config/bspwm/panel/menu"
        ln -sfn "$SPECTRWM_CONF_DEST/dzen2/menu/submenu.yaml" "$HOME/.config/bspwm/panel/menu/submenu.yaml"
        info "Linked stale bspwm path -> spectrwm's submenu.yaml (rdmenu reads the bspwm path verbatim in the real repo)"
    fi

    ok "spectrwm config deployed to $SPECTRWM_CONF_DEST"
}

setup_wallpapers() {
    step "Setting up wallpapers"
    if [ -d "$WORK_DIR/wallpaper" ]; then
        mkdir -p "$HOME/Pictures"
        cp -r "$WORK_DIR/wallpaper/"* "$HOME/Pictures/"
        ok "Wallpapers installed"
    else
        warn "No wallpaper/ directory found — skipping"
    fi
}

setup_cargo() {
    step "Setting up cargo stub"
    mkdir -p "$HOME/.cargo"
    touch "$HOME/.cargo/env"
    ok "~/.cargo/env ready"
}

install_starship() {
    step "Installing Starship prompt"
    if check_cmd starship || [ -x "$HOME/.local/bin/starship" ]; then
        info "Starship already installed — skipping"
        return
    fi
    mkdir -p "$HOME/.local/bin"
    # The official installer defaults to /usr/local/bin, which needs root.
    # This script never sudo's this curl|sh, so as a normal user the
    # installer just fails with "insufficient permissions" — and the old
    # `|| warn` swallowed that silently, so starship never actually landed.
    # -b installs to ~/.local/bin instead, matching where every other
    # user-level tool here already goes (cargo, go, sm-nvim-switcher).
    if curl -sS https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"; then
        ok "Starship installed to ~/.local/bin/starship"
    else
        warn "Starship install failed — install manually: curl -sS https://starship.rs/install.sh | sh -s -- -b ~/.local/bin"
        return
    fi
    ok "Starship binary ready at ~/.local/bin/starship"
}

# ─── Wire starship into ~/.bashrc (must run AFTER setup_dotfiles) ───────────
# This used to just warn "make sure .bashrc exports ~/.local/bin and inits
# starship, dotfiles-bsd should already do that" and leave it there. Two
# real problems with that:
#   1. It's an unverified assumption about what dotfiles-bsd's .bashrc
#      actually contains.
#   2. Even if install_starship HAD written to ~/.bashrc directly, it ran
#      BEFORE setup_dotfiles in main() — and on Slackware/FreeBSD,
#      setup_dotfiles symlinks ~/.bashrc straight from the dotfiles-bsd
#      repo, which would silently wipe out anything appended earlier.
# Fix: this runs AFTER setup_dotfiles, checks the actual deployed .bashrc,
# and appends whatever's missing — idempotent, safe to run every time.
ensure_starship_bashrc() {
    step "Wiring starship into ~/.bashrc"

    if [ ! -e "$HOME/.bashrc" ]; then
        warn "No ~/.bashrc found after dotfiles deploy — can't wire starship in. Check setup_dotfiles output above."
        return
    fi
    if [ ! -x "$HOME/.local/bin/starship" ] && ! check_cmd starship; then
        warn "starship binary not found — install_starship must have failed earlier. Skipping .bashrc wiring."
        return
    fi

    if ! grep -qE '(^|:)\$HOME/\.local/bin(:|$)|(^|:)~/\.local/bin(:|$)' "$HOME/.bashrc" 2>/dev/null \
       && ! grep -q 'HOME/.local/bin' "$HOME/.bashrc" 2>/dev/null; then
        {
            echo ''
            echo '# Added by install-shastenm.sh: ensure ~/.local/bin is on PATH (starship, sm-nvim-switcher, cargo, go, etc all land here)'
            echo 'export PATH="$HOME/.local/bin:$PATH"'
        } >> "$HOME/.bashrc"
        ok "Appended ~/.local/bin PATH export to ~/.bashrc"
    else
        info "~/.local/bin already on PATH in ~/.bashrc — skipping"
    fi

    if ! grep -q 'starship init bash' "$HOME/.bashrc" 2>/dev/null; then
        {
            echo ''
            echo '# Added by install-shastenm.sh: starship prompt'
            echo 'eval "$(starship init bash)"'
        } >> "$HOME/.bashrc"
        ok "Appended starship init to ~/.bashrc"
    else
        info "starship already initialized in ~/.bashrc — skipping"
    fi

    ok "Starship prompt will be active in new shells (run 'source ~/.bashrc' or open a new terminal)"
}

# ─── tmux plugin manager (tpm) ────────────────────────────────────────────
setup_tmux_plugins() {
    step "Setting up tmux plugin manager (tpm)"

    # CONFIRMED from his actual .tmux.conf: it uses real TPM, self-bootstrapping
    # on tmux startup via:
    #   if-shell "test ! -d ~/.tmux/plugins/tpm" "run 'git clone ... tpm'"
    #   run -b '~/.tmux/plugins/tpm/tpm'
    # with 5 real plugins declared: tmux-open, tmux-pain-control, tmux-sidebar,
    # tmux-yank, vim-tmux-navigator. My earlier guess that his README's "own
    # version of tmuxifier" meant NO plugin manager was wrong -- that line is
    # about a SEPARATE feature (.tmux/session-switch.sh, an fzf/rank-based
    # session switcher), not about how plugins load. Both are real and both
    # are independent of each other. Pre-cloning tpm here just saves the
    # first-launch delay/network dependency tmux's own if-shell would
    # otherwise hit -- it's not strictly required since tmux.conf bootstraps
    # itself, but doing it here means plugins are ready before the first
    # `tmux` invocation instead of on it.
    local tpm_dir="$HOME/.tmux/plugins/tpm"
    mkdir -p "$HOME/.tmux/plugins"

    if [ -d "$tpm_dir" ] && [ -x "$tpm_dir/tpm" ]; then
        info "tpm already present at $tpm_dir -- skipping clone"
    else
        rm -rf "$tpm_dir"   # dotfiles-bsd ships an empty .tmux/plugins/tpm placeholder dir -- clear it before cloning into it
        if git clone https://github.com/tmux-plugins/tpm "$tpm_dir" 2>/dev/null; then
            ok "tpm cloned to $tpm_dir"
        else
            warn "Failed to clone tpm -- tmux will still self-bootstrap it on first launch (its .tmux.conf has an if-shell fallback for this), or clone manually: git clone https://github.com/tmux-plugins/tpm $tpm_dir"
            return
        fi
    fi

    if [ -x "$tpm_dir/bin/install_plugins" ]; then
        "$tpm_dir/bin/install_plugins" >/dev/null 2>&1 \
            && ok "tmux plugins installed (tmux-open, tmux-pain-control, tmux-sidebar, tmux-yank, vim-tmux-navigator)" \
            || warn "tpm plugin install had issues -- inside tmux, press prefix+I (capital i, prefix is C-a here) to install manually"
    fi

    if check_cmd fzf; then
        ok "fzf present -- needed for his separate session-switch.sh session ranking script"
    else
        warn "fzf not found -- .tmux/session-switch.sh needs it; should already be installed, check the package step above"
    fi
}

install_rustup() {
    step "Installing Rust (rustup) — needed where the distro has no rust/cargo package"
    if check_cmd cargo; then
        info "cargo already installed — skipping"
        return
    fi
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y || warn "rustup install failed — install manually"
    # shellcheck disable=SC1090
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
}

install_go_tarball() {
    step "Installing Go from official tarball — needed where the distro has no go package"
    if check_cmd go; then
        info "go already installed — skipping"
        return
    fi
    local goarch="amd64"
    case "$(uname -m)" in
        x86_64|amd64) goarch="amd64" ;;
        aarch64|arm64) goarch="arm64" ;;
        *) warn "Unrecognized arch $(uname -m) for Go tarball — skipping, install manually"; return ;;
    esac
    local gosys="linux"
    [ "$OS_ID" = "freebsd" ] && gosys="freebsd"
    local tmp_tar="$WORK_DIR/go.tar.gz"
    mkdir -p "$WORK_DIR"
    if curl -fL "https://go.dev/dl/go1.23.0.${gosys}-${goarch}.tar.gz" -o "$tmp_tar"; then
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf "$tmp_tar" || warn "Go tarball extraction failed"
        if ! grep -q '/usr/local/go/bin' "$HOME/.bashrc" 2>/dev/null; then
            echo 'export PATH=$PATH:/usr/local/go/bin' >> "$HOME/.bashrc"
        fi
        ok "Go installed to /usr/local/go (added to PATH in .bashrc)"
    else
        warn "Go tarball download failed — install manually from go.dev"
    fi
}

install_neovim_tarball() {
    step "Installing Neovim from official prebuilt tarball — needed where the distro has no/an old neovim package"
    if check_cmd nvim; then
        info "nvim already installed — skipping"
        return
    fi
    local sys="linux64"
    [ "$OS_ID" = "freebsd" ] && { warn "No official Neovim FreeBSD tarball — install via 'pkg install neovim' instead, or build from source"; return; }
    local tmp_tar="$WORK_DIR/nvim.tar.gz"
    mkdir -p "$WORK_DIR"
    if curl -fL "https://github.com/neovim/neovim/releases/latest/download/nvim-${sys}.tar.gz" -o "$tmp_tar"; then
        sudo tar -C /usr/local -xzf "$tmp_tar" --strip-components=1 || warn "Neovim tarball extraction failed"
        ok "Neovim installed to /usr/local/bin/nvim"
    else
        warn "Neovim tarball download failed — install manually"
    fi
}

install_kitty_official() {
    step "Installing kitty via official installer — needed where the distro has no kitty package"
    if check_cmd kitty; then
        info "kitty already installed — skipping"
        return
    fi
    curl -fL https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin || warn "kitty installer failed — install manually"
    mkdir -p "$HOME/.local/bin"
    [ -e "$HOME/.local/kitty.app/bin/kitty" ] && ln -sf "$HOME/.local/kitty.app/bin/kitty" "$HOME/.local/bin/kitty"
}

install_fzf_git() {
    step "Installing fzf from source — needed where the distro has no fzf package"
    if check_cmd fzf; then
        info "fzf already installed — skipping"
        return
    fi
    clone_repo "https://github.com/junegunn/fzf.git" "$HOME/.fzf"
    "$HOME/.fzf/install" --bin --no-update-rc || warn "fzf install failed"
    ln -sf "$HOME/.fzf/bin/fzf" "$HOME/.local/bin/fzf" 2>/dev/null || true
}

# ─── SlackBuilds.org (SBo) — real package builds for what slackpkg lacks ────
# slackpkg only covers Slackware's own official package set, which doesn't
# include things like rofi, waybar, zathura, picom, sxhkd, fastfetch, etc.
# The standard, real-world way to get these on Slackware is building them
# from a SlackBuild (a shell script + .info file that downloads upstream
# source, compiles it, and packages it the Slackware way) from
# slackbuilds.org. Tools like sbopkg/sbotools automate this well, but both
# are themselves distributed AS SlackBuilds — a bootstrapping problem for a
# fresh install. This clones the official SBo tree directly and builds one
# package at a time instead, without that circular dependency.
#
# LIMITATION: this does NOT resolve/build a package's own dependency chain
# (that's genuinely what sbopkg/sbotools' queue files are for) — it just
# builds the one named package and tells you what its .info file says it
# REQUIRES, so you can build those first by hand if a build fails on a
# missing dependency.
SBO_REPO_DIR=""   # set by _sbo_ensure_repo() once cloned

_sbo_ensure_repo() {
    [ -n "$SBO_REPO_DIR" ] && return 0
    local dest="$WORK_DIR/slackbuilds"
    if [ -d "$dest/.git" ]; then
        info "SlackBuilds.org tree already present at $dest — skipping clone"
        SBO_REPO_DIR="$dest"
        return 0
    fi
    step "Cloning the SlackBuilds.org tree (large repo, one-time only)"
    if git clone --depth 1 https://gitlab.com/SlackBuilds.org/slackbuilds.git "$dest" 2>/dev/null; then
        SBO_REPO_DIR="$dest"
        ok "SlackBuilds.org tree cloned to $dest"
        return 0
    fi
    warn "Failed to clone the SlackBuilds.org tree — SBo package builds will be skipped this run"
    return 1
}

sbo_install() {
    local pkg="$1"

    if slackware_pkg_installed "$pkg"; then
        info "$pkg already installed — skipping SBo build"
        return 0
    fi

    _sbo_ensure_repo || return 1

    local build_dir
    build_dir=$(find "$SBO_REPO_DIR" -mindepth 2 -maxdepth 2 -type d -iname "$pkg" 2>/dev/null | head -1)
    if [ -z "$build_dir" ]; then
        warn "'$pkg' not found in the SlackBuilds.org tree under that exact name — check https://slackbuilds.org and build manually if it's named differently"
        return 1
    fi

    step "Building $pkg from SlackBuilds.org ($build_dir)"
    cd "$build_dir"

    local info_file="$build_dir/${pkg}.info"
    if [ -f "$info_file" ]; then
        # Join backslash-continued lines first — some .info files wrap
        # DOWNLOAD across multiple lines for packages with several source
        # tarballs, which would otherwise break the single-line sed below.
        local info_joined
        info_joined=$(sed ':a;N;$!ba;s/\\\n[[:space:]]*/ /g' "$info_file")

        local requires
        requires=$(printf '%s\n' "$info_joined" | sed -n 's/^REQUIRES="\(.*\)"/\1/p')
        if [ -n "$requires" ] && [ "$requires" != "%README%" ]; then
            info "$pkg's .info lists REQUIRES=\"$requires\" — build/install those first via sbo_install if this fails on a missing dependency"
        fi

        # Download the actual upstream source tarball(s) the .info file points at.
        local urls
        urls=$(printf '%s\n' "$info_joined" | sed -n 's/^DOWNLOAD\(_x86_64\)\?="\(.*\)"/\2/p' | tr ' ' '\n' | grep -v '^$')
        local total failed url_num consecutive_fails first_err
        total=$(printf '%s\n' "$urls" | grep -c .)
        failed=0
        url_num=0
        consecutive_fails=0

        if [ "$total" -gt 10 ]; then
            info "$pkg's .info lists $total separate source downloads (common for Rust packages that vendor crates individually) — this can take a while"
        fi

        for url in $urls; do
            url_num=$((url_num + 1))
            local err
            err=$(wget -q -c --tries=3 --timeout=15 "$url" -P "$build_dir" 2>&1)
            if [ $? -ne 0 ]; then
                failed=$((failed + 1))
                consecutive_fails=$((consecutive_fails + 1))
                if [ "$failed" -eq 1 ]; then
                    first_err="$err"
                    warn "Failed to download $url"
                    [ -n "$first_err" ] && warn "  reason: $first_err"
                fi
                # 5 straight failures on a big list is a systemic problem
                # (network down, DNS broken, firewall) — not worth grinding
                # through the other few hundred URLs to find out one at a
                # time. Bail with one clear message instead of a wall of
                # identical-looking warnings.
                if [ "$consecutive_fails" -ge 5 ] && [ "$total" -gt 10 ]; then
                    warn "$consecutive_fails downloads in a row have failed ($url_num/$total attempted) — this looks like a network problem, not a per-file issue. Stopping downloads for $pkg."
                    warn "Check connectivity to $(echo "$url" | sed -E 's#https?://([^/]+)/.*#\1#') and re-run once that's sorted — already-downloaded files are kept, so this will resume rather than restart."
                    break
                fi
            else
                consecutive_fails=0
            fi
        done

        if [ "$failed" -gt 1 ] && [ "$consecutive_fails" -lt 5 ]; then
            warn "$failed of $total downloads failed for $pkg (isolated failures, not a network-wide problem — could be stale/moved individual source URLs)"
        fi
    else
        warn "No ${pkg}.info found — SlackBuild will likely fail to find its source tarball"
    fi

    chmod +x "./${pkg}.SlackBuild" 2>/dev/null

    local build_log="$WORK_DIR/sbo-${pkg}-build.log"
    if sudo sh "./${pkg}.SlackBuild" 2>&1 | tee "$build_log"; then
        local built_pkg
        built_pkg=$(ls -t /tmp/${pkg}-*.tgz /tmp/${pkg}-*.txz 2>/dev/null | head -1)
        if [ -n "$built_pkg" ]; then
            if sudo installpkg "$built_pkg"; then
                ok "$pkg installed from SlackBuilds.org"
                cd "$DIR"
                return 0
            else
                warn "$pkg built but installpkg failed on $built_pkg"
            fi
        else
            warn "$pkg SlackBuild ran but no output package found in /tmp — check the build output above"
        fi
    else
        # The REQUIRES field is often empty/unhelpful (e.g. conky's real
        # missing dependency, imlib2, was never listed there at all — it
        # only showed up buried in its own CMake output). Grep the actual
        # captured build log for the common ways build systems phrase a
        # missing dependency, and surface those lines directly instead of
        # just gesturing at "check REQUIRES" and hoping.
        local hints
        hints=$(grep -iE "not found|NOTFOUND|could not find|none of the required|missing|no package .* found|unable to find|required.*not|^cmake error" "$build_log" 2>/dev/null | grep -viE "^--|Looking for" | sort -u | head -5)
        if [ -n "$hints" ]; then
            warn "$pkg SlackBuild failed. Likely missing dependency, found in the build log:"
            while IFS= read -r line; do
                warn "  $line"
            done <<< "$hints"
        else
            warn "$pkg SlackBuild failed — no obvious 'not found' hint in the log. Check $build_log directly for the real error."
        fi
        warn "Full build log saved at $build_log"
    fi
    cd "$DIR"
    return 1
}

# =============================================================================
# ─── Void Linux ───────────────────────────────────────────────────────────────
# =============================================================================
install_void() {
    step "Void Linux: Installing packages via xbps-install"

    sudo xbps-install -Syu || warn "xbps update failed, continuing"

    # REQUIRED: the actual build toolchain + X11/Xft/etc devel headers that
    # dzen2 and spectrwm need to compile, plus stow/neovim which the rest
    # of the script depends on. Installed one-at-a-time and verified — if
    # any of these are missing spectrwm/dzen2 CANNOT build, so we die here
    # with a clear list instead of failing later with a cryptic
    # "gcc: not found" mid-compile.
    local PKGS_VOID_REQUIRED=(
        git wget curl stow neovim
        pkg-config gcc make automake autoconf
        libX11-devel libXft-devel libXinerama-devel libXrandr-devel
        libXpm-devel freetype-devel cairo-devel pango-devel
        libxcb-devel xcb-util-devel libXcursor-devel xcb-util-wm-devel
        xcb-util-keysyms-devel libXt-devel fontconfig-devel
        libbsd-devel xlockmore
    )

    # OPTIONAL: nice-to-haves. Installed one-at-a-time so a package that
    # doesn't exist on the current xbps tree (waybar has been on/off
    # various Void repos over time) only costs itself instead of taking
    # gcc/pkg-config down with it.
    # NOTE: exa is unmaintained upstream — Void's package is 'eza' now,
    # which matches what's actually used in the shastenm aliases.
    local PKGS_VOID_OPTIONAL=(
        luarocks nodejs kitty wezterm ghostty
        xdotool nitrogen lxappearance picom sxhkd
        fzf bat eza tmux zk fastfetch
        rofi waybar zathura conky xclip xrdb
        go rust cargo
        # CONFIRMED from the real spectrwm repo (formerly spectrwm-bsd): autostart.sh runs
        # `clipmenud &` and `xfsettings &` directly, and sxhkdrc binds
        # keychords to gimp, l3afpad, and pavucontrol. All missing before.
        clipmenu xfce4-settings gimp l3afpad pavucontrol
        # dzen2/menu/submenu.py does `import yaml` — needs PyYAML.
        python3 python3-yaml
    )

    info "Installing required build/runtime packages (must all succeed)..."
    install_pkgs_resilient void_pkg_installed void_pkg_install required "${PKGS_VOID_REQUIRED[@]}"
    ok "All required Void packages present"

    info "Installing optional extras one-at-a-time (missing ones are skipped, not fatal)..."
    install_pkgs_resilient void_pkg_installed void_pkg_install optional "${PKGS_VOID_OPTIONAL[@]}"

    _build_dzen2_from_source
    _build_spectrwm "linux"
    _build_dmenu
    _build_xtitle
}

# =============================================================================
# ─── Slackware 15 ─────────────────────────────────────────────────────────────
# =============================================================================
# A fresh Slackware install has NO mirror configured in /etc/slackpkg/mirrors
# and slackpkg's GPG key has never been imported, so slackpkg itself is
# unusable until both are bootstrapped — this is the very first thing done.
SLACKWARE_MIRROR="https://mirrors.slackware.com/slackware/slackware64-15.0/"

bootstrap_slackware() {
    step "Bootstrapping slackpkg (mirror + GPG) — fresh Slackware ships with neither configured"

    [ -f /etc/slackpkg/mirrors ] || die "/etc/slackpkg/mirrors not found — is slackpkg installed? (it ships with Slackware by default)"

    if ! grep -qE '^[^#].*slackware64-15' /etc/slackpkg/mirrors 2>/dev/null; then
        info "No active mirror found — writing $SLACKWARE_MIRROR"
        sudo cp /etc/slackpkg/mirrors /etc/slackpkg/mirrors.bak.$(date +%s)
        echo "$SLACKWARE_MIRROR" | sudo tee -a /etc/slackpkg/mirrors >/dev/null
        ok "Mirror configured: $SLACKWARE_MIRROR"
    else
        info "Mirror already configured — skipping"
    fi

    sudo slackpkg update gpg || die "slackpkg update gpg failed"
    sudo slackpkg update || die "slackpkg update failed (check mirror reachability)"
    ok "slackpkg bootstrapped"
}

install_slackware() {
    step "Slackware 15: Installing packages via slackpkg"

    bootstrap_slackware

    # Slackware's "full install" already ships gcc/make/autoconf/automake,
    # X11 + dev headers, git, wget, curl, tmux, AND xfce4 itself. These are
    # still listed explicitly (one-at-a-time, same resilience fix as
    # Void/FreeBSD) in case of a minimal/custom install where slackpkg's
    # own transaction batching could otherwise let one bad name block the
    # rest.
    local PKGS_SLACKWARE_REQUIRED=(
        git wget curl tmux
        gcc make automake autoconf pkg-config
    )
    install_pkgs_resilient slackware_pkg_installed slackware_pkg_install required "${PKGS_SLACKWARE_REQUIRED[@]}"
    ok "All required Slackware packages present"

    # No GNU stow, no fzf, no rust/go in core Slackware repos — these come
    # from upstream tarballs/installers, same as elsewhere. neovim/kitty
    # ARE in current full Slackware 15 installs, but the tarball installers
    # below no-op cleanly if they're already present.
    install_neovim_tarball
    install_kitty_official
    install_fzf_git
    install_rustup
    install_go_tarball

    # ── Slackware gets dotfiles-bsd only — NO spectrwm ──────────────────
    # Per explicit instruction: spectrwm/dzen2/dmenu-solarized/xtitle
    # (and their WM-only support tools — sxhkd, nitrogen, picom, rofi,
    # waybar, clipmenu, conky's spectrwm bar config, the whole dzen2/
    # rdmenu/bspwm-path quirk) are Void- and FreeBSD-only now. Slackware
    # just runs dotfiles-bsd's shell/tmux/nvim/zk environment on top of
    # its stock XFCE session — no _build_spectrwm/_build_dzen2/_build_dmenu/
    # _build_xtitle calls, no setup_spectrwm_config, no setup_xinit
    # override (see main(), both are now skipped for OS_ID=slackware so
    # startx keeps launching Slackware's own default XFCE xinitrc).
    #
    # google-chrome-stable, gimp, l3afpad, pavucontrol, and xfce4-settings
    # are still installed below since they're genuinely useful apps under
    # XFCE on their own, independent of spectrwm/sxhkd even though that's
    # originally where they're bound in the real repo's sxhkdrc.
    local PKGS_SLACKWARE_DESKTOP=(gimp l3afpad pavucontrol zathura fastfetch)
    local dep
    for dep in "${PKGS_SLACKWARE_DESKTOP[@]}"; do
        if ! slackware_pkg_installed "$dep"; then
            if ! slackware_pkg_install "$dep"; then
                info "$dep not available via slackpkg — building from SlackBuilds.org instead"
                sbo_install "$dep" || warn "Couldn't get $dep from either slackpkg or SBo"
            fi
        fi
    done

    if check_cmd startxfce4; then
        info "XFCE detected (startxfce4 found) — this is Slackware's normal desktop session here; startx/xinitrc is left untouched (Void and FreeBSD get spectrwm, Slackware doesn't)"
    fi

    ok "Slackware package setup complete (dotfiles-bsd CLI environment + XFCE desktop apps — no spectrwm)"
}

# =============================================================================
# ─── FreeBSD 14 ────────────────────────────────────────────────────────────────
# =============================================================================
bootstrap_freebsd_pkg() {
    step "Bootstrapping pkg"
    if check_cmd pkg; then
        info "pkg already bootstrapped — updating catalog"
        sudo pkg update || warn "pkg update failed, continuing"
        return
    fi
    sudo env ASSUME_ALWAYS_YES=YES pkg bootstrap -y || die "pkg bootstrap failed"
}

install_freebsd() {
    step "FreeBSD 14: Installing packages via pkg"

    bootstrap_freebsd_pkg

    # Same atomic-transaction issue as Void applies to `pkg install` with a
    # multi-package list — one unresolvable name aborts the whole batch.
    # Required build toolchain + X11/Xft/etc headers first (must succeed),
    # then optional extras one-at-a-time.
    local PKGS_FREEBSD_REQUIRED=(
        git wget curl neovim
        gmake cmake pkgconf autoconf automake
        libX11 libXft libXinerama libXrandr libXpm
        freetype2 cairo pango
        libxcb xcb-util xcb-util-wm xcb-util-keysyms libXcursor
        libXt fontconfig
        libbsd
    )
    local PKGS_FREEBSD_OPTIONAL=(
        node npm kitty
        xdotool nitrogen lxappearance picom sxhkd
        fzf bat tmux
        rofi zathura
        conky xclip
        go rust
        # CONFIRMED from the real spectrwm repo (formerly spectrwm-bsd): autostart.sh runs
        # `clipmenud &` and `xfsettings &` directly, sxhkdrc binds
        # keychords to gimp/l3afpad/pavucontrol. All missing before.
        clipmenu xfce4-settings gimp l3afpad pavucontrol
        # dzen2/menu/submenu.py does `import yaml` — FreeBSD's package is py-yaml.
        py311-yaml
    )

    info "Installing required build/runtime packages (must all succeed)..."
    install_pkgs_resilient freebsd_pkg_installed freebsd_pkg_install required "${PKGS_FREEBSD_REQUIRED[@]}"
    ok "All required FreeBSD packages present"

    info "Installing optional extras one-at-a-time (missing ones are skipped, not fatal)..."
    install_pkgs_resilient freebsd_pkg_installed freebsd_pkg_install optional "${PKGS_FREEBSD_OPTIONAL[@]}"
    info "eza/zk/waybar/wezterm/ghostty/fastfetch aren't in this list — not consistently in pkg across FreeBSD 14 branches"

    _build_dzen2_from_source
    # FreeBSD's base `make` IS BSD make, which is exactly what conformal's
    # top-level spectrwm Makefile is written for — unlike Linux, do NOT
    # redirect into the linux/ subdir here.
    _build_spectrwm "bsd"
    _build_dmenu
    _build_xtitle
}

# =============================================================================
# ─── Build helpers (shared across all 3 OSes) ────────────────────────────────
# =============================================================================
_build_spectrwm() {
    local target="$1"   # "linux" or "bsd"
    step "Building spectrwm ($OS_ID, target=$target)"
    clone_repo "$REPO_SPECTRWM" "$WORK_DIR/spectrwm"

    local build_dir log_make
    if [ "$target" = "linux" ]; then
        # The top-level Makefile is BSD-make syntax and fails under GNU make
        # ("missing separator") — the actual Linux build lives in linux/.
        build_dir="$WORK_DIR/spectrwm/linux"
        log_make="make"
        [ -d "$build_dir" ] || die "spectrwm linux/ build dir not found — repo layout may have changed"
        if ! pkg-config --exists libbsd-overlay 2>/dev/null; then
            die "libbsd-overlay.pc not found — install libbsd-devel (Void: xbps-install -y libbsd-devel / Slackware: sudo sboinstall libbsd) and re-run"
        fi
    else
        # FreeBSD: build the top-level Makefile directly with native BSD make.
        build_dir="$WORK_DIR/spectrwm"
        log_make="make"
    fi

    cd "$build_dir"
    $log_make 2>&1 | tee "$WORK_DIR/spectrwm_compile.log" || die "spectrwm compilation failed — see $WORK_DIR/spectrwm_compile.log"
    sudo $log_make install
    cd "$DIR"

    # CONFIRMED via his real install-fedora.sh: it installs spectrwm.desktop
    # to /usr/share/xsessions so display managers (GDM/LightDM/etc) can list
    # spectrwm as a session — without this, spectrwm only works via `startx`
    # (which this script also wires up via setup_xinit, but a DM-based login
    # screen wouldn't show it as an option at all otherwise). Confirmed the
    # upstream conformal/spectrwm repo ships spectrwm.desktop at its root.
    if [ -f "$WORK_DIR/spectrwm/spectrwm.desktop" ]; then
        sudo mkdir -p /usr/share/xsessions
        sudo cp "$WORK_DIR/spectrwm/spectrwm.desktop" /usr/share/xsessions/spectrwm.desktop
        ok "spectrwm.desktop installed to /usr/share/xsessions — spectrwm will now show up as a session option in display managers too, not just via startx"
    else
        warn "spectrwm.desktop not found in the cloned repo — spectrwm will only be launchable via startx, not from a display manager's session picker"
    fi

    ok "spectrwm installed"
}

_build_dmenu() {
    step "Building dmenu-solarized"
    clone_repo "$REPO_DMENU" "$WORK_DIR/dmenu-solarized"
    cd "$WORK_DIR/dmenu-solarized"
    "$MAKE_GNU" || die "dmenu-solarized compilation failed"
    sudo "$MAKE_GNU" install
    cd "$DIR"
    ok "dmenu-solarized installed"
}

_build_xtitle() {
    step "Building xtitle"
    clone_repo "$REPO_XTITLE" "$WORK_DIR/xtitle"
    cd "$WORK_DIR/xtitle"
    "$MAKE_GNU" || die "xtitle compilation failed"
    sudo "$MAKE_GNU" install
    cd "$DIR"
    ok "xtitle installed"
}


# NOTE: unused as of this version — Slackware no longer builds spectrwm/
# libbsd (see install_slackware), and Void/FreeBSD get libbsd via their
# package managers. Left in place in case Slackware+spectrwm support returns.
_build_libmd_from_source() {
    step "Building libmd from source (libbsd dependency, no slackpkg package on Slackware)"

    if pkg-config --exists libmd 2>/dev/null; then
        info "libmd already available — skipping"
        return
    fi

    local tmp_tar="$WORK_DIR/libmd.tar.xz"
    local src_dir="$WORK_DIR/libmd-src"
    mkdir -p "$WORK_DIR" "$src_dir"

    curl -fL "$LIBMD_TARBALL_URL" -o "$tmp_tar" || die "Failed to download libmd source tarball"
    tar -xJf "$tmp_tar" -C "$src_dir" --strip-components=1 || die "Failed to extract libmd tarball"

    cd "$src_dir"
    ./configure --prefix=/usr/local || { tail -n 40 config.log 2>/dev/null; die "libmd configure failed (see config.log tail above)"; }
    "$MAKE_GNU" || die "libmd build failed"
    sudo "$MAKE_GNU" install || die "libmd install failed"
    sudo ldconfig 2>/dev/null || true

    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    if ! grep -q '/usr/local/lib/pkgconfig' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}' >> "$HOME/.bashrc"
    fi

    cd "$DIR"
    pkg-config --exists libmd || die "libmd built but libmd.pc still not found — check PKG_CONFIG_PATH"
    ok "libmd built and installed from source ($LIBMD_TARBALL_URL)"
}

_build_libbsd_from_source() {
    step "Building libbsd from source (no slackpkg package on Slackware)"

    if pkg-config --exists libbsd-overlay 2>/dev/null; then
        info "libbsd-overlay already available — skipping"
        return
    fi

    _build_libmd_from_source

    local tmp_tar="$WORK_DIR/libbsd.tar.xz"
    local src_dir="$WORK_DIR/libbsd-src"
    mkdir -p "$WORK_DIR" "$src_dir"

    curl -fL "$LIBBSD_TARBALL_URL" -o "$tmp_tar" || die "Failed to download libbsd source tarball"
    tar -xJf "$tmp_tar" -C "$src_dir" --strip-components=1 || die "Failed to extract libbsd tarball"

    cd "$src_dir"
    ./configure --prefix=/usr/local || { tail -n 40 config.log 2>/dev/null; die "libbsd configure failed (see config.log tail above)"; }
    "$MAKE_GNU" || die "libbsd build failed"
    sudo "$MAKE_GNU" install || die "libbsd install failed"
    sudo ldconfig 2>/dev/null || true

    # Slackware's pkg-config doesn't search /usr/local/lib/pkgconfig by
    # default, which is where the libbsd-overlay.pc we just installed lives.
    export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    if ! grep -q '/usr/local/lib/pkgconfig' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}' >> "$HOME/.bashrc"
    fi

    cd "$DIR"
    pkg-config --exists libbsd-overlay || die "libbsd built but libbsd-overlay.pc still not found — check PKG_CONFIG_PATH"
    ok "libbsd built and installed from source ($LIBBSD_TARBALL_URL)"
}

_build_dzen2_from_source() {
    step "Building dzen2 from source"
    if check_cmd dzen2; then
        info "dzen2 already installed — skipping"
        return
    fi
    clone_repo "https://github.com/robm/dzen.git" "$WORK_DIR/dzen2-src"
    cd "$WORK_DIR/dzen2-src"
    "$MAKE_GNU" || warn "dzen2 build failed — continuing without it"
    sudo "$MAKE_GNU" install || warn "dzen2 install failed"
    cd "$DIR"
    ok "dzen2 build complete"
}

# =============================================================================
# ─── Clone shastenm's support repos (everything except dotfiles-bsd) ────────
# =============================================================================
clone_shastenm_repos() {
    step "Cloning shastenm support repositories into $WORK_DIR"
    mkdir -p "$WORK_DIR"

    clone_repo "$REPO_BIN"                     "$WORK_DIR/bin"
    clone_repo "$REPO_WALLPAPER"               "$WORK_DIR/wallpaper"
    clone_repo "$REPO_DOTFILES_INSTALLATION"   "$WORK_DIR/dotfiles-installation"   # fonts live here, needed on all 3 OSes

    if [ "$OS_ID" != "slackware" ]; then
        # spectrwm/dzen2/dmenu-solarized/xtitle are Void/FreeBSD only now
        # (Slackware doesn't get spectrwm — dotfiles-bsd's CLI environment
        # only, on top of stock XFCE).
        clone_repo "$REPO_SPECTRWM_CFG" "$WORK_DIR/spectrwm-config"
        clone_repo "$REPO_DMENU"        "$WORK_DIR/dmenu-solarized"
        clone_repo "$REPO_XTITLE"       "$WORK_DIR/xtitle"
    else
        info "Skipping spectrwm-config/dmenu-solarized/xtitle clones on Slackware (spectrwm is Void/FreeBSD only)"
    fi
    # NOTE: nvim-configs (REPO_NVIM_CONFIGS) is NOT cloned separately here —
    # confirmed from the real dotfiles-bsd checkout that it's already
    # bundled at dotfiles-bsd's own .config/nvim-configs, deployed by
    # setup_dotfiles(). A standalone clone would just be redundant.
}

# =============================================================================
# ─── xsession wiring ──────────────────────────────────────────────────────────
# =============================================================================
setup_xinit() {
    step "Setting up X session entry"

    # ~/.xsession is read by display managers (xdm/lightdm/slim) when the
    # user picks a "custom session". ~/.xinitrc is what `startx` reads.
    # Slackware ships with NO display manager by default — startx is the
    # normal way in. Without ~/.xinitrc, startx silently falls back to the
    # system default (generic twm session), which looked like "spectrwm
    # isn't working" even though spectrwm itself was installed fine.
    local xrc="$HOME/.xsession"
    local xinitrc="$HOME/.xinitrc"

    if [ ! -f "$xrc" ]; then
        cat > "$xrc" <<'EOF'
#!/bin/sh
# Generated by install-shastenm.sh
export EDITOR=nvim
export TERM=xterm-256color
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
[ -f ~/.config/spectrwm/autostart.sh ] && sh ~/.config/spectrwm/autostart.sh &
exec spectrwm
EOF
        chmod +x "$xrc"
        ok "~/.xsession written"
    else
        warn "~/.xsession already exists — skipping"
    fi

    if [ ! -e "$xinitrc" ]; then
        # Symlink rather than duplicate: edits to one keep both in sync,
        # and it makes the relationship between the two obvious later.
        ln -sfn "$xrc" "$xinitrc"
        ok "~/.xinitrc -> ~/.xsession (so 'startx' launches spectrwm directly)"
    elif [ -L "$xinitrc" ] && [ "$(readlink "$xinitrc")" = "$xrc" ]; then
        info "~/.xinitrc already linked to ~/.xsession — skipping"
    elif [ "$OS_ID" = "slackware" ] && [ -L "$xinitrc" ] && [[ "$(readlink "$xinitrc")" == /etc/X11/xinit/* ]]; then
        # Slackware auto-populates every new user's ~/.xinitrc from
        # /etc/skel/.xinitrc, which is itself a symlink to one of the stock
        # /etc/X11/xinit/xinitrc.* alternatives — xinitrc.xfce by default on
        # a full install. That's a distro default nobody chose, not a user
        # customization, so it's safe (and necessary) to override it —
        # otherwise startx keeps launching XFCE forever, silently.
        local stock_target
        stock_target="$(readlink "$xinitrc")"
        warn "~/.xinitrc is Slackware's stock default (-> $stock_target) — replacing with spectrwm"
        rm -f "$xinitrc"
        ln -sfn "$xrc" "$xinitrc"
        ok "~/.xinitrc -> ~/.xsession (overrode Slackware's default XFCE xinitrc)"
    else
        warn "~/.xinitrc already exists and isn't ours — leaving it alone."
        warn "startx will use that file, not spectrwm, until you point it at ~/.xsession yourself"
        warn "(e.g. 'ln -sfn ~/.xsession ~/.xinitrc' once you've checked what's in the existing one)"
    fi
}

# =============================================================================
# ─── Post-install summary ────────────────────────────────────────────────────
# =============================================================================
print_summary() {
    echo ""
    echo -e "${CYN}╔══════════════════════════════════════════════════════════╗${RST}"
    echo -e "${CYN}║   shastenm dotfiles-bsd installation complete ($OS_ID)${RST}"
    echo -e "${CYN}╚══════════════════════════════════════════════════════════╝${RST}"
    echo ""
    echo -e "  OS             : ${GRN}$OS_ID${RST}"
    if [ "$OS_ID" = "slackware" ]; then
        echo -e "  Window Manager : ${YLW}none deployed${RST}  (Slackware stays on its stock XFCE session — spectrwm is Void/FreeBSD only)"
    else
        echo -e "  Window Manager : ${GRN}spectrwm${RST}"
    fi
    echo -e "  Terminal       : ${GRN}kitty${RST}  (MonaspiceNE / TokyoNight)"
    echo -e "  Shell prompt   : ${GRN}starship${RST}"
    if [ -n "$NVIM_CONFIGS_DEPLOYED" ]; then
        echo -e "  Editor         : ${GRN}neovim${RST}  (astro active by default; also available: $NVIM_CONFIGS_DEPLOYED)"
    else
        echo -e "  Editor         : ${YLW}neovim${RST}  (couldn't activate a default config — see warnings above)"
    fi
    if [ "$OS_ID" != "slackware" ]; then
        echo -e "  Bar            : ${GRN}spectrwm bar_action${RST} + dzen2"
    fi
    if [ "$OS_ID" = "void" ]; then
        echo -e "  Dotfiles       : ${GRN}$DOTFILES_SRC${RST}  (stowed to \$HOME)"
    else
        echo -e "  Dotfiles       : ${GRN}$DOTFILES_SRC${RST}  (symlinked directly to \$HOME, no stow)"
    fi
    if [ "$OS_ID" != "slackware" ]; then
        echo -e "  Spectrwm cfg   : ${GRN}$SPECTRWM_CONF_DEST${RST}  (from smothermonethan2002/spectrwm)"
    fi
    echo ""
    echo -e "  ${YLW}Next steps:${RST}"
    if [ "$OS_ID" = "slackware" ]; then
        echo "   • Log in to your usual XFCE session (startx/xinitrc was left at Slackware's stock default — untouched)"
    else
        echo "   • Log out and select spectrwm at your display manager (if you use one)"
        echo "   • Or just run 'startx' — ~/.xinitrc is already wired to launch spectrwm"
    fi
    if [ -n "$NVIM_CONFIGS_DEPLOYED" ]; then
        echo "   • plain 'nvim' launches astro (AstroNvim-based) by default"
        echo "   • Switch configs with the real aliases from his dotfiles (already sourced via .bashrc):"
        echo "       switch-astro / switch-dev / switch-lazy / switch-lunar / switch-nvchad / switch-kick / switch-writing / switch-zeeno / switch-nvim"
        echo "     (these just symlink ~/.config/nvim to ~/.config/nvim-configs/<name> — whichever you pick stays active until you switch again)"
    fi
    if [ "$OS_ID" = "slackware" ]; then
        echo ""
        echo -e "  ${YLW}Slackware note:${RST} no spectrwm/dzen2/dmenu-solarized/xtitle/sxhkd/nitrogen/picom —"
        echo "   this run installed dotfiles-bsd's CLI environment (bash, tmux, neovim, zk, starship) plus"
        echo "   gimp/l3afpad/pavucontrol/zathura/fastfetch for use under Slackware's own stock XFCE session."
    fi
    echo ""
    echo -e "  Support repos cloned to: ${BLU}$WORK_DIR${RST}"
    if [ "$OS_ID" != "slackware" ]; then
        echo -e "  Compile log:             ${BLU}$WORK_DIR/spectrwm_compile.log${RST}"
    fi
    echo ""
}

# =============================================================================
# ─── MAIN ────────────────────────────────────────────────────────────────────
# =============================================================================
main() {
    echo -e "${CYN}"
    echo "  ┌─────────────────────────────────────────────────────┐"
    echo "  │  dotfiles-bsd installer                               │"
    echo "  │  Void Linux / Slackware 15 / FreeBSD 14               │"
    echo "  │  spectrwm on Void + FreeBSD only — Slackware = XFCE   │"
    echo "  │  Source: shastenm / smothermonethan2002 forks         │"
    echo "  └─────────────────────────────────────────────────────┘"
    echo -e "${RST}"

    if [ "$(id -u)" -eq 0 ]; then
        warn "Running as root (\$HOME=$HOME) — clones, dotfiles, and spectrwm config will all"
        warn "land under /root instead of your normal user's home. This script calls sudo"
        warn "itself wherever root is needed, so re-run it as your normal user (no sudo)."
        warn "If a previous run already populated $WORK_DIR under your real user's home,"
        warn "running as root again will look in /root instead and find it 'not found'."
    fi

    detect_os
    resolve_dotfiles_src

    step "Cloning shastenm support repos"
    clone_shastenm_repos

    step "Installing OS packages"
    case "$OS_ID" in
        void)      install_void ;;
        slackware) install_slackware ;;
        freebsd)   install_freebsd ;;
        *)         die "Unsupported OS_ID: $OS_ID" ;;
    esac

    # CONFIRMED from the real spectrwm repo (formerly spectrwm-bsd): sxhkdrc binds a keychord
    # directly to `google-chrome-stable`. Deliberately NOT auto-installed —
    # it's closed-source and each OS needs a different, less scriptable
    # path: Void has it in the xbps nonfree repo (`xbps-install -R
    # nonfree google-chrome` after enabling void-repo-nonfree), Slackware
    # needs its own SlackBuild from slackbuilds.org (google-chrome, which
    # itself just wraps Google's .deb — SBo can't legally redistribute the
    # binary, so the build fetches it from Google directly and prompts),
    # and FreeBSD has no Chrome port at all (closest native equivalent is
    # www/chromium; Chrome itself only works there via the Linux
    # compatibility layer, which isn't something to silently bootstrap).
    case "$OS_ID" in
        void)      warn "google-chrome-stable (bound in sxhkdrc) not auto-installed — enable the nonfree repo first: sudo xbps-install -S void-repo-nonfree && sudo xbps-install -S google-chrome" ;;
        freebsd)   warn "google-chrome-stable (bound in sxhkdrc) not auto-installed — FreeBSD has no Chrome port; closest native option is 'sudo pkg install chromium', or run Chrome via linux-chrome under the Linux compat layer" ;;
        slackware) : ;; # no spectrwm/sxhkdrc deployed on Slackware — that keychord doesn't apply here
    esac

    setup_fonts
    setup_bin
    setup_cargo
    install_starship
    setup_wallpapers
    if [ "$OS_ID" != "slackware" ]; then
        setup_spectrwm_config
    else
        info "Skipping spectrwm config deploy on Slackware (spectrwm is Void/FreeBSD only per instruction)"
    fi
    setup_dotfiles
    ensure_starship_bashrc
    setup_nvim_configs || true
    setup_tmux_plugins
    if [ "$OS_ID" != "slackware" ]; then
        setup_xinit
    else
        info "Skipping startx->spectrwm wiring on Slackware — startx/xinitrc left at its stock XFCE default"
    fi
    print_summary
}

main "$@"
