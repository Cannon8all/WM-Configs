#!/usr/bin/env bash
set -euo pipefail

# ------------------------------- fancy output -------------------------------
# Palette: green = body text, purple = headers / prompts / separators.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET='\033[0m'
    C_BOLD='\033[1m'
    C_GREEN='\033[0;32m'
    C_PURPLE='\033[0;35m'
else
    C_RESET=''; C_BOLD=''; C_GREEN=''; C_PURPLE=''
fi

say()     { printf "${C_GREEN}%b${C_RESET}\n" "$*"; }
accent()  { printf "${C_PURPLE}%b${C_RESET}\n" "$*"; }
bar()     { local w="${COLUMNS:-80}"; printf "${C_PURPLE}"; printf '%*s' "$w" '' | tr ' ' '─'; printf "${C_RESET}\n"; }

banner() {
    bar
    printf "${C_PURPLE}${C_BOLD}%b${C_RESET}\n" "  ╭──────────────────────────────────────────────────────────────╮"
    printf "${C_PURPLE}${C_BOLD}%b${C_RESET}\n" "  │              OTTER SHELL — INSTALLER & UPDATER               │"
    printf "${C_PURPLE}${C_BOLD}%b${C_RESET}\n" "  ╰──────────────────────────────────────────────────────────────╯"
    say "  Detects your distro, installs dependencies via pkexec,"
    say "  builds every otter repo, and installs fonts & models."
    bar
}

# Ask a single-keypress question: press y (yes) or n (no), no Enter needed.
# With -y/--yes it auto-answers yes. 0 = yes, 1 = no.
ask_yn() {
    local ans=""
    if [ "$AUTOYES" = "1" ]; then
        say "  (auto-answering: yes)"
        return 0
    fi
    while true; do
        printf "${C_PURPLE}%b${C_RESET}" "$* [y/n] > "
        if ! IFS= read -r -n 1 ans; then
            printf "\n"
            say "  (no input on stdin — treating as no)"
            return 1
        fi
        case "${ans,,}" in
            y) printf "\n"; return 0 ;;
            n) printf "\n"; return 1 ;;
            *)
                printf "\r"
                say "  Please press y or n."
                ;;
        esac
    done
}

# Non-interactive mode: -y/--yes answers yes to every question.
AUTOYES="${OTTER_AUTOYES:-0}"
PHASE="user"

BASE_URL="https://git.pika-os.com/otter-shell"
ROOT_DIR="$(dirname "$(realpath "$0")")/otter-shell"

# Remember the user who started the script; the privileged (pkexec) phase runs
# as root and must hand the build tree back to this user at the end.
OTTER_INVOKER="${OTTER_INVOKER:-$(id -un)}"

case "${1:-}" in
    -y|--yes) AUTOYES="1" ;;
    -h|--help)
        cat <<EOF
usage: $(basename "$0") [-y|--yes] [--continue]

  Installs / updates Otter Shell. Asks the questions first (as the current
  user), then re-elevates through a single pkexec and runs the whole
  privileged install as root.
  -y/--yes      auto-answers yes for unattended runs.
  --continue    (internal) skip questions, run the privileged phase as root.
EOF
        exit 0
        ;;
    --continue)
        PHASE="root"
        if [ -n "${2:-}" ]; then
            OTTER_INVOKER="$2"
        fi
        ;;
    *)
        EXTRA_ARGS=("$@")
        ;;
esac

START_UID="$(id -u)"
START_USER="$OTTER_INVOKER"

# Repos are often cloned/owned by mixed users (root via pkexec, or the invoking
# user). Suppress git's protective per-directory "dubious ownership" fail -
# after a full run the tree is re-owned back to START_USER. Requires a writable
# git config; ignore failures (non-git or busybox environments).
git config --system --add safe.directory '*' 2>/dev/null || true

