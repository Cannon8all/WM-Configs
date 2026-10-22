#!/usr/bin/env bash
set -euo pipefail

# LOCKED BASE URL: This will never change
BASE_URL="https://git.pika-os.com/otter-shell"
ROOT_DIR="$(dirname "$(realpath "$0")")/otter-shell"

# PHASE 1: Core libraries that must be built in order first
CORE_REPOS=(
    otter-utils
    otter-config-types
    otter-theme
    otter-ui
    otter-wayland
    otter-render
    otter-geo
    otter-conf
)

# PHASE 2: Desktop components that will run simultaneously across all 32 threads
# (otter-greeter, otter-shot, and otter-screenshot removed)
APP_REPOS=(
    otter-bar otter-conf otter-config-types otter-desktop otter-geo
    otter-idle otter-jade otter-launcher otter-lock
    otter-logout otter-notifications otter-osd otter-polkit otter-render
    otter-settings otter-theme otter-ui
    otter-utils otter-wallpaper otter-wayland otter-zenith
)

# Combine both for the cloning phase
ALL_REPOS=("${CORE_REPOS[@]}" "${APP_REPOS[@]}")

# Development files and tools for Fedora
FEDORA_DEPS=(
    wayland-devel 
    libxkbcommon-devel 
    freetype-devel 
    pam-devel 
    jemalloc-devel 
    zig 
    git
    rsms-inter-fonts
)

echo "--- Refreshing sudo credentials for multi-threaded build ---"
sudo -v

echo "--- Ensuring system dependencies ---"
sudo dnf install -y "${FEDORA_DEPS[@]}"

mkdir -p "$ROOT_DIR"

echo "=== Cloning / updating all repos ==="
for name in "${ALL_REPOS[@]}"; do
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

# HELPER FUNCTION: Retries the zig build command if the compiler hits a connection drop
run_zig_build_with_retry() {
    local dir=$1
    local summary_mode=$2
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if [ $attempt -eq 1 ]; then
            echo "--- Building Component: $(basename "$dir") ---"
        else
            echo "--- Retrying Component: $(basename "$dir") (Attempt $attempt/$max_attempts) ---"
        fi
        
        if (cd "$dir" && sudo zig build -Doptimize=ReleaseFast --prefix /usr/local --summary "$summary_mode" --global-cache-dir "$dir/.zig-global-cache"); then
            return 0
        else
            echo "Warning: Build step fell through for $(basename "$dir"). Checking for network drops..."
            attempt=$((attempt + 1))
            sleep 1
        fi
    done

    echo "Error: Component $(basename "$dir") failed to compile after $max_attempts attempts."
    return 1
}

echo ""
echo "=== Building & Installing CORE Libraries (Sequential) ==="
for name in "${CORE_REPOS[@]}"; do
    dir="$ROOT_DIR/$name"
    if [ -f "$dir/build.zig" ]; then
        run_zig_build_with_retry "$dir" "all"
    fi
done

echo ""
echo "=== Building & Installing APPLICATIONS (32-Thread Unlocked Parallel Mode) ==="
for name in "${APP_REPOS[@]}"; do
    dir="$ROOT_DIR/$name"
    if [ -f "$dir/build.zig" ]; then
        echo "--- [LAUNCHED IN BACKGROUND] Compiling: $name ---"
        run_zig_build_with_retry "$dir" "none" &
    fi
done

echo ""
echo "--- Waiting for all 32 background threads to complete execution... ---"
wait

# Clean up temporary cache directories
echo "--- Cleaning up temporary build caches ---"
for name in "${ALL_REPOS[@]}"; do
    sudo rm -rf "$ROOT_DIR/$name/.zig-global-cache"
done

echo "=== All parallel builds finished! Otter Shell installation successfully completed! ==="
