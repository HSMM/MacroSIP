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
