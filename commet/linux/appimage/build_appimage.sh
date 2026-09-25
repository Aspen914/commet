#!/usr/bin/env bash
#
# build_appimage.sh
#
# Packages the Commet Flutter Linux release bundle as an AppImage.
#
# It assembles a standard AppDir (https://docs.appimage.org/reference/appdir.html)
# from the output of `flutter build linux --release`, bundles the app's shared
# library dependencies with linuxdeploy, then produces a self-contained .AppImage
# with appimagetool.
#
# Requirements (see the release workflow for the exact package list):
#   curl, wget, sed, install, file, pkg-config, find, desktop-file-utils
#   (GTK plugin path additionally needs libgtk-3-dev, librsvg2-dev,
#   libgdk-pixbuf2.0-dev, gobject-introspection)
#
# Usage:
#   ./linux/appimage/build_appimage.sh \
#     --bundle build/linux/x64/release/bundle \
#     --version v0.5.0 \
#     --output build/appimage/commet-linux-x64.AppImage

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"

APPID="chat.commet.commetapp"
BINARY_NAME="commet"
ICON_NAME="commet-desktop"

# Architecture of the AppImage. Can be overridden when cross building.
ARCH="${ARCH:-$(uname -m)}"

BUNDLE_DIR="${BUNDLE_DIR:-${ROOT_DIR}/build/linux/x64/release/bundle}"
VERSION="latest"
# AppStream validation rejects a <release> element with no date, so the
# metainfo template carries a {{RELEASE_DATE}} placeholder. Override
# RELEASE_DATE to keep builds byte-for-byte reproducible.
RELEASE_DATE="${RELEASE_DATE:-$(date -u +%Y-%m-%d)}"
OUTPUT=""
USE_GTK_PLUGIN=1
KEEP_WORK=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle)
      BUNDLE_DIR="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --output)
      OUTPUT="$2"
      shift 2
      ;;
    --no-gtk-plugin)
      USE_GTK_PLUGIN=0
      shift
      ;;
    --keep-work)
      KEEP_WORK=1
      shift
      ;;
    -h | --help)
      sed -n '2,25p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Normalize the version tag ("v0.5.0" or "v0.5.0-rc1" -> "0.5.0") for the
# desktop file, AppImage metadata and output filename.
if [[ "${VERSION}" =~ ^[^0-9]*([0-9]+(\.[0-9]+)+) ]]; then
  VERSION="${BASH_REMATCH[1]}"
fi

case "${ARCH}" in
  x86_64)
    LD_ARCH="x86_64"
    ;;
  aarch64)
    LD_ARCH="aarch64"
    ;;
  armhf | armv7l)
    LD_ARCH="armhf"
    ;;
  *)
    echo "ERROR: unsupported architecture '${ARCH}'" >&2
    exit 1
    ;;
esac

BUILD_APPIMAGE_DIR="${ROOT_DIR}/build/appimage"
WORK_DIR="${BUILD_APPIMAGE_DIR}/work"
TOOLS_DIR="${WORK_DIR}/tools"
APPDIR="${WORK_DIR}/AppDir"

LINUXDEPLOY="${TOOLS_DIR}/linuxdeploy-${LD_ARCH}.AppImage"
APPIMAGETOOL="${TOOLS_DIR}/appimagetool-${LD_ARCH}.AppImage"
GTK_PLUGIN="${TOOLS_DIR}/linuxdeploy-plugin-gtk.sh"

if [[ -z "${OUTPUT}" ]]; then
  OUTPUT="${BUILD_APPIMAGE_DIR}/commet-linux-${LD_ARCH}.AppImage"
fi

# The build runs from inside the work directory, because linuxdeploy's appimage
# output plugin writes into the current directory. Pin the caller's paths to an
# absolute form now, while they are still relative to the invocation directory.
abspath() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$(pwd)/$1" ;;
  esac
}

BUNDLE_DIR="$(abspath "${BUNDLE_DIR}")"
OUTPUT="$(abspath "${OUTPUT}")"

log() {
  echo "[appimage] $*"
}

download_tools() {
  log "Downloading linuxdeploy (${LD_ARCH})"
  curl -L --fail --retry 3 --retry-delay 2 -o "${LINUXDEPLOY}" \
    "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-${LD_ARCH}.AppImage"
  chmod +x "${LINUXDEPLOY}"
  # The GTK plugin re-invokes linuxdeploy and looks it up via this variable.
  export LINUXDEPLOY="${LINUXDEPLOY}"

  log "Downloading appimagetool (${LD_ARCH})"
  curl -L --fail --retry 3 --retry-delay 2 -o "${APPIMAGETOOL}" \
    "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-${LD_ARCH}.AppImage"
  chmod +x "${APPIMAGETOOL}"

  if [[ "${USE_GTK_PLUGIN}" == "1" ]]; then
    log "Downloading linuxdeploy GTK plugin"
    if ! curl -L --fail --retry 3 --retry-delay 2 -o "${GTK_PLUGIN}" \
      "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh"; then
      log "WARNING: could not download the GTK plugin, continuing without it"
      USE_GTK_PLUGIN=0
    else
      chmod +x "${GTK_PLUGIN}"
    fi
  fi

  export PATH="${TOOLS_DIR}:${PATH}"

  # The environment may not provide FUSE (e.g. Ubuntu 24.04 runner images), so
  # tell AppImage runtimes to extract themselves instead of mounting.
  export APPIMAGE_EXTRACT_AND_RUN=1
}

