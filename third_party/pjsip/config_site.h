/*
 * MacroSIP - PJSIP site configuration (pjproject 2.17, macOS arm64 + x86_64).
 *
 * Installed by scripts/build-pjsip.sh (once per architecture, same file) into
 * third_party/build/<arch>/pjproject-2.17/pjlib/include/pj/config_site.h before configure.
 * Every define is guarded with #ifndef so build-time -D flags from pjproject's
 * generated os-auto.mak (e.g. -DPJMEDIA_HAS_WEBRTC_AEC=1) never conflict.
 *
 * Intentionally NOT defining PJ_CONFIG_MAXIMUM_SPEED (it strips checks/logging
 * we want during development).
 */
#ifndef MACROSIP_PJ_CONFIG_SITE_H
#define MACROSIP_PJ_CONFIG_SITE_H

/* ---------------------------------------------------------------- pjlib --- */

/* IPv6 sockets/resolution support (default in pj/config.h is 0). */
#ifndef PJ_HAS_IPV6
#  define PJ_HAS_IPV6                       1
#endif

/* ---------------------------------------------------------------- pjsua --- */

/* Max simultaneous calls (default 4); MicroSIP-style UI needs a few lines. */
#ifndef PJSUA_MAX_CALLS
#  define PJSUA_MAX_CALLS                   8
#endif

/* Max SIP accounts (default 8; stated explicitly for clarity). */
#ifndef PJSUA_MAX_ACC
#  define PJSUA_MAX_ACC                     8
#endif

/* Max file players / recorders (ringtones, call recording); default 32. */
#ifndef PJSUA_MAX_PLAYERS
#  define PJSUA_MAX_PLAYERS                 8
#endif
#ifndef PJSUA_MAX_RECORDERS
#  define PJSUA_MAX_RECORDERS               8
#endif

/* Conference bridge slots: calls + players + recorders + sound device + spare. */
#ifndef PJSUA_MAX_CONF_PORTS
#  define PJSUA_MAX_CONF_PORTS              (PJSUA_MAX_CALLS + PJSUA_MAX_PLAYERS + PJSUA_MAX_RECORDERS + 8)
#endif

/* ----------------------------------------------------------------- pjsip --- */

/* Cache Authorization headers so subsequent requests can be pre-authenticated. */
#ifndef PJSIP_AUTH_HEADER_CACHING
#  define PJSIP_AUTH_HEADER_CACHING         1
#endif

/* Proactively send cached credentials on the next request (needs caching). */
#ifndef PJSIP_AUTH_AUTO_SEND_NEXT
#  define PJSIP_AUTH_AUTO_SEND_NEXT         1
#endif

/* SIP over TLS follows PJ_HAS_SSL_SOCK (set by configure for OpenSSL); explicit. */
#ifndef PJSIP_HAS_TLS_TRANSPORT
#  define PJSIP_HAS_TLS_TRANSPORT           1
#endif

/* ---------------------------------------------------------------- pjmedia --- */

/* Audio-only softphone: no video subsystem (also --disable-video). */
#ifndef PJMEDIA_HAS_VIDEO
#  define PJMEDIA_HAS_VIDEO                 0
#endif

/* SRTP (SDES) media encryption using the bundled libsrtp. */
#ifndef PJMEDIA_HAS_SRTP
#  define PJMEDIA_HAS_SRTP                  1
#endif

/* DTLS-SRTP is a WebRTC-ism, not used by classic SIP softphones; keep off. */
#ifndef PJMEDIA_SRTP_HAS_DTLS
#  define PJMEDIA_SRTP_HAS_DTLS             0
#endif

/* WebRTC (classic AEC/AECM) echo canceller from bundled third_party/webrtc. */
#ifndef PJMEDIA_HAS_WEBRTC_AEC
#  define PJMEDIA_HAS_WEBRTC_AEC            1
#endif

/* Desktop flavour of WebRTC AEC (not the mobile AECM). */
#ifndef PJMEDIA_WEBRTC_AEC_USE_MOBILE
#  define PJMEDIA_WEBRTC_AEC_USE_MOBILE     0
#endif

/* Speex AEC not built (--disable-speex-aec); WebRTC AEC is used instead. */
#ifndef PJMEDIA_HAS_SPEEX_AEC
#  define PJMEDIA_HAS_SPEEX_AEC             0
#endif

/* Sample-rate conversion through bundled libresample (pjmedia default). */
#ifndef PJMEDIA_RESAMPLE_IMP
#  define PJMEDIA_RESAMPLE_IMP              PJMEDIA_RESAMPLE_LIBRESAMPLE
#endif

/* --------------------------------------------------------------- codecs --- */
/* Built: Opus (libopus built from source), G.711 PCMU/PCMA, G.722, and     */
/* since 26.2 G.722.1 (Siren7/14), GSM 06.10, iLBC, Speex (pjproject's own  */
/* third_party sources; the engine leaves the 26.2 additions disabled until */
/* the user enables them). Dropped (also disabled in configure): L16,      */
/* G.729 (bcg729), AMR, SILK, Lyra.                                         */

#ifndef PJMEDIA_HAS_G711_CODEC
#  define PJMEDIA_HAS_G711_CODEC            1
#endif
#ifndef PJMEDIA_HAS_G722_CODEC
#  define PJMEDIA_HAS_G722_CODEC            1
#endif
#ifndef PJMEDIA_HAS_SPEEX_CODEC
#  define PJMEDIA_HAS_SPEEX_CODEC           1
#endif
#ifndef PJMEDIA_HAS_ILBC_CODEC
#  define PJMEDIA_HAS_ILBC_CODEC            1
#endif
#ifndef PJMEDIA_HAS_GSM_CODEC
#  define PJMEDIA_HAS_GSM_CODEC             1
#endif
#ifndef PJMEDIA_HAS_G7221_CODEC
#  define PJMEDIA_HAS_G7221_CODEC           1
#endif
#ifndef PJMEDIA_HAS_L16_CODEC
#  define PJMEDIA_HAS_L16_CODEC             0
#endif

/* Opus: wideband-friendly defaults (48 kHz clock, VBR, complexity 5). */
#ifndef PJMEDIA_CODEC_OPUS_DEFAULT_SAMPLE_RATE
#  define PJMEDIA_CODEC_OPUS_DEFAULT_SAMPLE_RATE  48000
#endif

#endif /* MACROSIP_PJ_CONFIG_SITE_H */
