/*
 * CPJSUA shim: tiny C helpers for what Swift cannot call directly
 * (inline/macro-based PJ APIs, mutable char * signatures, compile-time flags).
 */
#include "CPJSUA.h"

#include <ctype.h>
#include <stdlib.h>
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
    opt->txt_cnt = 0;   /* no RFC 4103 real-time text m-line (default is 1) */
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

pj_status_t cpjsua_transport_create2(pjsip_transport_type_e type,
                                     unsigned port,
                                     const char *address,
                                     pjsua_transport_id *out_id)
{
    pjsua_transport_config cfg;
    pjsua_transport_id tid = PJSUA_INVALID_ID;
    pj_status_t status;

    pjsua_transport_config_default(&cfg);
    cfg.port = port;
    if (address && *address) {
        cfg.bound_addr = cpjsua_str(address);
        cfg.public_addr = cpjsua_str(address);
    }
    status = pjsua_transport_create(type, &cfg, &tid);
    if (out_id)
        *out_id = tid;
    return status;
}

pj_status_t cpjsua_tls_transport_create(unsigned port,
                                        const char *address,
                                        int verify_server,
                                        const char *ca_file,
                                        pjsua_transport_id *out_id)
{
    pjsua_transport_config cfg;
    pjsua_transport_id tid = PJSUA_INVALID_ID;
    pj_status_t status;

    pjsua_transport_config_default(&cfg);
    cfg.port = port;
    if (address && *address) {
        cfg.bound_addr = cpjsua_str(address);
        cfg.public_addr = cpjsua_str(address);
    }
    cfg.tls_setting.verify_server = verify_server ? PJ_TRUE : PJ_FALSE;
    cfg.tls_setting.verify_client = PJ_FALSE;
    cfg.tls_setting.require_client_cert = PJ_FALSE;
    if (ca_file && *ca_file)
        cfg.tls_setting.ca_list_file = cpjsua_str(ca_file);
    status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &cfg, &tid);
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

/* ============================================================ threads === */

pj_status_t cpjsua_thread_register(void)
{
    /* Thread-local so the descriptor outlives the registration. */
    static _Thread_local pj_thread_desc desc;
    static _Thread_local pj_thread_t *thread;

    if (pjsua_get_state() == PJSUA_STATE_NULL)
        return PJ_EINVALIDOP;
    if (pj_thread_is_registered())
        return PJ_SUCCESS;
    pj_bzero(desc, sizeof(desc));
    thread = NULL;
    return pj_thread_register("macrosip", desc, &thread);
}

/* ============================================================== calls === */

static void copy_pjstr(const pj_str_t *s, char *buf, size_t len)
{
    cpjsua_str_copy(s, buf, len);
}

static int first_audio_index(const pjsua_call_info *ci)
{
    unsigned i;
    for (i = 0; i < ci->media_cnt; ++i) {
        if (ci->media[i].type == PJMEDIA_TYPE_AUDIO)
            return (int)i;
    }
    return -1;
}

