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

/** pjsua_call_setting_default() + audio-only (vid_cnt = 0, txt_cnt = 0). */
void cpjsua_call_setting_defaults(pjsua_call_setting *opt);

/** Create a SIP transport of `type` (UDP/TCP/TLS, optionally IPv6) on `port`
 *  (0 = random). Writes the transport id to *out_id on success. */
pj_status_t cpjsua_transport_create(pjsip_transport_type_e type,
                                    unsigned port,
                                    pjsua_transport_id *out_id);

/** Like cpjsua_transport_create, but binds to and advertises `address`
 *  (bound_addr = public_addr) when it is non-NULL and non-empty. */
pj_status_t cpjsua_transport_create2(pjsip_transport_type_e type,
                                     unsigned port,
                                     const char *address,
                                     pjsua_transport_id *out_id);

/** Bound port of a transport, or 0 if unknown. */
unsigned cpjsua_transport_port(pjsua_transport_id id);

/* ------------------------------------------------------------ threads --- */

/** Register the calling thread with pjlib if pjsua exists and the thread is
 *  not registered yet. The pj_thread_desc lives in C11 thread-local storage,
 *  so it stays valid for the lifetime of the thread (GCD worker threads are
 *  reused, so registration happens once per thread per pjsua instance).
 *  Returns PJ_SUCCESS when the thread may call pjsua, PJ_EINVALIDOP when
 *  pjsua has not been created. */
pj_status_t cpjsua_thread_register(void);

/* -------------------------------------------------------------- calls --- */

/** Flat, self-contained copy of pjsua_call_info plus audio stream details.
 *  Unlike pjsua_call_info it holds no pointers into itself, so Swift can copy it. */
typedef struct cpjsua_call_snapshot {
    pjsua_call_id           id;
    pjsua_acc_id            acc_id;
    int                     is_outgoing;        /* role == PJSIP_ROLE_UAC */
    pjsip_inv_state         state;
    int                     last_status;
    char                    last_status_text[128];
    char                    remote_info[PJSIP_MAX_URL_SIZE];
    char                    remote_contact[PJSIP_MAX_URL_SIZE];
    char                    sip_call_id[128];
    pjsua_call_media_status media_status;       /* of the first audio media */
    pjsua_conf_port_id      conf_slot;
    long                    connect_msec;       /* connect_duration in ms */
    void                   *user_data;
    int                     has_audio_stream;
    char                    codec[64];          /* "opus/48000", "" if none */
    int                     is_secure;          /* SRTP active on audio */
} cpjsua_call_snapshot;

/** Fill *out for call_id. Returns PJ_SUCCESS, or the pjsua_call_get_info error. */
pj_status_t cpjsua_call_snapshot_get(pjsua_call_id call_id, cpjsua_call_snapshot *out);

/** user_data as an integer (MacroSIP stores a per-call serial there). */
unsigned long long cpjsua_call_serial(pjsua_call_id call_id);
pj_status_t cpjsua_call_set_serial(pjsua_call_id call_id, unsigned long long serial);

/** Number of calls that are not hanging up (pjsua_call_is_active). */
unsigned cpjsua_active_call_count(void);

/** Fill ids[] with every call id pjsua knows about. Returns the count. */
unsigned cpjsua_enum_calls(pjsua_call_id *ids, unsigned max);

/** RTP counters of the first audio stream (from pjsua_call_get_stream_stat). */
typedef struct cpjsua_rtp_stat {
    unsigned rx_packets;
    unsigned tx_packets;
    unsigned rx_lost;
    unsigned rx_jitter_usec_mean;
    unsigned rtt_usec_mean;
} cpjsua_rtp_stat;
pj_status_t cpjsua_call_rtp_stat(pjsua_call_id call_id, cpjsua_rtp_stat *out);

/** Send DTMF with RFC 2833; when the remote did not offer telephone-event,
 *  fall back to SIP INFO. *used_info is set to 1 when INFO was used. */
pj_status_t cpjsua_call_send_dtmf(pjsua_call_id call_id, const char *digits, int *used_info);

/** Answer (code 200..699) with audio-only call settings. */
pj_status_t cpjsua_call_answer(pjsua_call_id call_id, unsigned code);

/** Outgoing call with audio-only settings; serial goes into user_data. */
pj_status_t cpjsua_call_make(pjsua_acc_id acc_id, const char *uri,
                             unsigned long long serial, pjsua_call_id *out_id);

/** Re-INVITE with PJSUA_CALL_UNHOLD (audio only). */
pj_status_t cpjsua_call_unhold(pjsua_call_id call_id);

/* ---------------------------------------------------- conference bridge --- */

/** 1 if src currently transmits to sink (per pjsua_conf_get_port_info). */
int cpjsua_conf_is_connected(pjsua_conf_port_id src, pjsua_conf_port_id sink);

/* -------------------------------------------------------------- tones --- */

/** Create a tone generator port that loops (freq1+freq2, on_ms / off_ms)
 *  with the conference bridge's clock rate and frame size. */
pj_status_t cpjsua_tonegen_create(pj_pool_t *pool,
                                  unsigned freq1, unsigned freq2,
                                  unsigned on_ms, unsigned off_ms,
                                  pjmedia_port **out_port);

/** Create a looping WAV file player port (20 ms frames). */
pj_status_t cpjsua_wav_loop_create(pj_pool_t *pool, const char *path,
                                   pjmedia_port **out_port);

/** Open `dev_id` as a playback-only sound port matching `port`'s format
 *  and connect `port` to it (used for a ringtone on a separate device). */
pj_status_t cpjsua_snd_port_play(pj_pool_t *pool, int dev_id, pjmedia_port *port,
                                 pjmedia_snd_port **out_snd);

void cpjsua_snd_port_close(pjmedia_snd_port *snd);

/* ------------------------------------------------------------- codecs --- */

typedef struct cpjsua_codec_entry {
    char     id[64];
    unsigned priority;
} cpjsua_codec_entry;

/** Enumerate codecs. *count is in/out. */
pj_status_t cpjsua_codecs(cpjsua_codec_entry *out, unsigned *count);

/* -------------------------------------------------------- audio devices --- */

typedef struct cpjsua_aud_dev_entry {
    int      id;
    char     name[PJMEDIA_AUD_DEV_INFO_NAME_LEN];
    char     driver[32];
    unsigned input_count;
    unsigned output_count;
} cpjsua_aud_dev_entry;

/** Enumerate audio devices (pjsua_enum_aud_devs). *count is in/out. */
pj_status_t cpjsua_aud_devs(cpjsua_aud_dev_entry *out, unsigned *count);

/** Select capture/playback devices without opening them immediately.
 *  Use PJMEDIA_AUD_DEFAULT_CAPTURE_DEV / PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV for defaults. */
pj_status_t cpjsua_set_snd_devs(int capture_dev, int playback_dev);

/* --------------------------------------------------------- error codes --- */

pj_status_t cpjsua_err_no_rfc2833(void);   /* PJMEDIA_RTP_EREMNORFC2833 */
pj_status_t cpjsua_err_not_found(void);    /* PJ_ENOTFOUND */

#endif /* CPJSUA_H */
