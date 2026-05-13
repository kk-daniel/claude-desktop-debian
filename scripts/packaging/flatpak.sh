#!/usr/bin/env bash

# Arguments passed from the main script
version="$1"
architecture="$2"
work_dir="$3"           # The top-level build directory (e.g., ./build)
app_staging_dir="$4"    # Directory containing the prepared app files
package_name="$5"
# $6 maintainer, $7 description (kept for parameter compatibility with deb)
description="${7:-Claude Desktop for Linux}"

echo '--- Starting Flatpak Build ---'
echo "Version: $version"
echo "Architecture: $architecture"
echo "Work Directory: $work_dir"
echo "App Staging Directory: $app_staging_dir"
echo "Package Name: $package_name"

# Flatpak app id (reverse-DNS). Flathub validation requires the .desktop,
# metainfo, and icon basenames to match this id.
flatpak_id='ai.claude.Claude'
flatpak_branch='stable'
runtime_version='25.08'

# Map our architecture names to Flatpak's
case "$architecture" in
	amd64) flatpak_arch='x86_64' ;;
	arm64) flatpak_arch='aarch64' ;;
	*)
		echo "Unsupported architecture for Flatpak: $architecture" >&2
		exit 1
		;;
esac

# Layout under $work_dir/flatpak:
#   sources/   — files baked into /app at build time (manifest 'dir' source)
#   build/     — flatpak-builder workdir (intermediate)
#   repo/      — OSTree repo emitted by flatpak-builder
#   state/     — flatpak-builder state cache
#   manifest.yml
flatpak_dir="$work_dir/flatpak"
sources_dir="$flatpak_dir/sources"
build_dir="$flatpak_dir/build"
repo_dir="$flatpak_dir/repo"
state_dir="$flatpak_dir/state"
manifest_path="$flatpak_dir/manifest.yml"

rm -rf "$flatpak_dir"
mkdir -p "$sources_dir/app" "$sources_dir/icons" || exit 1

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Stage application tree (mirrors AppImage layout) ---
echo "Staging application tree from $app_staging_dir..."
if [[ -d $app_staging_dir/node_modules ]]; then
	cp -a "$app_staging_dir/node_modules" "$sources_dir/app/" || exit 1
fi

resources_subdir='node_modules/electron/dist/resources'
mkdir -p "$sources_dir/app/$resources_subdir" || exit 1
if [[ -f $app_staging_dir/app.asar ]]; then
	cp -a "$app_staging_dir/app.asar" "$sources_dir/app/$resources_subdir/" \
		|| exit 1
fi
if [[ -d $app_staging_dir/app.asar.unpacked ]]; then
	cp -a "$app_staging_dir/app.asar.unpacked" \
		"$sources_dir/app/$resources_subdir/" || exit 1
fi

# Sanity check: Electron must be bundled, the launcher exec's it directly.
bundled_electron="$sources_dir/app/node_modules/electron/dist/electron"
if [[ ! -x $bundled_electron ]]; then
	echo "Electron executable missing in staging tree: $bundled_electron" >&2
	exit 1
fi

# Shared launcher library + doctor (sourced at runtime from /app/lib/...).
cp "$(dirname "$script_dir")/launcher-common.sh" "$sources_dir/app/" || exit 1
cp "$(dirname "$script_dir")/doctor.sh" "$sources_dir/app/" || exit 1

# --- Stage icons (numbered by size, like deb.sh) ---
declare -A icon_files=(
	[16]=13 [24]=11 [32]=10 [48]=8 [64]=7 [256]=6
)
for size in "${!icon_files[@]}"; do
	src="$work_dir/claude_${icon_files[$size]}_${size}x${size}x32.png"
	if [[ -f $src ]]; then
		cp "$src" "$sources_dir/icons/${size}.png" || exit 1
	else
		echo "Warning: missing ${size}x${size} icon at $src"
	fi
done