pj_status_t cpjsua_call_snapshot_get(pjsua_call_id call_id, cpjsua_call_snapshot *out)
{
    pjsua_call_info ci;
    pj_status_t status;
    int aud;

    if (!out)
        return PJ_EINVAL;
    pj_bzero(out, sizeof(*out));
    out->id = call_id;
    out->conf_slot = PJSUA_INVALID_ID;

    if (call_id < 0 || call_id >= (int)pjsua_call_get_max_count())
        return PJ_EINVAL;
    status = pjsua_call_get_info(call_id, &ci);
    if (status != PJ_SUCCESS)
        return status;

    out->acc_id = ci.acc_id;
    out->is_outgoing = (ci.role == PJSIP_ROLE_UAC) ? 1 : 0;
    out->state = ci.state;
    out->last_status = (int)ci.last_status;
    copy_pjstr(&ci.last_status_text, out->last_status_text, sizeof(out->last_status_text));
    copy_pjstr(&ci.remote_info, out->remote_info, sizeof(out->remote_info));
    copy_pjstr(&ci.remote_contact, out->remote_contact, sizeof(out->remote_contact));
    copy_pjstr(&ci.call_id, out->sip_call_id, sizeof(out->sip_call_id));
    out->media_status = ci.media_status;
    out->conf_slot = ci.conf_slot;
    out->connect_msec = (long)ci.connect_duration.sec * 1000 + ci.connect_duration.msec;
    out->user_data = pjsua_call_get_user_data(call_id);

    aud = first_audio_index(&ci);
    if (aud >= 0) {
        pjsua_stream_info si;
        pjmedia_transport_info tpinfo;

        out->media_status = ci.media[aud].status;
        out->conf_slot = ci.media[aud].stream.aud.conf_slot;

        if (pjsua_call_get_stream_info(call_id, (unsigned)aud, &si) == PJ_SUCCESS &&
            si.type == PJMEDIA_TYPE_AUDIO)
        {
            const pjmedia_codec_info *fmt = &si.info.aud.fmt;
            out->has_audio_stream = 1;
            pj_ansi_snprintf(out->codec, sizeof(out->codec), "%.*s/%u",
                             (int)fmt->encoding_name.slen, fmt->encoding_name.ptr,
                             fmt->clock_rate);
        }

        pjmedia_transport_info_init(&tpinfo);
        if (pjsua_call_get_med_transport_info(call_id, (unsigned)aud, &tpinfo) == PJ_SUCCESS) {
#if defined(PJMEDIA_HAS_SRTP) && PJMEDIA_HAS_SRTP != 0
            pjmedia_srtp_info *srtp = (pjmedia_srtp_info *)
                pjmedia_transport_info_get_spc_info(&tpinfo, PJMEDIA_TRANSPORT_TYPE_SRTP);
            out->is_secure = (srtp && srtp->active) ? 1 : 0;
#endif
        }
    }
    return PJ_SUCCESS;
}

unsigned long long cpjsua_call_serial(pjsua_call_id call_id)
{
    if (call_id < 0 || call_id >= (int)pjsua_call_get_max_count())
        return 0;
    return (unsigned long long)(pj_size_t)pjsua_call_get_user_data(call_id);
}

pj_status_t cpjsua_call_set_serial(pjsua_call_id call_id, unsigned long long serial)
{
    if (call_id < 0 || call_id >= (int)pjsua_call_get_max_count())
        return PJ_EINVAL;
    return pjsua_call_set_user_data(call_id, (void *)(pj_size_t)serial);
}

unsigned cpjsua_active_call_count(void)
{
    pjsua_call_id ids[PJSUA_MAX_CALLS];
    unsigned count = PJ_ARRAY_SIZE(ids), i, active = 0;
    if (pjsua_enum_calls(ids, &count) != PJ_SUCCESS)
        return 0;
    for (i = 0; i < count; ++i) {
        if (pjsua_call_is_active(ids[i]))
            ++active;
    }
    return active;
}

unsigned cpjsua_enum_calls(pjsua_call_id *ids, unsigned max)
{
    unsigned count = max;
    if (!ids || max == 0)
        return 0;
    if (pjsua_enum_calls(ids, &count) != PJ_SUCCESS)
        return 0;
    return count;
}

pj_status_t cpjsua_call_rtp_stat(pjsua_call_id call_id, cpjsua_rtp_stat *out)
{
    pjsua_call_info ci;
    pjsua_stream_stat st;
    pj_status_t status;
    int aud;

    if (!out)
        return PJ_EINVAL;
    pj_bzero(out, sizeof(*out));
    status = pjsua_call_get_info(call_id, &ci);
    if (status != PJ_SUCCESS)
        return status;
    aud = first_audio_index(&ci);
    if (aud < 0)
        return PJ_ENOTFOUND;
    status = pjsua_call_get_stream_stat(call_id, (unsigned)aud, &st);
    if (status != PJ_SUCCESS)
        return status;
    out->rx_packets = st.rtcp.rx.pkt;
    out->tx_packets = st.rtcp.tx.pkt;
    out->rx_lost = st.rtcp.rx.loss;
    out->rx_jitter_usec_mean = st.rtcp.rx.jitter.mean;
    out->rtt_usec_mean = st.rtcp.rtt.mean;
    return PJ_SUCCESS;
}

