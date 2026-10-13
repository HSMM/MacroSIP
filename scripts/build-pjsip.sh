#!/usr/bin/env bash
#
# build-pjsip.sh - build PJSIP and its dependencies (OpenSSL 3, Opus) for MacroSIP as
# universal (arm64 + x86_64) static libraries.
#
#   Targets: macOS arm64 (native) and x86_64 (cross-compiled on Apple Silicon),
#            static libraries, deployment target macOS 14.0 for both slices.
#   Inputs : pinned source tarballs (SHA-256 verified), third_party/pjsip/config_site.h
#   Output : third_party/deps/universal/{include,lib}   libssl.a, libcrypto.a, libopus.a
#            third_party/pjsip/{include,lib,bin/pjsua,LINKFLAGS,CFLAGS}   universal PJSIP
#   Per-arch intermediate results: third_party/deps/<arch>/, third_party/pjsip/arch/<arch>/
#
# Idempotent and cache-friendly: every component (OpenSSL, Opus, PJSIP per architecture,
# then the universal merge) records a stamp with its recipe (versions, checksums, flags,
# config_site.h hash). A component whose stamp matches is skipped; a changed recipe
# rebuilds that component and everything that depends on it. Tarballs are downloaded only
# when a component needs them and are SHA-256 verified before use. Each build starts from a
# freshly extracted source tree, so stale objects never leak into a new build.
#
# Usage: scripts/build-pjsip.sh            # build what is missing or out of date
#        scripts/build-pjsip.sh --clean    # remove all outputs and rebuild from scratch
#        JOBS=4 scripts/build-pjsip.sh     # override parallelism
#        KEEP_BUILD=1 scripts/build-pjsip.sh   # keep the source/build trees in third_party/build
#
set -euo pipefail

# ----------------------------------------------------------------- settings ---
PJ_VERSION="2.17"
PJ_URL="https://github.com/pjsip/pjproject/archive/refs/tags/${PJ_VERSION}.tar.gz"
PJ_SHA256="065fe06c06788d97c35f563796d59f00ce52fe9558a52d7b490a042a966facce"

# OpenSSL 3.5 is the LTS series (supported until April 2030).
OPENSSL_VERSION="3.5.9"
OPENSSL_URL="https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz"
OPENSSL_SHA256="603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a"

OPUS_VERSION="1.6.1"
OPUS_URL="https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz"
OPUS_SHA256="6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1"

MIN_MACOS="14.0"
ARCHS=(arm64 x86_64)
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TP="${ROOT}/third_party"
DL_DIR="${TP}/downloads"
BUILD_DIR="${TP}/build"
DEPS="${TP}/deps"
OUT="${TP}/pjsip"
CONFIG_SITE="${OUT}/config_site.h"
LOG_DIR="${TP}/build-logs"

CLEAN=0
for arg in "$@"; do
  case "${arg}" in
    --clean) CLEAN=1 ;;
    -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: ${arg} (try --help)" >&2; exit 2 ;;
  esac
done

# OpenSSL: static only; providers built in (no loadable modules); no tests, docs or apps
# are built because only the build_libs / install_dev targets run. OPENSSLDIR points at the
# system location: MacroSIP passes its own CA bundle to PJSIP (TLSRoots.swift) and never
# relies on OpenSSL's default certificate paths.
OPENSSL_OPTS=(no-shared no-module no-tests --openssldir=/private/etc/ssl)
OPUS_OPTS=(--disable-shared --enable-static --disable-doc --disable-extra-programs)
PJ_CONFIGURE_FLAGS=(
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
  --disable-speex-aec           # WebRTC AEC is used instead (the Speex codec is built)
  --disable-l16-codec
  --disable-opencore-amr
  --disable-silk
  --disable-bcg729
  --disable-lyra
)

# ------------------------------------------------------------------ helpers ---
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# run_logged <logname> <cmd...> : run quietly, keep full log, show tail on failure
run_logged() {
  local name="$1"; shift
  local log="${LOG_DIR}/${name}.log"
  mkdir -p "$(dirname "${log}")"
  if ! "$@" >"${log}" 2>&1; then
    printf '\033[1;31mFAILED: %s\033[0m (full log: %s)\n' "$*" "${log}" >&2
    tail -n 40 "${log}" >&2
    exit 1
  fi
  info "ok (log: ${log#"${ROOT}"/})"
}