# --- Generate launcher script ---
# Runs inside the Flatpak sandbox. /app paths are fixed by the runtime.
# Exec'd via /app/bin/zypak-wrapper.sh (provided by
# org.electronjs.Electron2.BaseApp): zypak intercepts Chromium's
# SUID-sandbox calls and translates them to namespace sandboxing,
# which is the standard Electron-in-Flatpak pattern. Passing
# --no-sandbox here would defeat zypak, so we use 'flatpak' mode in
# build_electron_args (which omits --no-sandbox).
cat > "$sources_dir/claude-desktop" << 'LAUNCHER_EOF'
#!/usr/bin/env bash

app_dir='/app/lib/claude-desktop'

# Source shared launcher library
# shellcheck source=/dev/null
source "$app_dir/launcher-common.sh"

if [[ "${1:-}" == '--doctor' ]]; then
	electron_path="$app_dir/node_modules/electron/dist/electron"
	run_doctor "$electron_path"
	exit $?
fi

setup_logging || exit 1
setup_electron_env
cleanup_orphaned_cowork_daemon
cleanup_stale_lock
cleanup_stale_cowork_socket

detect_display_backend

log_message '--- Claude Desktop Flatpak Start ---'
log_message "Timestamp: $(date)"
log_message "Arguments: $*"
log_message "APPDIR: $app_dir"
log_session_env

electron_exec="$app_dir/node_modules/electron/dist/electron"
app_path="$app_dir/node_modules/electron/dist/resources/app.asar"

# 'flatpak' mode omits --no-sandbox so zypak can do its job.
build_electron_args 'flatpak'
electron_args+=("$app_path")

cd "$HOME" || exit 1

zypak='/app/bin/zypak-wrapper.sh'
log_message "Executing: $zypak $electron_exec ${electron_args[*]} $*"
exec "$zypak" "$electron_exec" "${electron_args[@]}" "$@" \
	>> "$log_file" 2>&1
LAUNCHER_EOF
chmod +x "$sources_dir/claude-desktop" || exit 1

# --- Generate .desktop entry ---
# Filename + Icon must match $flatpak_id for Flathub validation.
cat > "$sources_dir/${flatpak_id}.desktop" << EOF
[Desktop Entry]
Name=Claude
Comment=$description
Exec=claude-desktop %u
Icon=$flatpak_id
Type=Application
Terminal=false
Categories=Network;Utility;
MimeType=x-scheme-handler/claude;
StartupWMClass=Claude
EOF

# --- Generate URL-handler .desktop entry ---
# Some DEs route x-scheme-handler/claude to the entry with the most
# specific MimeType match; a dedicated NoDisplay=true handler gives
# claude:// deep links a clean target without showing a duplicate
# launcher in the menu.
cat > "$sources_dir/${flatpak_id}-url-handler.desktop" << EOF
[Desktop Entry]
Name=Claude URL Handler
Comment=Handle Claude login links
Exec=claude-desktop %u
Icon=$flatpak_id
Type=Application
Terminal=false
NoDisplay=true
MimeType=x-scheme-handler/claude;
EOF

# --- Generate AppStream metainfo ---
# Flathub's appstream-validator rejects appdata.xml in /app/share/metainfo;
# the modern path is .metainfo.xml. Keep id, license, and release date
# fields aligned with the manifest.
cat > "$sources_dir/${flatpak_id}.metainfo.xml" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<component type="desktop-application">
  <id>${flatpak_id}</id>
  <metadata_license>CC0-1.0</metadata_license>
  <project_license>MIT</project_license>
  <developer id="ai.claude">
    <name>Anthropic</name>
  </developer>

  <name>Claude</name>
  <summary>Desktop client for Claude AI</summary>

  <description>
    <p>
      Provides a desktop experience for interacting with Claude AI,
      packaged as an unofficial Linux build of the Electron application.
    </p>
  </description>

  <launchable type="desktop-id">${flatpak_id}.desktop</launchable>
  <icon type="stock">${flatpak_id}</icon>
  <url type="homepage">https://github.com/aaddrick/claude-desktop-debian</url>
  <provides>
    <binary>claude-desktop</binary>
  </provides>

  <categories>
    <category>Network</category>
    <category>Utility</category>
  </categories>

  <content_rating type="oars-1.1" />

  <releases>
    <release version="$version" date="$(date +%Y-%m-%d)">
      <description>
        <p>Version $version.</p>
      </description>
    </release>
  </releases>
