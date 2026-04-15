#!/usr/bin/env bash
# build_appimage.sh — Build infinidream and package it as a self-contained AppImage.
#
# Usage:
#   cd client/client_generic/LinuxBuild
#   chmod +x build_appimage.sh
#   ./build_appimage.sh
#
# Output: infinidream-<arch>.AppImage in this directory.
#
# Requirements:
#   - All normal infinidream build dependencies (cmake, vulkan, ffmpeg, boost, etc.)
#   - curl (to download linuxdeploy / appimagetool on first run)
#   - FUSE or kernel >= 5.13 with /dev/fuse available.
#     On systems without FUSE the script sets APPIMAGE_EXTRACT_AND_RUN=1 automatically.

set -euo pipefail

ARCH="$(uname -m)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Clean AppDir unconditionally at startup.
# A failed or interrupted run leaves AppDir in an undefined state; always
# start fresh so the packaged result reflects only the current build.
# ---------------------------------------------------------------------------
rm -rf "${SCRIPT_DIR}/AppDir"
BUILD_DIR="${SCRIPT_DIR}/build"
APPDIR="${SCRIPT_DIR}/AppDir"
TOOLS_DIR="${SCRIPT_DIR}/appimage-tools"
RUNTIME_DIR="${SCRIPT_DIR}/../Runtime"

LINUXDEPLOY_BIN="linuxdeploy-${ARCH}.AppImage"
APPIMAGETOOL_BIN="appimagetool-${ARCH}.AppImage"

LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/${LINUXDEPLOY_BIN}"
# appimagetool moved from the deprecated AppImageKit repo to its own repo in 2023
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/${APPIMAGETOOL_BIN}"

OUTPUT_APPIMAGE="${SCRIPT_DIR}/infinidream-${ARCH}.AppImage"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[build_appimage] $*"; }

require_cmd() {
    command -v "$1" &>/dev/null || { echo "ERROR: '$1' not found. Please install it."; exit 1; }
}