assemble_appdir() {
  log "Assembling AppDir"
  rm -rf "${APPDIR}"
  mkdir -p "${APPDIR}/usr/bin"

  if [[ ! -x "${BUNDLE_DIR}/${BINARY_NAME}" ]]; then
    echo "ERROR: Flutter bundle not found at ${BUNDLE_DIR}" >&2
    echo "Build it first: flutter build linux --release" >&2
    exit 1
  fi

  cp -a "${BUNDLE_DIR}/." "${APPDIR}/usr/bin/"
  chmod +x "${APPDIR}/usr/bin/${BINARY_NAME}"

  # linuxdeploy relocates libraries into usr/lib and rewrites the executable's
  # RUNPATH to $ORIGIN/../lib. It only follows DT_NEEDED entries, so the
  # libraries the Flutter engine loads with dlopen() at runtime (libapp.so,
  # librust_lib_commet.so, libvodozemac_bindings_dart.so) are never moved and
  # become unreachable once the RUNPATH is rewritten. Merge the bundle's lib/
  # into usr/lib so the rewritten RUNPATH resolves them, and keep a usr/bin/lib
  # symlink so the original $ORIGIN/lib still resolves if the RUNPATH is left
  # untouched.
  if [[ -d "${APPDIR}/usr/bin/lib" ]]; then
    mkdir -p "${APPDIR}/usr/lib"
    cp -a "${APPDIR}/usr/bin/lib/." "${APPDIR}/usr/lib/"
    rm -rf "${APPDIR}/usr/bin/lib"
    ln -s ../lib "${APPDIR}/usr/bin/lib"
  fi

  install -Dm644 "${SCRIPT_DIR}/${APPID}.desktop" \
    "${APPDIR}/usr/share/applications/${APPID}.desktop"

  install -Dm644 "${ROOT_DIR}/linux/debian/usr/share/icons/hicolor/512x512/apps/${ICON_NAME}.png" \
    "${APPDIR}/usr/share/icons/hicolor/512x512/apps/${ICON_NAME}.png"

  # freedesktop.org metainfo so software centers can identify the app.
  install -Dm644 "${ROOT_DIR}/linux/flatpak/${APPID}.metainfo.xml" \
    "${APPDIR}/usr/share/metainfo/${APPID}.appdata.xml"
  sed -i "s|{{VERSION_TAG}}|${VERSION}|g" \
    "${APPDIR}/usr/share/metainfo/${APPID}.appdata.xml"
  sed -i "s|{{RELEASE_DATE}}|${RELEASE_DATE}|g" \
    "${APPDIR}/usr/share/metainfo/${APPID}.appdata.xml"
}

run_linuxdeploy() {
  local use_gtk="$1"
  local args=(
    --appdir "${APPDIR}"
    --executable "${APPDIR}/usr/bin/${BINARY_NAME}"
    --desktop-file "${APPDIR}/usr/share/applications/${APPID}.desktop"
    --icon-file "${APPDIR}/usr/share/icons/hicolor/512x512/apps/${ICON_NAME}.png"
  )

  if [[ "${use_gtk}" == "1" ]]; then
    log "Running linuxdeploy with the GTK plugin"
    args+=(--plugin gtk)
  else
    log "Running linuxdeploy"
  fi

  args+=(--output appimage)

  "${LINUXDEPLOY}" "${args[@]}"
}

build_appimage() {
  local use_gtk="$1"

  # Drop any AppImage left over from a previous attempt (e.g. a GTK plugin
  # run that failed after producing output), so finish() only ever sees the
  # result of the run that just succeeded.
  find "${BUILD_APPIMAGE_DIR}" -maxdepth 2 -name '*.AppImage' -not -path '*/tools/*' -delete

  assemble_appdir

  if [[ "${use_gtk}" == "1" ]] && [[ ! -x "${GTK_PLUGIN}" ]]; then
    use_gtk=0
  fi

  run_linuxdeploy "${use_gtk}"
}

finish() {
  local produced
  produced="$(find "${BUILD_APPIMAGE_DIR}" -maxdepth 2 -name '*.AppImage' -not -path '*/tools/*' | head -n1)"

  if [[ -z "${produced}" ]]; then
    echo "ERROR: linuxdeploy did not produce an AppImage" >&2
    exit 1
  fi

  mkdir -p "$(dirname "${OUTPUT}")"
  if [[ "${produced}" != "${OUTPUT}" ]]; then
    mv -f "${produced}" "${OUTPUT}"
  fi

  if [[ "${KEEP_WORK}" != "1" ]]; then
    rm -rf "${WORK_DIR}"
  fi

  log "Done: ${OUTPUT}"
}

main() {
  rm -rf "${BUILD_APPIMAGE_DIR}"
  mkdir -p "${TOOLS_DIR}"

  # linuxdeploy's appimage output plugin writes the built AppImage to the
  # current directory, so stage the build inside the work directory.
  cd "${WORK_DIR}"

  download_tools

  if [[ "${USE_GTK_PLUGIN}" == "1" ]]; then
    if build_appimage 1; then
      :
    else
      log "WARNING: GTK plugin run failed, retrying without it"
      build_appimage 0
    fi
  else
    build_appimage 0
  fi

  finish
}

main