</component>
EOF

# --- Generate install script invoked by manifest's build-commands ---
# Splitting into a script keeps the manifest readable and makes the icon
# loop trivial; flatpak-builder simple buildsystem runs each command via
# /bin/sh -c, but the multi-arg cp + loop is clearer as a script.
cat > "$sources_dir/install.sh" << EOF
#!/bin/sh
set -eu

install -d /app/lib/claude-desktop
cp -a app/. /app/lib/claude-desktop/

# Symlink node SDK extension binaries onto PATH. The extension is
# pulled at user-install time (declared in manifest add-extensions)
# and mounted at /app/lib/sdk/node24/. /app/bin is on PATH by default
# while /app/lib/sdk/node24/bin is not, so we bridge via these
# symlinks. Targets are dangling at build time (mount only happens at
# runtime) — that is intentional and resolves once the app runs.
install -d /app/bin
for bin in node npm npx corepack; do
	ln -sf /app/lib/sdk/node24/bin/\$bin /app/bin/\$bin
done

install -Dm755 claude-desktop /app/bin/claude-desktop

install -Dm644 ${flatpak_id}.desktop \\
	/app/share/applications/${flatpak_id}.desktop
install -Dm644 ${flatpak_id}-url-handler.desktop \\
	/app/share/applications/${flatpak_id}-url-handler.desktop
install -Dm644 ${flatpak_id}.metainfo.xml \\
	/app/share/metainfo/${flatpak_id}.metainfo.xml

for size in 16 24 32 48 64 256; do
	src="icons/\${size}.png"
	[ -f "\$src" ] || continue
	install -Dm644 "\$src" \\
		"/app/share/icons/hicolor/\${size}x\${size}/apps/${flatpak_id}.png"
done

# Drop chrome-sandbox: zypak provides namespace sandboxing via
# CHROME_DEVEL_SANDBOX, and Chromium aborts at startup if it sees a
# non-setuid chrome-sandbox sitting next to the binary.
sandbox=/app/lib/claude-desktop/node_modules/electron/dist/chrome-sandbox
[ -f "\$sandbox" ] && rm -f "\$sandbox"
EOF
chmod +x "$sources_dir/install.sh" || exit 1

# --- Write manifest ---
# 'dir' source path is relative to the manifest. base/runtime/sdk pinned
# to runtime_version so a Flathub runtime EOL doesn't break us silently.
cat > "$manifest_path" << EOF
id: ${flatpak_id}
runtime: org.freedesktop.Sdk
runtime-version: '${runtime_version}'
sdk: org.freedesktop.Sdk
base: org.electronjs.Electron2.BaseApp
base-version: '${runtime_version}'
command: claude-desktop
tags: [proprietary]
separate-locales: false
# Declare the node24 SDK extension so flatpak pulls it on user install
# and mounts it at /usr/lib/sdk/node24 at runtime. Required by the
# /app/bin/{node,npm,npx,corepack} symlinks created in install.sh; MCP
# servers spawned by Claude need node in PATH. The Sdk runtime alone
# only declares the extension *point* — it does not auto-install the
# extension content.
add-extensions:
  org.freedesktop.Sdk.Extension.node24:
    version: '${runtime_version}'
    directory: lib/sdk/node24
    add-ld-path: lib
    no-autodownload: false