# Per-repo versioning: each otter repo is tagged independently (there is no
# single shared release tag across the group). We check out each repo's own
# latest vX.Y.Z tag, falling back to the default branch for repos with no tags
# (e.g. otter-examples). Repos with no build.zig get skipped during the build.

# All otter-shell apps/libraries that can be built from source via `zig build install`.
#
# Deliberately NOT built (unbuildable on Fedora/Arch from a plain zig build):
#   otter-browser     - needs a WPE WebKit engine rebuilt from source first
#                       (scripts/build-webkit.sh); plain `zig build install`
#                       produces no browser without it.
#   otter-pkg         - links against APT (apt-pkg), which is Debian-only and
#                       not packaged on Fedora or Arch.
# Not apps (no build.zig, packaging/scripts/website only):
#   otter-zenith, otter-gaming-utils, otter-site
REPOS=(
    # --- core libraries ---
    otter-conf otter-config-types otter-utils otter-geo otter-wayland
    otter-theme otter-render otter-desktop otter-ui otter-tools-core otter-vte

    # --- shell / desktop ---
    otter-bar otter-launcher otter-lock otter-logout otter-osd otter-greeter
    otter-idle otter-notifications otter-wallpaper otter-settings otter-theme-gen
    otter-keybindhelp otter-overview otter-dock otter-taskbar

    # --- utilities ---
    otter-screenshot otter-shot otter-clip otter-pick otter-emoji otter-calc
    otter-cal otter-timer otter-note otter-clicker otter-monitor otter-nightlight
    otter-search

    # --- apps / widgets ---
    otter-term otter-jade otter-files otter-rec otter-vox otter-transcribe
    otter-assist otter-assistant otter-weather otter-cue otter-installer
    otter-first-setup otter-welcome otter-bench otter-hypr

    # --- system integration / plugins ---
    otter-polkit xdg-desktop-portal-otter bluetooth-applet-plugin
    otter-shell-plugins otter-plugin-factory otter-examples
)

# --- Dependency sets verified against the Arch Linux package database
#     (archlinux.org/packages) and Fedora (packages.fedoraproject.org) ---
ARCH_DEPS=(
    # existing core deps
    wayland libxkbcommon freetype2 fontconfig pam jemalloc zig ghostty
    # additional system libs needed by the newer apps
    libssh libwebp libdrm libglvnd mesa vulkan-headers vulkan-icd-loader libei
    cmake gcc patchelf pkgconf ffmpeg
    # Primary UI font ('Inter'): otter-render resolves it by family name via
    # fontconfig, and also via a Debian-specific hardcoded path that never
    # exists elsewhere, so the fontconfig fallback must find Inter installed.
    inter-font
    # apt-pkg: otter-first-setup and otter-welcome build otter_pkg's vendored
    # apt-dpkg-libs shim (cmake pkg_check_modules REQUIRED apt-pkg). Arch's
    # `apt` ships /usr/include/apt-pkg, libapt-pkg.so and /usr/lib/pkgconfig/apt-pkg.pc.
    apt
)

FEDORA_DEPS=(
    # existing core deps
    wayland-devel libxkbcommon-devel freetype-devel fontconfig-devel pam-devel
    jemalloc-devel zig
    # additional system devel libs needed by the newer apps
    libssh-devel libwebp-devel libdrm-devel
    mesa-libEGL-devel mesa-libGLES-devel mesa-libGL-devel
    vulkan-headers vulkan-loader-devel libei-devel libeis-devel
    cmake gcc-c++ patchelf pkgconf-pkg-config
    # Primary UI font ('Inter'); otter-render resolves it by family name.
    inter-fonts
    # ffmpeg (otter-rec) comes from RPM Fusion free, enabled below
    ffmpeg-devel
)

if [ "$PHASE" != "root" ]; then

banner

if ask_yn "Do you want to install Otter?"; then
    say "  Great — let's get Otter Shell set up."
else
    say "  Okay, no install today. Exiting."
    exit 0
fi

