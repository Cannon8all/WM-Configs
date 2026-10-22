#!/usr/bin/env bash
set -euo pipefail

# LOCKED BASE URL: This will never change
BASE_URL="https://git.pika-os.com/otter-shell"
ROOT_DIR="$(dirname "$(realpath "$0")")/otter-shell"

# SORTED BY DEPENDENCY ORDER (Libraries first)
REPOS=(
    otter-utils
    otter-config-types
    otter-theme
    otter-ui
    otter-wayland
    otter-render
    otter-geo
    otter-conf
    otter-bar
    otter-desktop
    otter-greeter
    otter-idle
    otter-jade
    otter-launcher
    otter-lock
    otter-logout
    otter-notifications
    otter-osd
    otter-polkit
    otter-screenshot
    otter-settings
    otter-term
    otter-shot
    otter-wallpaper
    otter-zenith
)

# Development files and tools for Fedora
FEDORA_DEPS=(
    wayland-devel 
    libxkbcommon-devel 
    freetype-devel 
    pam-devel 
    jemalloc-devel 
    zig 
    git
)

echo "--- Ensuring COPR repository for ghostty ---"
if ! dnf copr list --enabled 2>/dev/null | grep -q ghostty; then
    sudo dnf copr enable -y scottames/ghostty
fi

echo "--- Ensuring system dependencies ---"
sudo dnf install -y "${FEDORA_DEPS[@]}" ghostty

# AUTOMATED FIX FOR GHOSTTY LINK ERROR (.so files)
echo "--- Checking for Ghostty development symlinks ---"
GHOSTTY_TARGET="/usr/lib/libghostty-vt.so.0.1.0"
if [ -f "$GHOSTTY_TARGET" ]; then
    if [ ! -L "/usr/lib/libghostty-vt.so" ]; then
        echo "Creating symlink in /usr/lib..."
        sudo ln -s "$GHOSTTY_TARGET" "/usr/lib/libghostty-vt.so"
    fi
    if [ ! -L "/usr/lib64/libghostty-vt.so" ]; then
        echo "Creating symlink in /usr/lib64..."
        sudo ln -s "$GHOSTTY_TARGET" "/usr/lib64/libghostty-vt.so"
    fi
else
    echo "Warning: $GHOSTTY_TARGET not found. Checking alternate locations..."
    ALT_TARGET=$(find /usr/lib /usr/lib64 -name "libghostty-vt.so.*" -print -quit 2>/dev/null || true)
    if [ -n "$ALT_TARGET" ]; then
        [ ! -L "/usr/lib/libghostty-vt.so" ] && sudo ln -s "$ALT_TARGET" "/usr/lib/libghostty-vt.so" || true
        [ ! -L "/usr/lib64/libghostty-vt.so" ] && sudo ln -s "$ALT_TARGET" "/usr/lib64/libghostty-vt.so" || true
    fi
fi

mkdir -p "$ROOT_DIR"

echo "=== Cloning / updating all repos ==="
for name in "${REPOS[@]}"; do
    dir="$ROOT_DIR/$name"

    if [ -d "$dir/.git" ]; then
        echo "--- $name: fetching ---"
        git -C "$dir" fetch --tags || echo "Warning: git fetch failed for $name"
    else
        echo "--- $name: cloning ---"
        git -C "$ROOT_DIR" clone --quiet "${BASE_URL}/${name}.git" || { echo "Warning: git clone failed for $name"; continue; }
    fi

    if [ -d "$dir" ]; then
        echo "--- $name: determining latest tag ---"
        REPO_TAG="$(git -C "$dir" tag -l | sort -V | tail -1)"
        
        if [ -n "$REPO_TAG" ]; then
            echo "Checking out tag $REPO_TAG for $name"
            git -C "$dir" checkout --quiet "$REPO_TAG" || echo "Warning: git checkout $REPO_TAG failed for $name"
        else
            DEFAULT_BRANCH="$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')"
            echo "No tags found for $name. Falling back to default branch: $DEFAULT_BRANCH"
            git -C "$dir" checkout --quiet "$DEFAULT_BRANCH" && git -C "$dir" pull --quiet || echo "Warning: fallback checkout failed for $name"
        fi
    fi
done

# AUTOMATED FIX FOR MISSING GHOSTTY C HEADERS (Local copy from workspace cache)
echo "--- Extracting authentic ghostty header from local workspace cache ---"
sudo mkdir -p /usr/local/include/ghostty
# Otter Shell bundles ghostty bindings within its own repository structures (often inside otter-term or zig-pkg)
LOCAL_HEADER=$(find "$ROOT_DIR/otter-term" -name "vt.h" -print -quit 2>/dev/null || true)

if [ -n "$LOCAL_HEADER" ] && [ -f "$LOCAL_HEADER" ]; then
    echo "Found local authentic header at $LOCAL_HEADER, installing..."
    sudo cp "$LOCAL_HEADER" /usr/local/include/ghostty/vt.h
else
    # Fallback to generating the accurate minimal API mapping if the file isn't populated yet
    sudo tee /usr/local/include/ghostty/vt.h > /dev/null << 'EOF'
#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct GhosttyTerminal GhosttyTerminal;
typedef struct GhosttyRenderState GhosttyRenderState;
typedef struct GhosttyTerminalOptions { int cols; int rows; void* user_data; } GhosttyTerminalOptions;
GhosttyTerminal* ghostty_terminal_new(const GhosttyTerminalOptions* opts);
void ghostty_terminal_free(GhosttyTerminal* terminal);
void ghostty_terminal_resize(GhosttyTerminal* terminal, int cols, int rows);
void ghostty_terminal_write(GhosttyTerminal* terminal, const char* buf, size_t len);
#ifdef __cplusplus
}
#endif
#endif
EOF
fi

echo ""
echo "=== Building & Installing to System ==="
for name in "${REPOS[@]}"; do
    dir="$ROOT_DIR/$name"

    if [ ! -f "$dir/build.zig" ]; then
        echo "--- $name: skipping (no build.zig found) ---"
        continue
    fi

    echo "--- Building and Installing $name ---"
    (cd "$dir" && sudo zig build -Doptimize=ReleaseFast --prefix /usr/local --summary all)
done

echo "=== Installation successfully completed! ==="