# fetch <url> <sha256> <file> : download once into third_party/downloads, verify every time
fetch() {
  local url="$1" sha="$2" file="$3" actual
  if [[ -f "${file}" ]]; then
    info "using cached ${file#"${ROOT}"/}"
  else
    info "downloading ${url}"
    curl -fL --retry 3 --progress-bar -o "${file}.part" "${url}"
    mv "${file}.part" "${file}"
  fi
  actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${sha}" ]] || die "SHA-256 mismatch for ${file}
       expected ${sha}
       actual   ${actual}
     (delete the file to re-download; if upstream re-published it, review and update the pinned checksum)"
  info "sha256 ok: ${actual}"
}

# extract <tarball> <dest-parent> <expected-dir> : fresh source tree
extract() {
  local tarball="$1" parent="$2" dir="$3"
  rm -rf "${dir}"
  mkdir -p "${parent}"
  tar -xzf "${tarball}" -C "${parent}"
  [[ -d "${dir}" ]] || die "unexpected tarball layout (no ${dir})"
}

# The recipe of a component is stored in its stamp; equal recipe + stamp present = up to date.
stamp_ok() { [[ -f "$1" && "$(cat "$1")" == "$2" ]]; }

# check_slice <file> <arch> : the file is a single-arch Mach-O (or archive) of <arch>
# whose objects target macOS ${MIN_MACOS}.
check_slice() {
  local f="$1" arch="$2" minos
  [[ "$(lipo -archs "${f}")" == "${arch}" ]] || die "${f} is $(lipo -archs "${f}"), expected ${arch}"
  # Every object's LC_BUILD_VERSION (awk reads all input: an early exit would SIGPIPE otool).
  minos="$(otool -l "${f}" 2>/dev/null | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{v[$2]=1; b=0} END{for(k in v) printf "%s ", k}')"
  minos="${minos% }"
  [[ -z "${minos}" || "${minos}" == "${MIN_MACOS}" ]] || die "${f} targets macOS ${minos}, expected ${MIN_MACOS}"
}

# check_universal <file> : both slices present
check_universal() {
  local archs
  archs="$(lipo -archs "$1")"
  for a in "${ARCHS[@]}"; do
    [[ " ${archs} " == *" ${a} "* ]] || die "$1 lacks the ${a} slice (has: ${archs})"
  done
}