pj_status_t cpjsua_call_send_dtmf(pjsua_call_id call_id, const char *digits, int *used_info)
{
    pjsua_call_send_dtmf_param param;
    pj_status_t status;

    if (used_info)
        *used_info = 0;
    if (!digits || !*digits)
        return PJ_EINVAL;

    pjsua_call_send_dtmf_param_default(&param);
    param.method = PJSUA_DTMF_METHOD_RFC2833;
    param.duration = PJSUA_CALL_SEND_DTMF_DURATION_DEFAULT;
    param.digits = cpjsua_str(digits);
    status = pjsua_call_send_dtmf(call_id, &param);
    if (status == PJMEDIA_RTP_EREMNORFC2833) {
        param.method = PJSUA_DTMF_METHOD_SIP_INFO;
        status = pjsua_call_send_dtmf(call_id, &param);
        if (used_info)
            *used_info = 1;
    }
    return status;
}

pj_status_t cpjsua_call_answer(pjsua_call_id call_id, unsigned code)
{
    pjsua_call_setting opt;
    cpjsua_call_setting_defaults(&opt);
    return pjsua_call_answer2(call_id, &opt, code, NULL, NULL);
}

pj_status_t cpjsua_call_make(pjsua_acc_id acc_id, const char *uri,
                             unsigned long long serial, pjsua_call_id *out_id)
{
    pjsua_call_setting opt;
    pj_str_t dst;
    pjsua_call_id cid = PJSUA_INVALID_ID;
    pj_status_t status;

    if (!uri)
        return PJ_EINVAL;
    cpjsua_call_setting_defaults(&opt);
    dst = cpjsua_str(uri);
    status = pjsua_call_make_call(acc_id, &dst, &opt, (void *)(pj_size_t)serial, NULL, &cid);
    if (out_id)
        *out_id = cid;
    return status;
}

pj_status_t cpjsua_call_unhold(pjsua_call_id call_id)
{
    pjsua_call_setting opt;
    cpjsua_call_setting_defaults(&opt);
    opt.flag |= PJSUA_CALL_UNHOLD;
    return pjsua_call_reinvite2(call_id, &opt, NULL);
}

/* ================================================== conference bridge === */

int cpjsua_conf_is_connected(pjsua_conf_port_id src, pjsua_conf_port_id sink)
{
    pjsua_conf_port_info info;
    unsigned i;
    if (pjsua_conf_get_port_info(src, &info) != PJ_SUCCESS)
        return 0;
    for (i = 0; i < info.listener_cnt; ++i) {
        if (info.listeners[i] == sink)
            return 1;
    }
    return 0;
}

/* ========================================================== recorder === */

pj_status_t cpjsua_recorder_create(const char *path, pjsua_recorder_id *out_id,
                                   pjsua_conf_port_id *out_slot)
{
    pj_str_t file;
    pjsua_recorder_id rid = PJSUA_INVALID_ID;
    pj_status_t status;

    if (!path || !out_id || !out_slot)
        return PJ_EINVAL;
    *out_id = PJSUA_INVALID_ID;
    *out_slot = PJSUA_INVALID_ID;
    file = cpjsua_str(path);
    /* enc_type 0, no encoder parameter, no size limit, options 0 = 16-bit PCM. */
    status = pjsua_recorder_create(&file, 0, NULL, -1, 0, &rid);
    if (status != PJ_SUCCESS)
        return status;
    *out_id = rid;
    *out_slot = pjsua_recorder_get_conf_port(rid);
    return PJ_SUCCESS;
}

/* Group lock handler: runs after the WAV writer's own on_destroy (handlers run in the
 * order they were added; the port's handler is the first), i.e. after the header update. */
static void recorder_port_destroyed(void *arg)
{
    __atomic_store_n((int *)arg, 1, __ATOMIC_RELEASE);
}

pj_status_t cpjsua_recorder_destroy_wait(pjsua_recorder_id id, unsigned timeout_ms,
                                         int *finalised)
{
    pjmedia_port *port = NULL;
    int *done = NULL;
    unsigned waited = 0;
    pj_status_t status;

    if (finalised)
        *finalised = 0;
    if (pjsua_recorder_get_port(id, &port) == PJ_SUCCESS && port && port->grp_lock) {
        done = (int *)calloc(1, sizeof(int));
        if (done && pj_grp_lock_add_handler(port->grp_lock, NULL, done,
                                            &recorder_port_destroyed) != PJ_SUCCESS)
        {
            free(done);
            done = NULL;
        }
    }

    status = pjsua_recorder_destroy(id);
    if (status != PJ_SUCCESS || !done)
        return status;   /* `done` stays registered (and allocated) if destroy failed */

    while (!__atomic_load_n(done, __ATOMIC_ACQUIRE) && waited < timeout_ms) {
        pj_thread_sleep(2);
        waited += 2;
    }
    if (__atomic_load_n(done, __ATOMIC_ACQUIRE)) {
        if (finalised)
            *finalised = 1;
        free(done);
    }
    /* else: the handler still owns `done` and sets it later; it is leaked on purpose. */
    return status;
}

