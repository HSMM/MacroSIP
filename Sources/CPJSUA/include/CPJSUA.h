/*
 * CPJSUA - umbrella header exposing PJSUA (pjproject 2.17) to Swift.
 *
 * This is the only place in MacroSIP that includes PJSIP headers.
 * The headers come from third_party/pjsip/include (see scripts/build-pjsip.sh).
 */
#ifndef CPJSUA_H
#define CPJSUA_H

/* The libraries were built with autoconf; consumers must see the same
 * pj/compat/os_auto.h and pj/config_site.h (mirrors third_party/pjsip/CFLAGS). */
#ifndef PJ_AUTOCONF
#  define PJ_AUTOCONF 1
#endif
#ifndef PJ_IS_BIG_ENDIAN
#  define PJ_IS_BIG_ENDIAN 0
#endif
#ifndef PJ_IS_LITTLE_ENDIAN
#  define PJ_IS_LITTLE_ENDIAN 1
#endif

#include <pjsua-lib/pjsua.h>
#include <pjmedia-audiodev/audiodev.h>

#include <stddef.h>

/* ----------------------------------------------------------- strings --- */

/** pj_str() taking a const C string (Swift passes String as const char *).
 *  The returned pj_str_t borrows the pointer; it must outlive the use. */
pj_str_t cpjsua_str(const char *s);

/** Copy a pj_str_t into a NUL-terminated buffer. Returns bytes copied (without NUL). */
size_t cpjsua_str_copy(const pj_str_t *s, char *buf, size_t buf_len);

/* ------------------------------------------------------------ status --- */

/** 1 when status == PJ_SUCCESS. */
int cpjsua_succeeded(pj_status_t status);

/** pj_strerror() into buf, always NUL-terminated. Returns buf. */
const char *cpjsua_strerror(pj_status_t status, char *buf, size_t buf_len);

/* ----------------------------------------------------------- version --- */

/** PJ_VERSION string, e.g. "2.17". */
const char *cpjsua_version(void);

/* ---------------------------------------------- compiled-in features --- */

int cpjsua_has_tls(void);         /* PJSIP_HAS_TLS_TRANSPORT */
int cpjsua_has_srtp(void);        /* PJMEDIA_HAS_SRTP */
int cpjsua_has_ipv6(void);        /* PJ_HAS_IPV6 */
int cpjsua_has_webrtc_aec(void);  /* PJMEDIA_HAS_WEBRTC_AEC */
int cpjsua_has_video(void);       /* PJMEDIA_HAS_VIDEO */
/** Name of the SSL backend ("openssl", "darwin", "gnutls", "mbedtls", "none"). */
const char *cpjsua_ssl_backend(void);

/* ------------------------------------------------------------ config --- */

/** pjsua_call_setting_default() + audio-only (vid_cnt = 0). */
void cpjsua_call_setting_defaults(pjsua_call_setting *opt);

/** Create a SIP transport of `type` (UDP/TCP/TLS, optionally IPv6) on `port`
 *  (0 = random). Writes the transport id to *out_id on success. */
pj_status_t cpjsua_transport_create(pjsip_transport_type_e type,
                                    unsigned port,
                                    pjsua_transport_id *out_id);

/** Bound port of a transport, or 0 if unknown. */
unsigned cpjsua_transport_port(pjsua_transport_id id);

#endif /* CPJSUA_H */