bar
accent "Detecting your distribution..."
DISTRO=""
DISTRO_NAME=""
if command -v pacman &>/dev/null; then
    DISTRO="arch"
    DISTRO_NAME="Arch Linux"
elif command -v dnf &>/dev/null; then
    DISTRO="fedora"
    DISTRO_NAME="Fedora"
else
    accent "Error: unsupported distro (neither pacman nor dnf found)."
    exit 1
fi
say "  Detected: $DISTRO_NAME"

if ask_yn "Are you on $DISTRO_NAME?"; then
    say "  Perfect, continuing with $DISTRO_NAME setup."
else
    say "  Can't proceed without the right distro. Exiting."
    exit 1
fi

bar
accent "Checking repos against the latest releases..."

ALL_CURRENT=1

for name in "${REPOS[@]}"; do
    dir="$ROOT_DIR/$name"
    if [ ! -d "$dir/.git" ]; then
        say "  - $name: not cloned yet"
        ALL_CURRENT=0
        continue
    fi
    current="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    cur_short="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
    repo_tag="$(git ls-remote --tags --refs "$BASE_URL/$name" 2>/dev/null \
        | grep -oP 'refs/tags/\Kv[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 \
        || true)"
    if [ -n "$repo_tag" ]; then
        latest="$(git ls-remote "$BASE_URL/$name" "refs/tags/$repo_tag" 2>/dev/null | awk '{print $1}')"
        if [ -z "$latest" ] || [ "$current" != "$latest" ]; then
            say "  - $name: update available (latest tag $repo_tag)"
            ALL_CURRENT=0
        else
            say "  - $name: already at latest tag $repo_tag ($cur_short)"
        fi
    else
        remote_head="$(git ls-remote "$BASE_URL/$name" HEAD 2>/dev/null | awk '{print $1}')"
        if [ -z "$remote_head" ] || [ "$current" != "$remote_head" ]; then
            say "  - $name: no release tags; default branch behind remote"
            ALL_CURRENT=0
        else
            say "  - $name: up to date on default branch ($cur_short)"
        fi
    fi
done

if [ "$ALL_CURRENT" = "1" ]; then
    bar
    say "  Everything is already on the newest release."
    if ask_yn "Do you want to update (fetch & reinstall) to the newest release anyway?"; then
        say "  Re-running the update."
    else
        say "  Nothing to do. Exiting."
        exit 0
    fi
else
    say "  Some repos have updates available — proceeding."
fi

# Questions answered. Everything below needs root, so re-elevate through ONE
# pkexec (a single password prompt) and run the whole privileged phase as root
# with no further sudo/pkexec at all. "--continue" makes the root process skip
# the questions and carries the original invoker for the final chown-back.
if [ "$(id -u)" != "0" ]; then
    bar
    accent "Requesting root privileges through pkexec (enter your password)..."
    exec pkexec /usr/bin/env bash "$(realpath "$0")" --continue "$START_USER"
    accent "Error: pkexec elevation failed."
    exit 1
fi

else
accent "Running the privileged (root) phase..."
fi

# The pkexec "--continue" relaunch is a fresh process, so re-detect the
# distro here (Phase A already did this and DISTRO is set on direct root runs).
if [ -z "${DISTRO:-}" ]; then
    if command -v pacman &>/dev/null; then
        DISTRO="arch"
    elif command -v dnf &>/dev/null; then
        DISTRO="fedora"
    fi
fi

if [ "$DISTRO" = "arch" ]; then
    DEPS=("${ARCH_DEPS[@]}")
else
    DEPS=("${FEDORA_DEPS[@]}")
    # ghostty is in COPR; enable it if not already
    if ! dnf copr list --enabled 2>/dev/null | grep -q ghostty; then
        accent "Enabling the ghostty COPR..."
        dnf copr enable -y scottames/ghostty
    fi
    # ffmpeg-devel is not in the Fedora repos (packages.fedoraproject.org);
    # it lives in RPM Fusion free. Enable it before installing deps.
    if ! dnf repolist --enabled 2>/dev/null | grep -q rpmfusion-free; then
        accent "Enabling RPM Fusion free (needed for ffmpeg-devel)..."
        dnf install -y "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm" \
            || accent "Warning: could not enable RPM Fusion free; otter-rec may fail to build"
    fi