/* ========================================================== presence === */

pj_status_t cpjsua_buddy_add(const char *uri, unsigned long long token, pjsua_buddy_id *out_id)
{
    pjsua_buddy_config cfg;

    if (!uri || !out_id)
        return PJ_EINVAL;
    pjsua_buddy_config_default(&cfg);
    cfg.uri = cpjsua_str(uri);
    cfg.subscribe = PJ_TRUE;
    cfg.user_data = (void *)(pj_size_t)token;
    return pjsua_buddy_add(&cfg, out_id);
}

unsigned cpjsua_max_buddies(void)
{
    return PJSUA_MAX_BUDDIES;
}

int cpjsua_event_notify_body_contains(const pjsip_event *event, const char *needle)
{
    const pjsip_rx_data *rdata;
    const pjsip_msg *msg;
    const char *data;
    size_t len, nlen, i, j;

    if (!event || !needle || event->type != PJSIP_EVENT_TSX_STATE ||
        event->body.tsx_state.type != PJSIP_EVENT_RX_MSG)
        return -1;
    rdata = event->body.tsx_state.src.rdata;
    if (!rdata || !(msg = rdata->msg_info.msg) || msg->type != PJSIP_REQUEST_MSG ||
        pjsip_method_cmp(&msg->line.req.method, pjsip_get_notify_method()) != 0 ||
        !msg->body || !msg->body->data || msg->body->len == 0)
        return -1;
    data = (const char *)msg->body->data;
    len = msg->body->len;
    nlen = strlen(needle);
    for (i = 0; nlen > 0 && i + nlen <= len; ++i) {
        for (j = 0; j < nlen; ++j) {
            if (tolower((unsigned char)data[i + j]) != tolower((unsigned char)needle[j]))
                break;
        }
        if (j == nlen)
            return 1;
    }
    return 0;
}

pj_status_t cpjsua_buddy_snapshot_get(pjsua_buddy_id id, cpjsua_buddy_snapshot *out)
{
    pjsua_buddy_info info;
    pj_status_t status;

    if (!out)
        return PJ_EINVAL;
    pj_bzero(out, sizeof(*out));
    if (!pjsua_buddy_is_valid(id))
        return PJ_EINVAL;
    status = pjsua_buddy_get_info(id, &info);
    if (status != PJ_SUCCESS)
        return status;
    out->token = (unsigned long long)(pj_size_t)pjsua_buddy_get_user_data(id);
    copy_pjstr(&info.uri, out->uri, sizeof(out->uri));
    out->status = info.status;
    out->activity = info.rpid.activity;
    copy_pjstr(&info.rpid.note, out->note, sizeof(out->note));
    out->sub_state = info.sub_state;
    out->term_code = info.sub_term_code;
    return PJ_SUCCESS;
}

pj_status_t cpjsua_acc_set_presence(pjsua_acc_id acc_id, int online,
                                    pjrpid_activity activity, const char *note)
{
    pjrpid_element elem;

    pj_bzero(&elem, sizeof(elem));
    elem.type = PJRPID_ELEMENT_TYPE_PERSON;
    elem.activity = activity;
    elem.note = cpjsua_str(note);
    return pjsua_acc_set_online_status2(acc_id, online ? PJ_TRUE : PJ_FALSE, &elem);
}

/* ============================================ Call-Info answer-after === */

static const char *skip_ws(const char *p)
{
    while (*p == ' ' || *p == '\t')
        ++p;
    return p;
}