download_tool() {
    local url="$1" dest="$2"
    if [[ ! -x "${dest}" ]]; then
        log "Downloading $(basename "${dest}") ..."
        curl -fsSL --retry 3 -o "${dest}" "${url}"
        chmod +x "${dest}"
    else
        log "$(basename "${dest}") already present, skipping download."
    fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
require_cmd cmake
require_cmd curl

# Detect whether FUSE is available; if not, fall back to extract-and-run mode.
if [[ ! -e /dev/fuse ]]; then
    log "WARNING: /dev/fuse not found — enabling APPIMAGE_EXTRACT_AND_RUN=1 for tooling."
    export APPIMAGE_EXTRACT_AND_RUN=1
fi

# ---------------------------------------------------------------------------
# Download AppImage toolchain (cached in appimage-tools/)
# ---------------------------------------------------------------------------
mkdir -p "${TOOLS_DIR}"
download_tool "${LINUXDEPLOY_URL}"  "${TOOLS_DIR}/${LINUXDEPLOY_BIN}"
download_tool "${APPIMAGETOOL_URL}" "${TOOLS_DIR}/${APPIMAGETOOL_BIN}"

APPIMAGETOOL="${TOOLS_DIR}/${APPIMAGETOOL_BIN}"

# linuxdeploy is run from an extracted directory rather than as an AppImage.
# Its bundled strip is too old to handle .relr.dyn sections (RELR relocations)
# present in all modern distro libs — it exits non-zero and aborts packaging.
# Extracting lets us swap in the system strip, which handles modern ELF.
LINUXDEPLOY_DIR="${TOOLS_DIR}/linuxdeploy-extracted"
if [[ ! -d "${LINUXDEPLOY_DIR}" ]]; then
    log "Extracting linuxdeploy (one-time setup) ..."
    pushd "${TOOLS_DIR}" > /dev/null
    "${TOOLS_DIR}/${LINUXDEPLOY_BIN}" --appimage-extract > /dev/null
    mv squashfs-root "${LINUXDEPLOY_DIR}"
    popd > /dev/null
fi
# Always sync system strip into the extracted tree so it stays current
cp "$(command -v strip)" "${LINUXDEPLOY_DIR}/usr/bin/strip"
LINUXDEPLOY="${LINUXDEPLOY_DIR}/AppRun"

# ---------------------------------------------------------------------------
# Build infinidream (Release)
# ---------------------------------------------------------------------------
log "Configuring CMake ..."
cmake -B "${BUILD_DIR}" -S "${SCRIPT_DIR}" \
    -DCMAKE_BUILD_TYPE=Release

log "Compiling ($(nproc) jobs) ..."
cmake --build "${BUILD_DIR}" -j"$(nproc)"

# ---------------------------------------------------------------------------
# Assemble AppDir
# ---------------------------------------------------------------------------
log "Assembling AppDir ..."
mkdir -p "${APPDIR}/usr/bin"
mkdir -p "${APPDIR}/usr/lib"

# Binary
cp "${BUILD_DIR}/infinidream" "${APPDIR}/usr/bin/"

# Compiled SPIR-V shaders (must sit at ./shaders/ relative to binary)
cp -r "${BUILD_DIR}/shaders" "${APPDIR}/usr/bin/"

# Runtime assets (logo, font, OSD PNGs — all go next to the binary so
# SHAREDIR="./" resolves them correctly when AppRun cd's to usr/bin/)
cp "${RUNTIME_DIR}/"*.png  "${APPDIR}/usr/bin/"
cp "${RUNTIME_DIR}/Lato-Regular.ttf" "${APPDIR}/usr/bin/"

# AppImage mandatory files
cp "${SCRIPT_DIR}/AppRun"              "${APPDIR}/AppRun"
chmod +x "${APPDIR}/AppRun"
cp "${SCRIPT_DIR}/infinidream.desktop" "${APPDIR}/"
cp "${RUNTIME_DIR}/logo.png"           "${APPDIR}/infinidream.png"  # icon

# ---------------------------------------------------------------------------
# Bundle shared library dependencies with linuxdeploy
#
# Exclusion policy for a Vulkan application:
#   - libvulkan.so*        : ICD loader — must come from host (driver-specific)
#   - libGL / libEGL       : GPU driver libs — must come from host
#   - libGLdispatch        : libglvnd dispatch — host only
#   - libX11 / libxcb*    : X11 display-server protocol — always present on X11 hosts
#   - libwayland-*         : Wayland display-server protocol — present when Wayland runs
#   - libxkbcommon         : Input — typically available on any desktop
#   - libdecor             : Wayland decoration helper — host-provided
#
# Everything else (FFmpeg, Boost, OpenSSL, curl, libpng, ...) is bundled.
# ---------------------------------------------------------------------------
log "Running linuxdeploy to bundle shared libraries ..."
"${LINUXDEPLOY}" \
    --appdir "${APPDIR}" \
    --executable "${APPDIR}/usr/bin/infinidream" \
    --exclude-library "libvulkan.so*"         \
    --exclude-library "libGL.so*"             \
    --exclude-library "libGLX.so*"            \
    --exclude-library "libGLdispatch.so*"     \
    --exclude-library "libEGL.so*"            \
    --exclude-library "libX11.so*"            \
    --exclude-library "libX11-xcb.so*"        \
    --exclude-library "libXau.so*"            \
    --exclude-library "libXdmcp.so*"          \
    --exclude-library "libxcb.so*"            \
    --exclude-library "libxcb-*.so*"          \
    --exclude-library "libXrender.so*"        \
    --exclude-library "libXext.so*"           \
    --exclude-library "libwayland-client.so*" \
    --exclude-library "libwayland-cursor.so*" \
    --exclude-library "libwayland-egl.so*"    \
    --exclude-library "libxkbcommon.so*"      \
    --exclude-library "libdecor-0.so*"        \
    --exclude-library "libpthread.so*"        \
    --exclude-library "libm.so*"              \
    --exclude-library "libc.so*"              \
    --exclude-library "libdl.so*"             \
    --exclude-library "librt.so*"

# ---------------------------------------------------------------------------
# Remove libraries that crash on startup when bundled.
#
# These libs have static constructors or IFUNC resolvers that segfault when
# loaded outside their native environment. They are either:
#   - present on all major distros (gnutls, zmq via system packages), OR
#   - only used by FFmpeg codecs that infinidream never exercises (xvidcore,
#     opencore-amr), so their absence causes a graceful codec-unavailable
#     rather than a crash.
# libleancrypto also has an undefined symbol (lc_kyber_512_dec) in the
# bundled copy, making it broken regardless.
# ---------------------------------------------------------------------------
log "Removing libs that crash at startup when bundled ..."
for lib in \
    libgnutls.so* \
    libleancrypto.so* \
    libxvidcore.so* \
    "libopencore-amrnb.so*" \
    "libopencore-amrwb.so*" \
    libzmq.so*; do
    rm -f "${APPDIR}/usr/lib/"${lib} && log "  removed ${lib}" || true
done

# ---------------------------------------------------------------------------
# Create the AppImage
# ---------------------------------------------------------------------------
log "Creating AppImage ..."
rm -f "${OUTPUT_APPIMAGE}"
"${APPIMAGETOOL}" "${APPDIR}" "${OUTPUT_APPIMAGE}"

log ""
log "Done! AppImage created at:"
log "  ${OUTPUT_APPIMAGE}"
log ""
log "Run it with:"
log "  ${OUTPUT_APPIMAGE}"
log ""
log "On systems without FUSE:"
log "  APPIMAGE_EXTRACT_AND_RUN=1 ${OUTPUT_APPIMAGE}"