fi

# Arch's ffmpeg ships libavutil/hwcontext_cuda.h, which #includes <cuda.h>
# unconditionally. otter-rec's zig translate-c maps that header AND its
# gpu_bridge.c is compiled for real, so both need a cuda.h present even though
# otter-rec dlopens libcuda.so at runtime and never links CUDA. KICKS in only
# when the path otter-rec's build.zig passes (-I /usr/local/cuda/include) has no
# real CUDA install: we (re)write the stub when it is missing or still carries
# our "CUDA_VERSION 0" marker, so an actual Vulkan/CUDA toolkit header is never
# overwritten. Mirrors just enough of the driver API for gpu_bridge.c to parse
# (compile-only; layout/values are irrelevant at runtime). Each stub header is
# created independently (the outer check must not gate both): once cuda.h
# exists, cudaGL.h still needs to be created on later runs.
if [ "$DISTRO" = "arch" ]; then
    mkdir -p /usr/local/cuda/include || true
    if [ ! -e /usr/local/cuda/include/cuda.h ] || \
        grep -q '^#define CUDA_VERSION 0$' /usr/local/cuda/include/cuda.h; then
        tee /usr/local/cuda/include/cuda.h >/dev/null <<'EOF'
#ifndef CUDA_H
#define CUDA_H
#define CUDA_VERSION 0
#define CUDAAPI

typedef enum CUresult_enum {
    CUDA_SUCCESS = 0,
} CUresult;

typedef struct CUctx_st *CUcontext;
typedef struct CUstream_st *CUstream;
typedef struct CUarray_st *CUarray;
typedef struct CUgraphicsResource_st *CUgraphicsResource;
typedef void *CUdeviceptr;

typedef enum CUmemorytype_enum {
    CU_MEMORYTYPE_HOST = 1,
    CU_MEMORYTYPE_DEVICE = 2,
    CU_MEMORYTYPE_ARRAY = 3,
    CU_MEMORYTYPE_UNIFIED = 4,
} CUmemorytype;

typedef enum CUgraphicsRegisterFlags_enum {
    CU_GRAPHICS_REGISTER_FLAGS_NONE = 0x0,
} CUgraphicsRegisterFlags;

typedef struct CUDA_MEMCPY2D_st {
    unsigned int srcXInBytes;
    unsigned int srcY;
    CUmemorytype srcMemoryType;
    const void *srcHost;
    CUdeviceptr srcDevice;
    CUarray srcArray;
    unsigned int srcPitch;
    unsigned int dstXInBytes;
    unsigned int dstY;
    CUmemorytype dstMemoryType;
    void *dstHost;
    CUdeviceptr dstDevice;
    CUarray dstArray;
    unsigned int dstPitch;
    unsigned int WidthInBytes;
    unsigned int Height;
} CUDA_MEMCPY2D;
#endif
EOF
    fi
    # otter-rec's gpu_bridge.h includes <cudaGL.h> after <cuda.h>; it uses no
    # CUDA-GL symbols, so an empty header satisfies the include.
    if [ ! -e /usr/local/cuda/include/cudaGL.h ]; then
        tee /usr/local/cuda/include/cudaGL.h >/dev/null <<'EOF'
#ifndef CUDAGL_H
#define CUDAGL_H
#endif
EOF
    fi
fi

bar
accent "Installing system dependencies..."
say "  Installing as root: ${DEPS[*]}"
if [ "$DISTRO" = "arch" ]; then
    pacman -S --needed --noconfirm "${DEPS[@]}" \
        || accent "Warning: failed to install some deps"
else
    dnf install -y "${DEPS[@]}" \
        || accent "Warning: failed to install some deps"
fi

mkdir -p "$ROOT_DIR"