/* Value of "answer-after" when `p` points at the parameter name, else -1. */
static int answer_after_at(const char *p)
{
    static const char key[] = "answer-after";
    const size_t klen = sizeof(key) - 1;
    long n = 0;

    if (pj_ansi_strnicmp(p, key, klen) != 0)
        return -1;
    p = skip_ws(p + klen);
    if (*p != '=')
        return -1;
    p = skip_ws(p + 1);
    if (*p == '"')
        ++p;
    if (!isdigit((unsigned char)*p))
        return -1;
    while (isdigit((unsigned char)*p)) {
        if (n < 86400)
            n = n * 10 + (*p - '0');
        ++p;
    }
    return n > 86400 ? 86400 : (int)n;
}

int cpjsua_parse_answer_after(const char *value)
{
    const char *p;
    int n;

    if (!value)
        return -1;
    n = answer_after_at(skip_ws(value));
    if (n >= 0)
        return n;
    for (p = value; *p; ++p) {
        if (*p != ';')
            continue;
        n = answer_after_at(skip_ws(p + 1));
        if (n >= 0)
            return n;
    }
    return -1;
}

int cpjsua_rdata_answer_after(const pjsip_rx_data *rdata)
{
    static const pj_str_t name = { "Call-Info", 9 };
    const pjsip_msg *msg;
    const pjsip_hdr *hdr;
    char buf[1024];

    if (!rdata || !(msg = rdata->msg_info.msg))
        return -1;
    hdr = (const pjsip_hdr *)pjsip_msg_find_hdr_by_name(msg, &name, NULL);
    while (hdr) {
        /* Print the whole header ("Call-Info: <...>;answer-after=0"); works for any
         * header representation (Call-Info has no dedicated parser in PJSIP). */
        int len = pjsip_hdr_print_on((void *)hdr, buf, sizeof(buf) - 1);
        if (len > 0) {
            const char *colon;
            int n;
            buf[len] = '\0';
            colon = strchr(buf, ':');
            n = cpjsua_parse_answer_after(colon ? colon + 1 : buf);
            if (n >= 0)
                return n;
        }
        hdr = (const pjsip_hdr *)pjsip_msg_find_hdr_by_name(msg, &name, hdr->next);
    }
    return -1;
}

/* ====================================================== packet source === */

pj_status_t cpjsua_rdata_source(const pjsip_rx_data *rdata, cpjsua_pkt_source *out)
{
    if (!out)
        return PJ_EINVAL;
    pj_bzero(out, sizeof(*out));
    if (!rdata)
        return PJ_EINVAL;
    pj_ansi_strxcpy(out->addr, rdata->pkt_info.src_name, sizeof(out->addr));
    out->port = rdata->pkt_info.src_port;
    if (rdata->tp_info.transport)
        out->transport = (int)(rdata->tp_info.transport->key.type & ~PJSIP_TRANSPORT_IPV6);
    return PJ_SUCCESS;
}

/* ============================================================== tones === */

pj_status_t cpjsua_tonegen_create(pj_pool_t *pool,
                                  unsigned freq1, unsigned freq2,
                                  unsigned on_ms, unsigned off_ms,
                                  pjmedia_port **out_port)
{
    pjsua_conf_port_info master;
    pjmedia_tone_desc tone;
    pjmedia_port *port = NULL;
    pj_status_t status;

    if (!pool || !out_port)
        return PJ_EINVAL;
    *out_port = NULL;

    /* Slot 0 is the sound device / master port: match its format. */
    status = pjsua_conf_get_port_info(0, &master);
    if (status != PJ_SUCCESS)
        return status;

    status = pjmedia_tonegen_create(pool, master.clock_rate, master.channel_count,
                                    master.samples_per_frame, master.bits_per_sample,
                                    0, &port);
    if (status != PJ_SUCCESS)
        return status;

    pj_bzero(&tone, sizeof(tone));
    tone.freq1 = (short)freq1;
    tone.freq2 = (short)freq2;
    tone.on_msec = (short)on_ms;
    tone.off_msec = (short)off_ms;
    status = pjmedia_tonegen_play(port, 1, &tone, PJMEDIA_TONEGEN_LOOP);
    if (status != PJ_SUCCESS) {
        pjmedia_port_destroy(port);
        return status;
    }
    *out_port = port;
    return PJ_SUCCESS;
}

pj_status_t cpjsua_wav_loop_create(pj_pool_t *pool, const char *path,
                                   pjmedia_port **out_port)
{
    if (!pool || !path || !out_port)
        return PJ_EINVAL;
    *out_port = NULL;
    /* flags 0 = loop at end of file; buff_size 0 = default. */
    return pjmedia_wav_player_port_create(pool, path, 20, 0, 0, out_port);
}

