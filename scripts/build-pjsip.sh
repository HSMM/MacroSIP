#!/usr/bin/env bash
#
# build-pjsip.sh - fetch, configure, build and install pjproject (PJSIP) for MacroSIP.
#
#   Target : macOS arm64 only, static libraries, deployment target macOS 14.0
#   Output : third_party/pjsip/{include,lib,bin/pjsua,LINKFLAGS,CFLAGS}
#
# Idempotent: the tarball is downloaded once (and SHA-256 verified every run),
# the source tree is re-extracted fresh on every run so stale objects or a
# previous config never leak into a new build.
#
# Usage: scripts/build-pjsip.sh            # full (re)build
#        JOBS=4 scripts/build-pjsip.sh     # override parallelism
#
set -euo pipefail

# ----------------------------------------------------------------- settings ---
PJ_VERSION="2.17"
PJ_URL="https://github.com/pjsip/pjproject/archive/refs/tags/${PJ_VERSION}.tar.gz"
PJ_SHA256="065fe06c06788d97c35f563796d59f00ce52fe9558a52d7b490a042a966facce"

MIN_MACOS="14.0"
ARCH="arm64"
OPENSSL_PREFIX="/opt/homebrew/opt/openssl@3"
OPUS_PREFIX="/opt/homebrew/opt/opus"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TP="${ROOT}/third_party"
DL_DIR="${TP}/downloads"
TARBALL="${DL_DIR}/pjproject-${PJ_VERSION}.tar.gz"
SRC="${TP}/pjproject-${PJ_VERSION}"
OUT="${TP}/pjsip"
CONFIG_SITE="${OUT}/config_site.h"
LOG_DIR="${TP}/build-logs"

# ------------------------------------------------------------------ helpers ---
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run_logged <logname> <cmd...> : run quietly, keep full log, show tail on failure
run_logged() {
  local name="$1"; shift
  local log="${LOG_DIR}/${name}.log"
  if ! "$@" >"${log}" 2>&1; then
    printf '\033[1;31mFAILED: %s\033[0m (full log: %s)\n' "$*" "${log}" >&2
    tail -n 40 "${log}" >&2
    exit 1
  fi
  info "ok (log: ${log#"${ROOT}"/})"
}

START_TS=$(date +%s)

# ------------------------------------------------------------ prerequisites ---
step "Checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) host required"
command -v clang >/dev/null || die "clang not found (install Xcode Command Line Tools)"
command -v make  >/dev/null || die "make not found (install Xcode Command Line Tools)"
command -v curl  >/dev/null || die "curl not found"
[[ -f "${OPENSSL_PREFIX}/include/openssl/ssl.h" ]] || die "openssl@3 missing: brew install openssl@3"
[[ -f "${OPUS_PREFIX}/include/opus/opus.h" ]]      || die "opus missing: brew install opus"
[[ -f "${CONFIG_SITE}" ]] || die "missing ${CONFIG_SITE}"
info "clang: $(clang --version | head -1)"
info "jobs : ${JOBS}"
mkdir -p "${DL_DIR}" "${LOG_DIR}"

# ----------------------------------------------------------------- download ---
step "Fetching pjproject ${PJ_VERSION}"
if [[ -f "${TARBALL}" ]]; then
  info "using cached ${TARBALL#"${ROOT}"/}"
else
  curl -fL --retry 3 --progress-bar -o "${TARBALL}.part" "${PJ_URL}"
  mv "${TARBALL}.part" "${TARBALL}"
fi
ACTUAL_SHA="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA}" != "${PJ_SHA256}" ]]; then
  die "SHA-256 mismatch for ${TARBALL}
       expected ${PJ_SHA256}
       actual   ${ACTUAL_SHA}
     (delete the file to re-download; if upstream re-tagged, review and update PJ_SHA256)"
fi
info "sha256 ok: ${ACTUAL_SHA}"