# merge_headers <dest> <dir-of-arch1> <dir-of-arch2>... : copy the first include tree to <dest>;
# a header that differs between architectures (configure results such as PJ_M_NAME in
# pj/compat/m_auto.h) becomes one file with an #if branch per architecture. The trees must
# contain the same files.
arch_macro() { case "$1" in arm64) echo "__aarch64__" ;; x86_64) echo "__x86_64__" ;; esac; }
merge_headers() {
  local dest="$1" rel a kw i differs
  shift
  local -a dirs=("$@")
  for ((i = 1; i < ${#dirs[@]}; i++)); do
    [[ "$(cd "${dirs[0]}" && find . -type f | sort)" == "$(cd "${dirs[i]}" && find . -type f | sort)" ]] \
      || die "header trees contain different files: ${dirs[0]} vs ${dirs[i]}"
  done
  rm -rf "${dest}"
  cp -R "${dirs[0]}" "${dest}"
  while IFS= read -r rel; do
    differs=0
    for ((i = 1; i < ${#dirs[@]}; i++)); do
      cmp -s "${dirs[0]}/${rel}" "${dirs[i]}/${rel}" || differs=1
    done
    [[ "${differs}" == 1 ]] || continue
    {
      printf '/* Per-architecture configure results, merged by scripts/build-pjsip.sh. */\n'
      kw="#if"
      for ((i = 0; i < ${#dirs[@]}; i++)); do
        printf '%s defined(%s)\n' "${kw}" "$(arch_macro "${ARCHS[i]}")"
        cat "${dirs[i]}/${rel}"
        kw="#elif"
      done
      printf '#else\n#error "unsupported architecture"\n#endif\n'
    } >"${dest}/${rel}"
    info "merged per-arch header: ${rel#./}"
  done < <(cd "${dirs[0]}" && find . -type f | sort)
}

# Clang flags for one architecture. Native arm64 builds need no --host; x86_64 is a cross build.
arch_cflags() { echo "-arch $1 -mmacosx-version-min=${MIN_MACOS}"; }
arch_host()   { [[ "$1" == "arm64" ]] && echo "" || echo "--host=x86_64-apple-darwin"; }

# per_arch <pattern-with-ARCH> : print one path per architecture, NUL-separated (for mapfile-free bash 3.2)
per_arch() { local a; for a in "${ARCHS[@]}"; do printf '%s\0' "${1//@ARCH@/${a}}"; done; }
# with_per_arch <pattern> <cmd...> : run <cmd...> <path-for-arch1> <path-for-arch2>...
with_per_arch() {
  local pattern="$1"; shift
  local -a paths=()
  local p
  while IFS= read -r -d '' p; do paths+=("${p}"); done < <(per_arch "${pattern}")
  "$@" "${paths[@]}"
}

sha_of() { shasum -a 256 "$1" | awk '{print $1}'; }

START_TS=$(date +%s)

# ------------------------------------------------------------ prerequisites ---
step "Checking prerequisites"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) host required (x86_64 is cross-compiled)"
for tool in clang make curl perl lipo otool shasum; do
  command -v "${tool}" >/dev/null || die "${tool} not found (install Xcode Command Line Tools)"
done
[[ -f "${CONFIG_SITE}" ]] || die "missing ${CONFIG_SITE}"
info "clang: $(clang --version | head -1)"
info "jobs : ${JOBS}"
info "archs: ${ARCHS[*]} (macOS >= ${MIN_MACOS})"

if [[ "${CLEAN}" == 1 ]]; then
  step "Cleaning previous outputs (--clean)"
  rm -rf "${BUILD_DIR}" "${DEPS}" "${LOG_DIR}" \
         "${OUT}/arch" "${OUT}/include" "${OUT}/lib" "${OUT}/bin" "${OUT}/.stage" \
         "${OUT}/LINKFLAGS" "${OUT}/CFLAGS" "${OUT}/.stamp-universal"
  info "kept: third_party/downloads (verified tarballs), third_party/pjsip/config_site.h"
fi
# Source tree of the single-arch layout used before the universal build.
rm -rf "${TP}/pjproject-${PJ_VERSION}"
mkdir -p "${DL_DIR}" "${LOG_DIR}"

# ------------------------------------------------------------------ OpenSSL ---
build_openssl() {
  local arch="$1" prefix="${DEPS}/$1" target src
  local stamp="${prefix}/.stamp-openssl"
  local recipe="openssl ${OPENSSL_VERSION} ${OPENSSL_SHA256} ${arch} macos-${MIN_MACOS} ${OPENSSL_OPTS[*]}"
  step "OpenSSL ${OPENSSL_VERSION} (${arch})"
  if stamp_ok "${stamp}" "${recipe}"; then info "up to date"; return; fi
  rm -f "${stamp}"
  case "${arch}" in
    arm64)  target=darwin64-arm64-cc ;;
    x86_64) target=darwin64-x86_64-cc ;;
  esac
  local tarball="${DL_DIR}/openssl-${OPENSSL_VERSION}.tar.gz"
  fetch "${OPENSSL_URL}" "${OPENSSL_SHA256}" "${tarball}"
  src="${BUILD_DIR}/${arch}/openssl-${OPENSSL_VERSION}"
  extract "${tarball}" "${BUILD_DIR}/${arch}" "${src}"
  rm -rf "${prefix}/include/openssl" "${prefix}/lib/libssl.a" "${prefix}/lib/libcrypto.a" \
         "${prefix}/lib/pkgconfig/"{libssl,libcrypto,openssl}.pc
  (
    cd "${src}"
    export MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}"
    run_logged "${arch}/openssl-configure" ./Configure "${target}" "${OPENSSL_OPTS[@]}" \
      --prefix="${prefix}" --libdir=lib "-mmacosx-version-min=${MIN_MACOS}"
    run_logged "${arch}/openssl-make" make -j"${JOBS}" build_libs
    run_logged "${arch}/openssl-install" make install_dev
  )
  check_slice "${prefix}/lib/libssl.a" "${arch}"
  check_slice "${prefix}/lib/libcrypto.a" "${arch}"
  [[ "${KEEP_BUILD:-0}" == 1 ]] || rm -rf "${src}"
  printf '%s' "${recipe}" >"${stamp}"
}

# --------------------------------------------------------------------- Opus ---
build_opus() {
  local arch="$1" prefix="${DEPS}/$1" src host
  local stamp="${prefix}/.stamp-opus"
  local recipe="opus ${OPUS_VERSION} ${OPUS_SHA256} ${arch} macos-${MIN_MACOS} ${OPUS_OPTS[*]}"
  step "Opus ${OPUS_VERSION} (${arch})"
  if stamp_ok "${stamp}" "${recipe}"; then info "up to date"; return; fi
  rm -f "${stamp}"
  local tarball="${DL_DIR}/opus-${OPUS_VERSION}.tar.gz"
  fetch "${OPUS_URL}" "${OPUS_SHA256}" "${tarball}"
  src="${BUILD_DIR}/${arch}/opus-${OPUS_VERSION}"
  extract "${tarball}" "${BUILD_DIR}/${arch}" "${src}"
  rm -rf "${prefix}/include/opus" "${prefix}/lib/libopus."* "${prefix}/lib/pkgconfig/opus.pc"
  host="$(arch_host "${arch}")"
  (
    cd "${src}"
    export MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}"
    export CC=clang
    export CFLAGS="$(arch_cflags "${arch}") -O2"
    export LDFLAGS="$(arch_cflags "${arch}")"
    run_logged "${arch}/opus-configure" ./configure ${host:+"${host}"} "${OPUS_OPTS[@]}" \
      --prefix="${prefix}" --libdir="${prefix}/lib"
    run_logged "${arch}/opus-make" make -j"${JOBS}"
    run_logged "${arch}/opus-install" make install
  )
  rm -f "${prefix}/lib/libopus.la"
  check_slice "${prefix}/lib/libopus.a" "${arch}"
  [[ "${KEEP_BUILD:-0}" == 1 ]] || rm -rf "${src}"
  printf '%s' "${recipe}" >"${stamp}"
}

# -------------------------------------------------------------------- PJSIP ---
build_pjsip() {
  local arch="$1" deps="${DEPS}/$1" dest="${OUT}/arch/$1" src host
  local stamp="${dest}/.stamp"
  local recipe
  recipe="pjproject ${PJ_VERSION} ${PJ_SHA256} ${arch} macos-${MIN_MACOS} config_site $(sha_of "${CONFIG_SITE}")
${PJ_CONFIGURE_FLAGS[*]}
$(cat "${deps}/.stamp-openssl")
$(cat "${deps}/.stamp-opus")"
  step "PJSIP ${PJ_VERSION} (${arch})"
  if stamp_ok "${stamp}" "${recipe}"; then info "up to date"; return; fi
  rm -f "${stamp}"
  local tarball="${DL_DIR}/pjproject-${PJ_VERSION}.tar.gz"
  fetch "${PJ_URL}" "${PJ_SHA256}" "${tarball}"
  src="${BUILD_DIR}/${arch}/pjproject-${PJ_VERSION}"
  extract "${tarball}" "${BUILD_DIR}/${arch}" "${src}"
  [[ -x "${src}/configure" ]] || die "unexpected tarball layout (no ${src}/configure)"
  cp "${CONFIG_SITE}" "${src}/pjlib/include/pj/config_site.h"
  info "config_site.h -> pjlib/include/pj/config_site.h"
  host="$(arch_host "${arch}")"

  (
    cd "${src}"
    local flags; flags="$(arch_cflags "${arch}")"
    export MACOSX_DEPLOYMENT_TARGET="${MIN_MACOS}"
    export CC=clang CXX=clang++
    export CFLAGS="${flags} -O2 -g -fno-common"
    export CXXFLAGS="${flags} -O2 -g"
    export LDFLAGS="${flags}"
    # Only our own dependency prefix is visible to pkg-config (nothing from Homebrew).
    export PKG_CONFIG_LIBDIR="${deps}/lib/pkgconfig"
    info "CFLAGS=${CFLAGS}"
    run_logged "${arch}/pjsip-configure" ./configure ${host:+"${host}"} \
      --prefix="${dest}/.stage" "${PJ_CONFIGURE_FLAGS[@]}" \
      --with-ssl="${deps}" --with-opus="${deps}"

    local cfg_log="${LOG_DIR}/${arch}/pjsip-configure.log"
    grep -q "OpenSSL library found, SSL support enabled" "${cfg_log}" || die "configure did not enable OpenSSL"
    grep -q "OPUS library found, OPUS support enabled" "${cfg_log}" || die "configure did not enable Opus"
    # G.722.1, GSM, iLBC and Speex come from pjproject's third_party tree (26.2).
    for c in "GSM codec" "G.722.1 codec" "iLBC codec" "Speex codec"; do
      if grep -q "Checking if ${c} is disabled...yes" "${cfg_log}"; then die "configure disabled the ${c}"; fi
    done
    grep -E "sound device backend|webrtc|SSL support|OPUS support" "${cfg_log}" | sed 's/^/    | /' | head -10 || true

    run_logged "${arch}/pjsip-make-dep" make dep
    run_logged "${arch}/pjsip-make" make -j"${JOBS}"
  )

  local target_name pjsua_bin
  target_name="$(sed -n 's/^export TARGET_NAME := *//p' "${src}/build.mak" | tr -d ' ')"
  [[ -n "${target_name}" ]] || die "could not determine TARGET_NAME from build.mak"
  pjsua_bin="${src}/pjsip-apps/bin/pjsua-${target_name}"
  [[ -x "${pjsua_bin}" ]] || die "pjsua was not built (${pjsua_bin})"
  info "target: ${target_name}"

  rm -rf "${dest}"
  mkdir -p "${dest}/lib" "${dest}/bin"
  ( cd "${src}" && run_logged "${arch}/pjsip-install" make install )
  mv "${dest}/.stage/include" "${dest}/include"
  # Strip the host-triple suffix (libpj-aarch64-apple-darwin27.2.0.a -> libpj.a) so link
  # flags stay stable across macOS updates and match between architectures.
  for a in "${dest}/.stage/lib/"*.a; do
    local base; base="$(basename "${a}")"
    cp "${a}" "${dest}/lib/${base/-${target_name}.a/.a}"
  done
  rm -rf "${dest}/.stage"
  cp "${pjsua_bin}" "${dest}/bin/pjsua"
  for lib in gsmcodec ilbccodec speex g7221codec; do
    [[ -f "${dest}/lib/lib${lib}.a" ]] || die "lib${lib}.a was not built (codec missing)"
  done
  for f in "${dest}/bin/pjsua" "${dest}/lib/"*.a; do check_slice "${f}" "${arch}"; done
  if otool -L "${dest}/bin/pjsua" | grep -q /opt/homebrew; then
    die "${dest}/bin/pjsua links a Homebrew dylib"
  fi

  # Link and compile flags, from pjproject's own build.mak.
  local print_mk="${LOG_DIR}/${arch}/print-flags.mak" ldlibs install_cflags tok
  cat >"${print_mk}" <<'MK'
include build.mak
print-ldlibs:  ; @echo $(PJ_LDLIBS)
print-cflags:  ; @echo $(PJ_INSTALL_CFLAGS)
MK
  ldlibs="$(cd "${src}" && make -s -f "${print_mk}" print-ldlibs)"
  install_cflags="$(cd "${src}" && make -s -f "${print_mk}" print-cflags)"
  local libs_out=()
  for tok in ${ldlibs}; do
    case "${tok}" in -L*) continue ;; esac     # library dirs are set below, per layout
    libs_out+=("${tok/-${target_name}/}")
  done
  printf '%s\n' "${libs_out[*]}" >"${dest}/LDLIBS"
  printf '%s\n' "${install_cflags}" | sed "s#-I${dest}/.stage/include##g; s#  *# #g; s#^ *##; s# *\$##" >"${dest}/CFLAGS"

  [[ "${KEEP_BUILD:-0}" == 1 ]] || rm -rf "${src}"
  printf '%s' "${recipe}" >"${stamp}"
}

for arch in "${ARCHS[@]}"; do
  build_openssl "${arch}"
  build_opus "${arch}"
  build_pjsip "${arch}"
done
[[ "${KEEP_BUILD:-0}" == 1 ]] || rm -rf "${BUILD_DIR}"

# ---------------------------------------------------------------- universal ---
# lipo the per-arch archives together; headers must be identical across architectures.
step "Universal libraries (${ARCHS[*]})"
FIRST="${ARCHS[0]}"
UNI_RECIPE=""
for arch in "${ARCHS[@]}"; do
  UNI_RECIPE+="$(cat "${DEPS}/${arch}/.stamp-openssl" "${DEPS}/${arch}/.stamp-opus" "${OUT}/arch/${arch}/.stamp")"$'\n'
done
UNI_STAMP="${OUT}/.stamp-universal"
UNI_DEPS="${DEPS}/universal"

if stamp_ok "${UNI_STAMP}" "${UNI_RECIPE}" && [[ -f "${OUT}/LINKFLAGS" && -d "${UNI_DEPS}/lib" ]]; then
  info "up to date"
else
  rm -f "${UNI_STAMP}"
  for arch in "${ARCHS[@]:1}"; do
    cmp -s "${OUT}/arch/${FIRST}/LDLIBS" "${OUT}/arch/${arch}/LDLIBS" \
      || die "PJSIP link libraries differ between ${FIRST} and ${arch}"
    cmp -s "${OUT}/arch/${FIRST}/CFLAGS" "${OUT}/arch/${arch}/CFLAGS" \
      || die "PJSIP consumer CFLAGS differ between ${FIRST} and ${arch}"
  done

  rm -rf "${UNI_DEPS}"
  mkdir -p "${UNI_DEPS}/lib"
  with_per_arch "${DEPS}/@ARCH@/include" merge_headers "${UNI_DEPS}/include"
  for lib in libssl.a libcrypto.a libopus.a; do
    with_per_arch "${DEPS}/@ARCH@/lib/${lib}" lipo -output "${UNI_DEPS}/lib/${lib}" -create
    check_universal "${UNI_DEPS}/lib/${lib}"
  done

  rm -rf "${OUT}/include" "${OUT}/lib" "${OUT}/bin"
  mkdir -p "${OUT}/lib" "${OUT}/bin"
  with_per_arch "${OUT}/arch/@ARCH@/include" merge_headers "${OUT}/include"
  for a in "${OUT}/arch/${FIRST}/lib/"*.a; do
    lib="$(basename "${a}")"
    with_per_arch "${OUT}/arch/@ARCH@/lib/${lib}" lipo -output "${OUT}/lib/${lib}" -create
    check_universal "${OUT}/lib/${lib}"
  done
  with_per_arch "${OUT}/arch/@ARCH@/bin/pjsua" lipo -output "${OUT}/bin/pjsua" -create
  check_universal "${OUT}/bin/pjsua"

  # LINKFLAGS: everything needed to link an executable against the universal libraries.
  LINKFLAGS="-L${OUT}/lib $(cat "${OUT}/arch/${FIRST}/LDLIBS") -L${UNI_DEPS}/lib -lc++"
  # De-duplicate tokens while keeping order (frameworks are '-framework X' pairs).
  LINKFLAGS="$(echo "${LINKFLAGS}" | awk '{
    out=""; for(i=1;i<=NF;i++){ t=$i; if(t=="-framework"){ t=t" "$(++i) }
      if(!(t in seen)){ seen[t]=1; out=out (out==""?"":" ") t } } print out }')"
  printf '%s\n' "${LINKFLAGS}" >"${OUT}/LINKFLAGS"
  # Consumers must see the same feature macros as the library build.
  printf '%s\n' "-I${OUT}/include $(cat "${OUT}/arch/${FIRST}/CFLAGS")" | sed 's# *$##' >"${OUT}/CFLAGS"
  printf '%s' "${UNI_RECIPE}" >"${UNI_STAMP}"
fi

# ---------------------------------------------------------------- summary ---
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
step "Done in $((ELAPSED / 60))m $((ELAPSED % 60))s"
info "pjproject   : ${PJ_VERSION}, OpenSSL ${OPENSSL_VERSION}, Opus ${OPUS_VERSION}; macOS >= ${MIN_MACOS}, static"
info "deps        : third_party/deps/universal/lib"
for a in "${UNI_DEPS}/lib/"*.a; do info "              $(basename "${a}")  ($(lipo -archs "${a}"), $(du -h "${a}" | awk '{print $1}'))"; done
info "headers     : third_party/pjsip/include ($(find "${OUT}/include" -name '*.h' | wc -l | tr -d ' ') files)"
info "libraries   : third_party/pjsip/lib ($(lipo -archs "${OUT}/lib/libpj.a"))"
for a in "${OUT}/lib/"*.a; do info "              $(basename "${a}")  ($(du -h "${a}" | awk '{print $1}'))"; done
info "cli         : third_party/pjsip/bin/pjsua ($(lipo -archs "${OUT}/bin/pjsua"), version $("${OUT}/bin/pjsua" --version 2>&1 | awk '/PJ_VERSION/{print $NF; exit}'))"
info "LINKFLAGS   : third_party/pjsip/LINKFLAGS"
info "CFLAGS      : third_party/pjsip/CFLAGS -> $(cat "${OUT}/CFLAGS")"
info "logs        : third_party/build-logs/<arch>/"