bar
accent "Cloning / updating all repos ($((${#REPOS[@]})) repos)..."
for name in "${REPOS[@]}"; do
    dir="$ROOT_DIR/$name"

    if [ -d "$dir/.git" ]; then
        accent "  $name: fetching..."
        git -C "$dir" fetch --quiet --tags || accent "Warning: git fetch failed for $name"
    else
        accent "  $name: cloning..."
        git -C "$ROOT_DIR" clone --quiet "$BASE_URL/$name" || accent "Warning: git clone failed for $name"
    fi

    repo_tag="$(git ls-remote --tags --refs "$BASE_URL/$name" 2>/dev/null \
        | grep -oP 'refs/tags/\Kv[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1 \
        || true)"
    if [ -n "$repo_tag" ]; then
        accent "  $name: checking out $repo_tag"
        git -C "$dir" checkout --quiet "$repo_tag" \
            || accent "Warning: git checkout $repo_tag failed for $name"
    else
        accent "  $name: no release tags, staying on default branch"
    fi
done

bar

# otter-render resolves fonts from /usr/share/fonts/otter-shell (its
# font/resolve.zig "known fonts": IoskeleyMonoNerdFont-Regular.ttf,
# SymbolsNerdFontMono-Regular.ttf, Lilex-Medium.ttf, Fira Code..., DejaVu...)
# and falls back to fontconfig by family name (e.g. 'Inter'). The TTFs ship in
# the otter-render tree itself; install them system-wide so every app finds its
# fonts. 'Inter' comes from the distro package (added to DEPS above).
if [ -d "$ROOT_DIR/otter-render/fonts" ]; then
    mkdir -p /usr/share/fonts/otter-shell
    cp "$ROOT_DIR"/otter-render/fonts/*.ttf /usr/share/fonts/otter-shell/ 2>/dev/null \
        && accent "--- installed otter-shell fonts ---"
    fc-cache -f /usr/share/fonts/otter-shell >/dev/null 2>&1 || true
fi

# otter-assist's daemon loads its GGUF from /usr/share/otter-shell/models/assist/
# (otter-assist/src/main.zig: installed_model_file). The model ships inside the
# repo checkout (src/models/otter-assistant-trained-lfm2.5-2.6b-v2-userservice/
# final/LFM2.5-2.6B.IQ4_XS.gguf, ~1.5GB) but build.zig does not install it, so
# the daemon fails with ModelFileMissing. Copy it under the exact expected
# name once. If the source filename changes in a future tag, this no-ops and
# prints a hint.
ASSIST_MODEL_SRC="$ROOT_DIR/otter-assist/src/models/otter-assistant-trained-lfm2.5-2.6b-v2-userservice/final/LFM2.5-2.6B.IQ4_XS.gguf"
ASSIST_MODEL_DST="/usr/share/otter-shell/models/assist/otter-assist-LFM2.5-2.6B-v2-userservice-IQ4_XS.gguf"
if [ -e "$ASSIST_MODEL_DST" ]; then
    :
elif [ -s "$ASSIST_MODEL_SRC" ]; then
    mkdir -p /usr/share/otter-shell/models/assist
    cp "$ASSIST_MODEL_SRC" "$ASSIST_MODEL_DST" \
        && accent "--- installed otter-assist model ---"
else
    accent "Warning: otter-assist GGUF not found at expected source path ($ASSIST_MODEL_SRC); update update-all.sh for the new tag"
fi

bar

# otter-examples / otter-hypr are the ONLY repos that declare inter-otter deps
# via `.path` (workspace siblings). Every sibling package (otter-ui, -theme,
# -wayland, ...) instead declares the SAME deps as git+ URL deps from
# git.pika-os.com. When one app reaches package A through BOTH mechanisms, stock
# Zig 0.16 materialises two A instances whose identical generated
# addOptions()/translate-c bytes collapse onto a single cache file ->
# "file exists in modules 'X' and 'X0'". Rewriting these two manifests to
# URL-only deps (exactly how every other app resolves them) gives each package
# a single instance. Idempotent: once converted the manifest no longer matches
# the `.path = "..` guard below. Hashes are taken from the other apps' zons.
for name in otter-examples otter-hypr; do
    zon="$ROOT_DIR/$name/build.zig.zon"
    if [ -f "$zon" ] && grep -qE '\.path[[:space:]]*=[[:space:]]*"\.\./' "$zon"; then
        accent "--- $name: converting inter-otter deps from .path to git+ URL (Zig 0.16 dual-instance workaround) ---"
        if [ "$name" = otter-examples ]; then
            cat > "$zon" <<'EOF'
.{
    .name = .otter_examples,
    .version = "0.0.1",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .otter_utils = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-utils.git#v0.11.113", .hash = "otter_utils-0.11.113-DYWsu9jtAQBc8uVLY0lBK9vz9cb32DEevGzqJI1NovR3" },
        .otter_geo = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-geo.git#v0.11.113", .hash = "otter_geo-0.11.113-_BK9GXyNAABqne81f1xnVLbDV9ug7j_W-1xsXSgfo_N4" },
        .otter_render = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-render.git#v0.11.113", .hash = "otter_render-0.11.113-nsNKUoHOeQDISd6HPqGCXY8MNOcPSyojHP4ZLX97c3_l" },
        .otter_theme = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-theme.git#v0.11.113", .hash = "otter_theme-0.11.113-YqawRu73AAB8EgkyH4h4ZfJu87xZcxHG6WVUCVsZ6Pjc" },
        .otter_wayland = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-wayland.git#v0.11.113", .hash = "otter_wayland-0.11.113-BgbeyABLFwD8BCk4fL6Y8N-NfEwYFIpZsRjugIRjHSKf" },
        .otter_ui = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-ui.git#v0.11.113", .hash = "otter_ui-0.11.113-dHO2H1Z5UQCac41lJUGCI1qVpl34StrPfghAYyFac5fY" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "assets", "README.md", "docs", "testdata", "tools" },
}
EOF
        else
            cat > "$zon" <<'EOF'
.{
    .name = .otter_hypr,
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .otter_geo = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-geo.git#v0.11.113", .hash = "otter_geo-0.11.113-_BK9GXyNAABqne81f1xnVLbDV9ug7j_W-1xsXSgfo_N4" },
        .otter_utils = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-utils.git#v0.11.113", .hash = "otter_utils-0.11.113-DYWsu9jtAQBc8uVLY0lBK9vz9cb32DEevGzqJI1NovR3" },
        .otter_render = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-render.git#v0.11.113", .hash = "otter_render-0.11.113-nsNKUoHOeQDISd6HPqGCXY8MNOcPSyojHP4ZLX97c3_l" },
        .otter_wayland = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-wayland.git#v0.11.113", .hash = "otter_wayland-0.11.113-BgbeyABLFwD8BCk4fL6Y8N-NfEwYFIpZsRjugIRjHSKf" },
        .otter_conf = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-conf.git#v0.11.113", .hash = "otter_conf-1.11.113-d7vdxJJ_AgDZi3NAK_z2EFXUJv6RyAueqiMsQrJzAu6E" },
        .otter_ui = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-ui.git#v0.11.113", .hash = "otter_ui-0.11.113-dHO2H1Z5UQCac41lJUGCI1qVpl34StrPfghAYyFac5fY" },
        .otter_theme = .{ .url = "git+https://git.pika-os.com/otter-shell/otter-theme.git#v0.11.113", .hash = "otter_theme-0.11.113-YqawRu73AAB8EgkyH4h4ZfJu87xZcxHG6WVUCVsZ6Pjc" },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src", "lua", "examples", "tests", "README.md" },
}
EOF
        fi
    fi
    # Zig 0.16 validates build.zig.zon's .fingerprint against the RESOLVED
    # dependency graph (for git+ URL deps that resolution can vary between
    # fetches), and errors when the field is absent or stale. We therefore let
    # zig name the suggested fingerprint, bake it in, and re-fetch so the real
    # build below has a manifest that matches this host's resolution.
    if [ -f "$zon" ]; then
        out="$( (cd "$ROOT_DIR/$name" && zig build --fetch 2>&1) || true )"
        fp="$(printf '%s\n' "$out" | grep -oE 'suggested value: 0x[0-9a-f]+' | head -1 | awk '{print $NF}')"
        if [ -n "$fp" ]; then
            accent "--- $name: baking zig-suggested package fingerprint $fp ---"
            if grep -q '^    \.fingerprint = ' "$zon"; then
                sed -i "s/^    \.fingerprint = .*/    .fingerprint = $fp,/" "$zon"
            else
                sed -i "/^    \.version = /a\    .fingerprint = $fp," "$zon"
            fi
            (cd "$ROOT_DIR/$name" && zig build --fetch >/dev/null 2>&1 || accent "Warning: $name zon still failing after fingerprint fix")
        fi
    fi