# ------------------------------------------------------------------ extract ---
step "Extracting fresh source tree"
rm -rf "${SRC}"
tar -xzf "${TARBALL}" -C "${TP}"
[[ -x "${SRC}/configure" ]] || die "unexpected tarball layout (no ${SRC}/configure)"
info "${SRC#"${ROOT}"/}"

step "Installing config_site.h"
cp "${CONFIG_SITE}" "${SRC}/pjlib/include/pj/config_site.h"
info "third_party/pjsip/config_site.h -> pjlib/include/pj/config_site.h"

# ---------------------------------------------------------------- configure ---
step "Configuring"
COMMON_FLAGS="-arch ${ARCH} -mmacosx-version-min=${MIN_MACOS}"
export MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}"
export CFLAGS="${COMMON_FLAGS} -O2 -g -fno-common"
export CXXFLAGS="${COMMON_FLAGS} -O2 -g"
export LDFLAGS="${COMMON_FLAGS}"

CONFIGURE_FLAGS=(
  --prefix="${OUT}/.stage"
  --disable-shared
  --disable-pjsua2              # C API only; Swift talks to pjsua-lib via CPJSUA
  --disable-video
  --disable-sdl
  --disable-ffmpeg
  --disable-v4l2
  --disable-openh264
  --disable-vpx
  --disable-libyuv
  --disable-upnp
  --disable-darwin-ssl          # force OpenSSL backend (SecureTransport is deprecated)
  --with-ssl="${OPENSSL_PREFIX}"
  --with-opus="${OPUS_PREFIX}"
  --disable-speex-codec
  --disable-speex-aec           # WebRTC AEC is used instead
  --disable-ilbc-codec
  --disable-gsm-codec
  --disable-g7221-codec
  --disable-l16-codec
  --disable-opencore-amr
  --disable-silk
  --disable-bcg729
  --disable-lyra
)
info "CFLAGS=${CFLAGS}"
info "LDFLAGS=${LDFLAGS}"
info "./configure ${CONFIGURE_FLAGS[*]}"
( cd "${SRC}" && run_logged configure ./configure "${CONFIGURE_FLAGS[@]}" )

# Sanity-check what configure detected.
CFG_LOG="${LOG_DIR}/configure.log"
grep -q "OpenSSL library found, SSL support enabled" "${CFG_LOG}" || die "configure did not enable OpenSSL"
grep -qi "opus.*found\|Checking if OPUS.*yes\|OPUS library found" "${CFG_LOG}" \
  || grep -q "PJMEDIA_HAS_OPUS_CODEC 1" "${SRC}/pjmedia/include/pjmedia-codec/config_auto.h" \
  || die "configure did not enable Opus"
grep -E "Checking sound device backend|coreaudio|Checking if libwebrtc|SSL|OPUS|opus" "${CFG_LOG}" \
  | sed 's/^/    | /' | head -20 || true

# -------------------------------------------------------------------- build ---
step "Building (make dep)"
( cd "${SRC}" && run_logged make-dep make dep )
step "Building libraries + pjsua (make -j${JOBS})"
( cd "${SRC}" && run_logged make make -j"${JOBS}" )

TARGET_NAME="$(sed -n 's/^export TARGET_NAME := *//p' "${SRC}/build.mak" | tr -d ' ')"
[[ -n "${TARGET_NAME}" ]] || die "could not determine TARGET_NAME from build.mak"
PJSUA_BIN="${SRC}/pjsip-apps/bin/pjsua-${TARGET_NAME}"
[[ -x "${PJSUA_BIN}" ]] || die "pjsua was not built (${PJSUA_BIN})"
info "target: ${TARGET_NAME}"