pj_status_t cpjsua_snd_port_play(pj_pool_t *pool, int dev_id, pjmedia_port *port,
                                 pjmedia_snd_port **out_snd)
{
    pjmedia_snd_port *snd = NULL;
    const pjmedia_audio_format_detail *afd;
    pj_status_t status;

    if (!pool || !port || !out_snd)
        return PJ_EINVAL;
    *out_snd = NULL;
    afd = pjmedia_format_get_audio_format_detail(&port->info.fmt, PJ_TRUE);
    status = pjmedia_snd_port_create_player(pool, dev_id, afd->clock_rate,
                                            afd->channel_count,
                                            PJMEDIA_AFD_SPF(afd),
                                            afd->bits_per_sample, 0, &snd);
    if (status != PJ_SUCCESS)
        return status;
    status = pjmedia_snd_port_connect(snd, port);
    if (status != PJ_SUCCESS) {
        pjmedia_snd_port_destroy(snd);
        return status;
    }
    *out_snd = snd;
    return PJ_SUCCESS;
}

void cpjsua_snd_port_close(pjmedia_snd_port *snd)
{
    if (!snd)
        return;
    pjmedia_snd_port_disconnect(snd);
    pjmedia_snd_port_destroy(snd);
}

/* ============================================================= codecs === */

pj_status_t cpjsua_codecs(cpjsua_codec_entry *out, unsigned *count)
{
    pjsua_codec_info info[32];
    unsigned n = PJ_ARRAY_SIZE(info), i;
    pj_status_t status;

    if (!out || !count)
        return PJ_EINVAL;
    status = pjsua_enum_codecs(info, &n);
    if (status != PJ_SUCCESS)
        return status;
    if (n > *count)
        n = *count;
    for (i = 0; i < n; ++i) {
        copy_pjstr(&info[i].codec_id, out[i].id, sizeof(out[i].id));
        out[i].priority = info[i].priority;
    }
    *count = n;
    return PJ_SUCCESS;
}

/* ====================================================== audio devices === */

pj_status_t cpjsua_aud_devs(cpjsua_aud_dev_entry *out, unsigned *count)
{
    unsigned n, i;

    if (!out || !count)
        return PJ_EINVAL;
    n = pjmedia_aud_dev_count();
    if (n > *count)
        n = *count;
    for (i = 0; i < n; ++i) {
        pjmedia_aud_dev_info info;
        pj_status_t status = pjmedia_aud_dev_get_info((pjmedia_aud_dev_index)i, &info);
        pj_bzero(&out[i], sizeof(out[i]));
        out[i].id = (int)i;
        if (status != PJ_SUCCESS)
            continue;
        pj_ansi_strxcpy(out[i].name, info.name, sizeof(out[i].name));
        pj_ansi_strxcpy(out[i].driver, info.driver, sizeof(out[i].driver));
        out[i].input_count = info.input_count;
        out[i].output_count = info.output_count;
    }
    *count = n;
    return PJ_SUCCESS;
}

pj_status_t cpjsua_set_snd_devs(int capture_dev, int playback_dev)
{
    pjsua_snd_dev_param prm;
    pjsua_snd_dev_param_default(&prm);
    prm.capture_dev = capture_dev;
    prm.playback_dev = playback_dev;
    prm.mode = PJSUA_SND_DEV_NO_IMMEDIATE_OPEN;
    return pjsua_set_snd_dev2(&prm);
}

/* ======================================================== error codes === */

pj_status_t cpjsua_err_no_rfc2833(void) { return PJMEDIA_RTP_EREMNORFC2833; }
pj_status_t cpjsua_err_not_found(void)  { return PJ_ENOTFOUND; }
pj_status_t cpjsua_err_invalid_op(void)  { return PJ_EINVALIDOP; }
pj_status_t cpjsua_err_pj_busy(void)     { return PJ_EBUSY; }
pj_status_t cpjsua_err_sip_busy(void)    { return PJSIP_EBUSY; }

unsigned cpjsua_regc_expiration_not_specified(void)
{
    return (unsigned)PJSIP_REGC_EXPIRATION_NOT_SPECIFIED;
}