done

# otter-first-setup / otter-welcome build otter_pkg's vendored aptc shim (cmake;
# pkg_check_modules REQUIRED apt-pkg). Arch's apt ships RemoveCaches() but not
# RemoveCacheLeftovers(), which the shim calls in aptc_update(). Zig extracts the
# fetched otter_pkg package under <app>/zig-pkg right before the build; patch the
# extracted source so the update fallback always fully rebuilds caches. On
# Debian-family hosts does nothing (the method exists there).
for name in otter-first-setup otter-welcome; do
    dir="$ROOT_DIR/$name"
    if [ ! -f "$dir/build.zig.zon" ]; then
        continue
    fi
    (cd "$dir" && zig build --fetch >/dev/null 2>&1 || true)
    while IFS= read -r ac; do
        if grep -q 'RemoveCacheLeftovers' "$ac"; then
            accent "--- $name: patching aptc shim RemoveCacheLeftovers -> RemoveCaches ---"
            sed -i 's/pkgCacheFile::RemoveCacheLeftovers();/pkgCacheFile::RemoveCaches();/' "$ac"
        fi
    done < <(find "$dir/zig-pkg" -path '*/vendor/apt-dpkg-libs/shim/src/acquire.cc' 2>/dev/null)
done

bar
accent "=== Building & installing ==="