finish-args:
  - --require-version=0.10.3
  - --share=network
  - --share=ipc
  - --socket=wayland
  - --socket=fallback-x11
  - --device=dri
  - --env=LD_LIBRARY_PATH=/app/lib
  - --env=XCURSOR_PATH=/run/host/user-share/icons:/run/host/share/icons
  # Routes detect_display_backend in launcher-common.sh into the
  # native-Wayland branch. The deb/AppImage default of "X11 via
  # XWayland for global hotkeys" would force --ozone-platform=x11,
  # which has no X server reachable inside the sandbox
  # (--socket=fallback-x11 is inert when Wayland is present) and
  # SIGSEGVs Electron during Ozone init. Users who want XWayland
  # can grant --socket=x11 + unset this via 'flatpak override'.
  - --env=CLAUDE_USE_WAYLAND=1
  - --talk-name=org.freedesktop.Notifications
  # Notification-area / tray (StatusNotifierItem on KDE & GNOME-via-
  # extension, AppIndicator on Ubuntu/Cinnamon). Without these the SNI
  # registration silently fails under Flatpak and no icon appears.
  # Modern Electron registers the item by object path on its existing
  # bus connection, so we don't need to --own-name the per-PID SNI
  # bus name.
  - --talk-name=org.kde.StatusNotifierWatcher
  - --talk-name=com.canonical.AppMenu.Registrar
  - --talk-name=com.canonical.AppMenu.Registrar.*
  - --talk-name=com.canonical.indicator.application
  # libappindicator claims a per-PID bus name under
  # com.canonical.indicator.application; without ownership, the
  # registration call to the watcher silently no-ops.
  - --own-name=com.canonical.indicator.application.*
modules:
  - name: claude-desktop
    buildsystem: simple
    build-commands:
      - sh ./install.sh
    sources:
      - type: dir
        path: ./sources
EOF

echo "Manifest written to $manifest_path"

# --- Verify build tools ---
if ! command -v flatpak-builder &> /dev/null; then
	echo 'Error: flatpak-builder not found in PATH.' >&2
	echo "Install with: sudo apt install flatpak-builder (Debian/Ubuntu)" \
		>&2
	echo "          or: sudo dnf install flatpak-builder (Fedora)" >&2
	exit 1
fi
if ! command -v flatpak &> /dev/null; then
	echo 'Error: flatpak not found in PATH.' >&2
	exit 1
fi

# --- Ensure flathub remote and required runtimes are present ---
# --user keeps the build self-contained per builder; system-wide remotes
# would need sudo. --if-not-exists is idempotent across re-runs.
echo 'Configuring flathub remote (user)...'
flatpak remote-add --user --if-not-exists flathub \
	https://flathub.org/repo/flathub.flatpakrepo || exit 1

echo 'Installing required runtimes (idempotent)...'
# Sdk is the manifest's runtime AND its build sdk, so Platform is not
# needed on the build host (Sdk is a superset). Electron2.BaseApp is
# the manifest's base. Extension content is pulled by users at install
# time via the manifest's add-extensions declaration, not here.
flatpak install --user -y --noninteractive flathub \
	"org.freedesktop.Sdk//${runtime_version}" \
	"org.electronjs.Electron2.BaseApp//${runtime_version}" || {
	echo 'Failed to install Flatpak runtimes' >&2
	exit 1
}

# --- Build ---
echo "Running flatpak-builder for ${flatpak_arch}..."
mkdir -p "$state_dir" || exit 1
if ! flatpak-builder \
	--arch="$flatpak_arch" \
	--repo="$repo_dir" \
	--state-dir="$state_dir" \
	--default-branch="$flatpak_branch" \
	--disable-rofiles-fuse \
	--force-clean \
	"$build_dir" \
	"$manifest_path"; then
	echo 'flatpak-builder failed' >&2
	exit 1
fi

# --- Bundle into single .flatpak file ---
output_filename="${package_name}-${version}-${architecture}.flatpak"
output_path="$work_dir/$output_filename"

echo "Bundling to $output_path..."
if ! flatpak build-bundle \
	--arch="$flatpak_arch" \
	"$repo_dir" \
	"$output_path" \
	"$flatpak_id" \
	"$flatpak_branch"; then
	echo 'flatpak build-bundle failed' >&2
	exit 1
fi

echo "Flatpak bundle built successfully: $output_path"
echo '--- Flatpak Build Finished ---'

exit 0
