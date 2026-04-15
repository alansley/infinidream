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
#   - All normal infinidream build dependencies (cmake, vulkan, boost, etc.)
#     EXCEPT system FFmpeg — a minimal FFmpeg is compiled from source here.
#   - curl (to download FFmpeg source + linuxdeploy / appimagetool on first run)
#   - nasm or yasm (FFmpeg assembly optimisations; skipped gracefully if absent)
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

BUILD_DIR="${SCRIPT_DIR}/build-appimage"
APPDIR="${SCRIPT_DIR}/AppDir"
TOOLS_DIR="${SCRIPT_DIR}/appimage-tools"
RUNTIME_DIR="${SCRIPT_DIR}/../Runtime"

# ---------------------------------------------------------------------------
# Minimal FFmpeg — built from source to avoid transitive codec dependencies
# that crash when bundled (libgnutls, libzmq, libxvidcore, libopencore-amr, …).
# Pinned to a specific release for reproducibility.
# ---------------------------------------------------------------------------
FFMPEG_VERSION="7.1.1"
FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"
FFMPEG_SRC_DIR="${SCRIPT_DIR}/ffmpeg-src/ffmpeg-${FFMPEG_VERSION}"
FFMPEG_INSTALL="${SCRIPT_DIR}/ffmpeg-minimal"

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
require_cmd make

# Detect whether FUSE is available; if not, fall back to extract-and-run mode.
if [[ ! -e /dev/fuse ]]; then
    log "WARNING: /dev/fuse not found — enabling APPIMAGE_EXTRACT_AND_RUN=1 for tooling."
    export APPIMAGE_EXTRACT_AND_RUN=1
fi

# ---------------------------------------------------------------------------
# Build minimal FFmpeg from source (cached — skipped if already built).
#
# --disable-everything + selective enables gives us a tiny FFmpeg with:
#   • Decoders:   h264, hevc
#   • BSFs:       h264_mp4toannexb, hevc_mp4toannexb
#   • Parsers:    h264, hevc
#   • Demuxers:   mov (MP4/MOV), matroska (MKV/WebM)
#   • Protocols:  file, http, https, tcp, tls
#   • TLS via OpenSSL (already a direct dependency — avoids gnutls entirely)
#
# This eliminates ALL transitive codec dependencies that would otherwise crash
# at startup when loaded outside their native system environment.
# ---------------------------------------------------------------------------
FFMPEG_MARKER="${FFMPEG_INSTALL}/lib/pkgconfig/libavcodec.pc"
if [[ -f "${FFMPEG_MARKER}" ]]; then
    log "Minimal FFmpeg already built at ${FFMPEG_INSTALL}, skipping."
else
    log "Building minimal FFmpeg ${FFMPEG_VERSION} from source ..."

    mkdir -p "${SCRIPT_DIR}/ffmpeg-src"

    # Download tarball if not already present
    FFMPEG_TARBALL_PATH="${SCRIPT_DIR}/ffmpeg-src/${FFMPEG_TARBALL}"
    if [[ ! -f "${FFMPEG_TARBALL_PATH}" ]]; then
        log "Downloading FFmpeg ${FFMPEG_VERSION} ..."
        curl -fsSL --retry 3 -o "${FFMPEG_TARBALL_PATH}" "${FFMPEG_URL}"
    else
        log "FFmpeg tarball already downloaded, skipping."
    fi

    # Extract if not already extracted
    if [[ ! -d "${FFMPEG_SRC_DIR}" ]]; then
        log "Extracting FFmpeg source ..."
        tar -xf "${FFMPEG_TARBALL_PATH}" -C "${SCRIPT_DIR}/ffmpeg-src"
    fi

    pushd "${FFMPEG_SRC_DIR}" > /dev/null

    log "Configuring minimal FFmpeg ..."
    ./configure \
        --prefix="${FFMPEG_INSTALL}" \
        --disable-everything \
        --enable-shared \
        --disable-static \
        --enable-pic \
        --enable-avformat \
        --enable-avcodec \
        --enable-avutil \
        --enable-swscale \
        --enable-swresample \
        --enable-network \
        --enable-openssl \
        --enable-protocol=file \
        --enable-protocol=http \
        --enable-protocol=https \
        --enable-protocol=tcp \
        --enable-protocol=tls \
        --enable-demuxer=mov \
        --enable-demuxer=matroska \
        --enable-decoder=h264 \
        --enable-decoder=hevc \
        --enable-parser=h264 \
        --enable-parser=hevc \
        --enable-bsf=h264_mp4toannexb \
        --enable-bsf=hevc_mp4toannexb \
        --disable-doc \
        --disable-programs

    log "Compiling minimal FFmpeg ($(nproc) jobs) ..."
    make -j"$(nproc)"

    log "Installing minimal FFmpeg to ${FFMPEG_INSTALL} ..."
    make install

    popd > /dev/null
    log "Minimal FFmpeg build complete."
fi

# Point pkg-config and the linker at our minimal FFmpeg install.
# This overrides any system FFmpeg for the cmake build below.
export PKG_CONFIG_PATH="${FFMPEG_INSTALL}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${FFMPEG_INSTALL}/lib:${LD_LIBRARY_PATH:-}"

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
# Build infinidream (Release) against the minimal FFmpeg
# ---------------------------------------------------------------------------
log "Configuring CMake ..."
cmake -B "${BUILD_DIR}" -S "${SCRIPT_DIR}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_EXE_LINKER_FLAGS="-L${FFMPEG_INSTALL}/lib"

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
# All FFmpeg libraries come from our minimal build and are fully self-contained —
# no transitive codec dependencies that would crash when loaded in a foreign env.
# Everything else (Boost, OpenSSL, curl, libpng, ...) is bundled.
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