# savannah note: the freetype Zig package downloads its upstream
# source tarball from download.savannah.gnu.org, which is frequently down
# (502/504). The SourceForge mirror serves a byte-identical file, and since
# zig caches fetched packages by content hash, caching the mirrored file makes
# the pinned savannah URL resolve from cache. See preseed_freetype below.
mirror_url() {
    local url="$1" path ver
    case "$url" in
        https://download.savannah.gnu.org/releases/freetype/freetype-*.tar.xz)
            path="${url##*/}"
            ver="$(printf '%s' "$path" | sed -E 's/^freetype-([0-9.]+)\.tar\.xz$/\1/')"
            if [ -n "$ver" ]; then
                echo "https://sourceforge.net/projects/freetype/files/freetype2/${ver}/freetype-${ver}.tar.xz/download"
            else
                echo "$url"
            fi
            ;;
        *) echo "$url" ;;
    esac
}

# Zig only materialises "lazy" dependencies when already in the package cache;
# otherwise b.lazyDependency() returns null and the otter build.zig files panic
# (freetype.?, harfbuzz.?, ...). The fetches below prime the cache the
# build will use. Everything is run as root so the packages land in the same
# cache (/root/.cache/zig) that the root build uses.
FETCHED_ATTRS=""

fetch_dep() {
    # fetch a single dependency URL into zig's cache (helps skip savannah by
    # mirroring its freetype source tarball from the identical SourceForge
    # copy; zig caches by content hash, so the pinned URL resolves from cache).
    local dir="$1" url="$2" sf base file
    case "$url" in
        https://download.savannah.gnu.org/releases/freetype/*.tar.xz)
            sf="$(mirror_url "$url")"
            base="$(basename "$url")"
            file="/tmp/opencode-otter-${base}"
            if [ ! -f "$file" ] && ! timeout 120 curl -fsSL --retry 3 -o "$file" "$sf"; then
                accent "Warning: could not mirror $url" >&2
                return 0
            fi
            (cd "$dir" && zig fetch "file://$file" >/dev/null 2>&1) || true
            ;;
        *)
            (cd "$dir" && zig fetch "$url" >/dev/null 2>&1) || true
            ;;
    esac
}