# ------------------------------------------------------------------ install ---
step "Installing into third_party/pjsip"
rm -rf "${OUT}/include" "${OUT}/lib" "${OUT}/bin" "${OUT}/.stage"
( cd "${SRC}" && run_logged make-install make install )
mkdir -p "${OUT}/lib" "${OUT}/bin"
mv "${OUT}/.stage/include" "${OUT}/include"
# Strip the host-triple suffix (e.g. libpj-aarch64-apple-darwin27.2.0.a -> libpj.a)
# so link flags stay stable across macOS updates.
for a in "${OUT}/.stage/lib/"*.a; do
  base="$(basename "${a}")"
  cp "${a}" "${OUT}/lib/${base/-${TARGET_NAME}.a/.a}"
done
rm -rf "${OUT}/.stage"
cp "${PJSUA_BIN}" "${OUT}/bin/pjsua"

# Verify architecture of what we ship.
for f in "${OUT}/bin/pjsua" "${OUT}/lib/libpj.a"; do
  lipo -info "${f}" | grep -q "arm64" || die "${f} is not arm64"
done
otool -l "${OUT}/bin/pjsua" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print "    pjsua minos: "$2; exit}'

# ---------------------------------------------------------- link/c flags ---
step "Generating LINKFLAGS / CFLAGS"
# Ask pjproject's own build.mak for the exact app link line.
PRINT_MK="${LOG_DIR}/print-flags.mak"
cat >"${PRINT_MK}" <<'MK'
include build.mak
print-ldlibs:  ; @echo $(PJ_LDLIBS)
print-cflags:  ; @echo $(PJ_INSTALL_CFLAGS)
MK
LDLIBS="$(cd "${SRC}" && make -s -f "${PRINT_MK}" print-ldlibs)"
INSTALL_CFLAGS="$(cd "${SRC}" && make -s -f "${PRINT_MK}" print-cflags)"

# -lfoo-<triple> -> -lfoo (we install the archives without the triple suffix).
LIBS_OUT=()
for tok in ${LDLIBS}; do
  LIBS_OUT+=("${tok/-${TARGET_NAME}/}")
done
# libwebrtc contains C++ objects; Apple's libc++ is needed when linking with a C/Swift driver.
LINKFLAGS="-L${OUT}/lib ${LIBS_OUT[*]} -L${OPENSSL_PREFIX}/lib -L${OPUS_PREFIX}/lib -lc++"
# De-duplicate tokens while keeping order (frameworks are '-framework X' pairs).
LINKFLAGS="$(echo "${LINKFLAGS}" | awk '{
  out=""; for(i=1;i<=NF;i++){ t=$i; if(t=="-framework"){ t=t" "$(++i) }
    if(!(t in seen)){ seen[t]=1; out=out (out==""?"":" ") t } } print out }')"
printf '%s\n' "${LINKFLAGS}" >"${OUT}/LINKFLAGS"
# Consumers must see the same feature macros as the library build.
printf '%s\n' "$(echo "${INSTALL_CFLAGS}" | sed "s#-I${OUT}/.stage/include#-I${OUT}/include#")" >"${OUT}/CFLAGS"

# ---------------------------------------------------------------- summary ---
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
step "Done in $((ELAPSED / 60))m $((ELAPSED % 60))s"
info "pjproject   : ${PJ_VERSION} (sha256 ${PJ_SHA256:0:16}...)"
info "target      : ${TARGET_NAME}, macOS >= ${MIN_MACOS}, static"
info "headers     : third_party/pjsip/include ($(find "${OUT}/include" -name '*.h' | wc -l | tr -d ' ') files)"
info "libraries   : third_party/pjsip/lib"
for a in "${OUT}/lib/"*.a; do info "              $(basename "${a}")  ($(du -h "${a}" | awk '{print $1}'))"; done
info "cli         : third_party/pjsip/bin/pjsua (version $("${OUT}/bin/pjsua" --version 2>&1 | awk '/PJ_VERSION/{print $NF; exit}'))"
info "LINKFLAGS   : third_party/pjsip/LINKFLAGS"
info "CFLAGS      : third_party/pjsip/CFLAGS -> $(cat "${OUT}/CFLAGS")"
info "logs        : third_party/build-logs/"
