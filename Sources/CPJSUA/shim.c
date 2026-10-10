/*
 * CPJSUA shim: tiny C helpers for what Swift cannot call directly
 * (inline/macro-based PJ APIs, mutable char * signatures, compile-time flags).
 */
#include "CPJSUA.h"

#include <string.h>

pj_str_t cpjsua_str(const char *s)
{
    pj_str_t r;
    r.ptr = (char *)s;
    r.slen = s ? (pj_ssize_t)strlen(s) : 0;
    return r;
}

size_t cpjsua_str_copy(const pj_str_t *s, char *buf, size_t buf_len)
{
    size_t n;
    if (!buf || buf_len == 0)
        return 0;
    if (!s || !s->ptr || s->slen <= 0) {
        buf[0] = '\0';
        return 0;
    }
    n = (size_t)s->slen;
    if (n >= buf_len)
        n = buf_len - 1;
    memcpy(buf, s->ptr, n);
    buf[n] = '\0';
    return n;
}

int cpjsua_succeeded(pj_status_t status)
{
    return status == PJ_SUCCESS;
}

const char *cpjsua_strerror(pj_status_t status, char *buf, size_t buf_len)
{
    if (!buf || buf_len == 0)
        return "";
    pj_strerror(status, buf, (pj_size_t)buf_len);
    buf[buf_len - 1] = '\0';
    return buf;
}

const char *cpjsua_version(void)
{
    return pj_get_version();
}

int cpjsua_has_tls(void)        { return PJSIP_HAS_TLS_TRANSPORT ? 1 : 0; }
int cpjsua_has_srtp(void)       { return PJMEDIA_HAS_SRTP ? 1 : 0; }
int cpjsua_has_ipv6(void)       { return PJ_HAS_IPV6 ? 1 : 0; }
int cpjsua_has_webrtc_aec(void) { return PJMEDIA_HAS_WEBRTC_AEC ? 1 : 0; }
int cpjsua_has_video(void)      { return PJMEDIA_HAS_VIDEO ? 1 : 0; }

const char *cpjsua_ssl_backend(void)
{
#if !defined(PJ_HAS_SSL_SOCK) || PJ_HAS_SSL_SOCK == 0
    return "none";
#elif PJ_SSL_SOCK_IMP == PJ_SSL_SOCK_IMP_OPENSSL
    return "openssl";
#elif PJ_SSL_SOCK_IMP == PJ_SSL_SOCK_IMP_DARWIN
    return "darwin";
#elif PJ_SSL_SOCK_IMP == PJ_SSL_SOCK_IMP_GNUTLS
    return "gnutls";
#elif PJ_SSL_SOCK_IMP == PJ_SSL_SOCK_IMP_MBEDTLS
    return "mbedtls";
#else
    return "other";
#endif
}

void cpjsua_call_setting_defaults(pjsua_call_setting *opt)
{
    if (!opt)
        return;
    pjsua_call_setting_default(opt);
    opt->aud_cnt = 1;
    opt->vid_cnt = 0;
}

pj_status_t cpjsua_transport_create(pjsip_transport_type_e type,
                                    unsigned port,
                                    pjsua_transport_id *out_id)
{
    pjsua_transport_config cfg;
    pjsua_transport_id tid = PJSUA_INVALID_ID;
    pj_status_t status;

    pjsua_transport_config_default(&cfg);
    cfg.port = port;
    status = pjsua_transport_create(type, &cfg, &tid);
    if (out_id)
        *out_id = tid;
    return status;
}

unsigned cpjsua_transport_port(pjsua_transport_id id)
{
    pjsua_transport_info info;
    if (pjsua_transport_get_info(id, &info) != PJ_SUCCESS)
        return 0;
    return pj_sockaddr_get_port(&info.local_addr);
}