crawl_deps() {
    # Recursively fetch the URL deps of $dir/build.zig.zon AND every package
    # already extracted under $dir/.zig-cache/zig-pkg/ (those are transitive
    # deps like otter_render's freetype/harfbuzz/zlib/libpng git packages).
    # Iterate to a fixpoint because fetching one package may reveal more.
    local dir="$1" url added
    while :; do
        added=0
        while IFS= read -r url; do
            [ -z "$url" ] && continue
            case "$FETCHED_ATTRS" in
                *"|$url|"*) continue ;;
            esac
            FETCHED_ATTRS="$FETCHED_ATTRS|$url|"
            fetch_dep "$dir" "$url"
            added=1
        done < <({ cat "$dir/build.zig.zon" 2>/dev/null;
                    for zon in "$dir/.zig-cache/zig-pkg"/*/build.zig.zon; do
                        [ -f "$zon" ] && cat "$zon"
                    done; } \
                  | grep -oE '\.url = "[^"]+"' \
                  | sed -E 's/^\.url = "//; s/"$//' || true)
        [ "$added" -eq 0 ] && break
    done
}

# Pre-seed the freetype source tarball (savannah mirror) up front so even the
# first freetype-dependent build resolves it from the content cache.
preseed_freetype() {
    local ver="" pkgfile tmp
    pkgfile="$(ls /root/.cache/zig/p/freetype-[0-9]*.tar.gz 2>/dev/null | head -1 || true)"
    if [ -z "$pkgfile" ]; then
        pkgfile="$(ls "$HOME/.cache/zig/p/freetype-"*.tar.gz 2>/dev/null | head -1 || true)"
    fi
    if [ -n "$pkgfile" ]; then
        ver="$(basename "$pkgfile" | sed -E 's/^freetype-([0-9.]+)-.*$/\1/' || true)"
    fi
    [ -n "$ver" ] || ver="2.14.3"
    tmp="/tmp/opencode-otter-freetype-${ver}.tar.xz"
    fetch_dep "$ROOT_DIR/otter-conf" "https://download.savannah.gnu.org/releases/freetype/freetype-${ver}.tar.xz"
    [ -f "$tmp" ] && say "Pre-seeded freetype ${ver} source tarball (savannah mirror workaround)"
}

preseed_freetype || true

for name in "${REPOS[@]}"; do
    dir="$ROOT_DIR/$name"

    if [ ! -f "$dir/build.zig" ]; then
        accent "--- $name: skipped (no build.zig) ---"
        continue
    fi

    crawl_deps "$dir" || true

    accent "--- $name: building & installing ---"
    (cd "$dir" && zig build -Doptimize=ReleaseFast -Dcpu=x86_64_v4 --prefix /usr install) || accent "Warning: build/install failed for $name"
done

bar
say "Done."

# The build loop ran as root (the pkexec phase), leaving root-owned
# .zig-cache/zig-pkg inside the clone tree. Re-own the tree so the user can
# build incrementally. When Otter_INVOKER is root (fully-automated runs) the
# tree stays root-owned.
if [ "$(id -u)" != "$START_UID" ] && [ -n "$OTTER_INVOKER" ] && [ "$OTTER_INVOKER" != "root" ]; then
    chown -R "$OTTER_INVOKER" "$ROOT_DIR" 2>/dev/null || true
fi
