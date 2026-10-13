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

/** TLS listener (also used for outgoing TLS connections of accounts bound to it).
 *  verify_server != 0: the server certificate must chain to a CA in `ca_file` (PEM) and
 *  match the destination host name (PJSIP sets SNI and checks CN/SAN per connection).
 *  verify_client is always off; no client certificate is presented. */
pj_status_t cpjsua_tls_transport_create(unsigned port,
                                        const char *address,
                                        int verify_server,
                                        const char *ca_file,
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
    unsigned rx_jitter_usec_last;   /* RFC 3550 interarrival jitter, latest value */
    unsigned rtt_usec_last;         /* from the latest RTCP receiver report; 0 = none yet */
    unsigned rtt_samples;           /* number of RTT measurements so far */
    unsigned rtcp_rx_reports;       /* RTCP SR/RR report blocks received about our stream */
} cpjsua_rtp_stat;
pj_status_t cpjsua_call_rtp_stat(pjsua_call_id call_id, cpjsua_rtp_stat *out);

/** Send DTMF with RFC 2833; when the remote did not offer telephone-event,
 *  fall back to SIP INFO. *used_info is set to 1 when INFO was used. */
pj_status_t cpjsua_call_send_dtmf(pjsua_call_id call_id, const char *digits, int *used_info);

/** cpjsua_call_send_dtmf2 modes. */
#define CPJSUA_DTMF_AUTO      0   /* RFC 2833, SIP INFO when the remote has no telephone-event */
#define CPJSUA_DTMF_RFC2833   1   /* RFC 2833 only: PJMEDIA_RTP_EREMNORFC2833 when not offered */
#define CPJSUA_DTMF_SIP_INFO  2   /* SIP INFO (application/dtmf-relay) only */

/** Send DTMF signalled out of band (RFC 2833 and/or SIP INFO, per `mode`).
 *  *used_info is set to 1 when INFO was used. In-band tones: cpjsua_dtmf_generator_*. */
pj_status_t cpjsua_call_send_dtmf2(pjsua_call_id call_id, const char *digits, int mode, int *used_info);

/** Answer (code 200..699) with audio-only call settings. */
pj_status_t cpjsua_call_answer(pjsua_call_id call_id, unsigned code);

/** Outgoing call with audio-only settings; serial goes into user_data. */
pj_status_t cpjsua_call_make(pjsua_acc_id acc_id, const char *uri,
                             unsigned long long serial, pjsua_call_id *out_id);

/** Re-INVITE with PJSUA_CALL_UNHOLD (audio only). */
pj_status_t cpjsua_call_unhold(pjsua_call_id call_id);

/* ---------------------------------------------------- conference bridge --- */

/** Level of one existing (or queued) connection src -> sink, 0...2 (1 = unchanged); pjsua has
 *  no wrapper for pjmedia_conf_adjust_conn_level. Queued like connect/disconnect in 2.17, so a
 *  call right after pjsua_conf_connect2 applies to that connection. */
pj_status_t cpjsua_conf_adjust_conn_level(pjsua_conf_port_id src, pjsua_conf_port_id sink, float level);

/** 1 if src currently transmits to sink (per pjsua_conf_get_port_info). */
int cpjsua_conf_is_connected(pjsua_conf_port_id src, pjsua_conf_port_id sink);

/** Number of ports src transmits to (0 if src is unknown). */
unsigned cpjsua_conf_listener_count(pjsua_conf_port_id src);

/** Recorder (pjsua_recorder_create): WAV, 16-bit PCM, conference clock rate, mono.
 *  Writes the recorder id and its conference slot. `path` must end in ".wav". */
pj_status_t cpjsua_recorder_create(const char *path, pjsua_recorder_id *out_id,
                                   pjsua_conf_port_id *out_slot);

/** pjsua_recorder_destroy, then wait up to `timeout_ms` until the WAV writer port is
 *  really destroyed (PJSIP 2.17 removes conference ports on the next audio frame and
 *  only then writes the final RIFF/data sizes). *finalised = 1 when that happened in time;
 *  otherwise the header is written later, when the bridge processes the removal. */
pj_status_t cpjsua_recorder_destroy_wait(pjsua_recorder_id id, unsigned timeout_ms,
                                         int *finalised);

/** Most recorders one call can have (stereo split: two). */
#define CPJSUA_MAX_RECORDERS_PER_CALL 4

/** cpjsua_recorder_destroy_wait for several recorders at once: all are destroyed in one
 *  go (the bridge removes them on the same audio frame, so recorders that were fed from
 *  the same clock keep the same length), then the call waits up to `timeout_ms` for all of
 *  them. finalised[i] as above; the first failing destroy status is returned. 1...4 ids. */
pj_status_t cpjsua_recorders_destroy_wait(const pjsua_recorder_id *ids, unsigned count,
                                          unsigned timeout_ms, int *finalised);

/* ----------------------------------------------------------- presence --- */

/** pjsua_buddy_add with subscribe = PJ_TRUE (account chosen by pjsua per request) and
 *  `token` as user data (MacroSIP identifies watched buddies by it; ids are reused). */
pj_status_t cpjsua_buddy_add(const char *uri, unsigned long long token, pjsua_buddy_id *out_id);

/** PJSUA_MAX_BUDDIES: pjsua_buddy_add asserts (aborts in debug builds) beyond it. */
unsigned cpjsua_max_buddies(void);

/** 1 when `event` is a received NOTIFY whose body contains `needle` (ASCII,
 *  case-insensitive), 0 when it is a NOTIFY with a body without it, -1 otherwise
 *  (no NOTIFY, no body). Used for RPID activities pjrpid does not know (on-the-phone). */
int cpjsua_event_notify_body_contains(const pjsip_event *event, const char *needle);

/** Flat copy of the pjsua_buddy_info fields MacroSIP maps to a presence status. */
typedef struct cpjsua_buddy_snapshot {
    unsigned long long token;                     /* user data given to cpjsua_buddy_add */
    char               uri[PJSIP_MAX_URL_SIZE];   /* as given to pjsua_buddy_add */
    pjsua_buddy_status status;
    pjrpid_activity    activity;
    char               note[128];
    pjsip_evsub_state  sub_state;                 /* NULL when no subscription exists */
    unsigned           term_code;
} cpjsua_buddy_snapshot;

pj_status_t cpjsua_buddy_snapshot_get(pjsua_buddy_id id, cpjsua_buddy_snapshot *out);

/** pjsua_acc_set_online_status2 with a PERSON RPID element (`note` may be NULL). */
pj_status_t cpjsua_acc_set_presence(pjsua_acc_id acc_id, int online,
                                    pjrpid_activity activity, const char *note);

/* ------------------------------------------------------------- MWI --- */

/** Body of the NOTIFY behind an on_mwi_info callback (RFC 3842 message-summary), copied
 *  NUL-terminated into `buf` (truncated to `size` - 1). Returns the body length, or -1 when
 *  the callback carries no request or the request has no body. *solicited = 1 when the
 *  NOTIFY belongs to our own subscription (evsub set), 0 for an unsolicited one. */
int cpjsua_mwi_body(const pjsua_mwi_info *info, char *buf, unsigned size, int *solicited);

/* ------------------------------------------------- Call-Info answer-after --- */

/** Seconds from an `answer-after=N` parameter in a Call-Info header value: the parameter
 *  after any ';' (e.g. "<sip:pbx>;answer-after=0" or the bare ";answer-after=5") or at the
 *  very start of the value. Case-insensitive, whitespace around ';' and '=' allowed,
 *  capped at 86400. Returns -1 when absent or without digits. */
int cpjsua_parse_answer_after(const char *value);

/** answer-after of the first Call-Info header of an incoming request that has one, or -1. */
int cpjsua_rdata_answer_after(const pjsip_rx_data *rdata);

/** Value of the first header called `name` (case-insensitive; the compact form is not
 *  looked up) in a received message, as printed after the colon with surrounding blanks
 *  removed, into `buf` (NUL-terminated, truncated to `size` - 1). Returns its length, or -1
 *  when the message has no such header. */
int cpjsua_rdata_header(const pjsip_rx_data *rdata, const char *name, char *buf, unsigned size);

/* ------------------------------------------------------------------ dns --- */

/** Points the SIP endpoint's DNS resolver (created by pjsua_init from
 *  pjsua_config.nameserver) at `count` servers with explicit ports (pjsua_config only knows
 *  port 53). Creates and installs a resolver when there is none. */
pj_status_t cpjsua_set_nameservers(const char *const *hosts, const pj_uint16_t *ports, unsigned count);

/** Whether the SIP endpoint resolves host names through its DNS resolver (SRV), 1/0. */
int cpjsua_has_resolver(void);

/** Local RTP port of the call's first audio stream, 0 if none (tests, diagnostics). */
int cpjsua_call_local_rtp_port(pjsua_call_id call_id);

/* ----------------------------------------------------- packet source --- */

/** Where a received message came from (rdata->pkt_info, rdata->tp_info). */
typedef struct cpjsua_pkt_source {
    char addr[PJ_INET6_ADDRSTRLEN];
    int  port;
    int  transport;   /* PJSIP_TRANSPORT_UDP/TCP/TLS with the IPv6 flag cleared; 0 = unknown */
} cpjsua_pkt_source;

pj_status_t cpjsua_rdata_source(const pjsip_rx_data *rdata, cpjsua_pkt_source *out);

/* -------------------------------------------------------------- tones --- */

/** Create a tone generator port that loops (freq1+freq2, on_ms / off_ms)
 *  with the conference bridge's clock rate and frame size. */
pj_status_t cpjsua_tonegen_create(pj_pool_t *pool,
                                  unsigned freq1, unsigned freq2,
                                  unsigned on_ms, unsigned off_ms,
                                  pjmedia_port **out_port);

/** Tone generator in the bridge's format that loops `tones` (1...PJMEDIA_TONEGEN_MAX_DIGITS
 *  entries, played one after another; volume 0 = PJMEDIA_TONEGEN_VOLUME). */
pj_status_t cpjsua_tone_sequence_create(pj_pool_t *pool, const pjmedia_tone_desc *tones,
                                        unsigned count, pjmedia_port **out_port);

/** Idle tone generator in the bridge's format for in-band DTMF (cpjsua_dtmf_generator_play). */
pj_status_t cpjsua_dtmf_generator_create(pj_pool_t *pool, pjmedia_port **out_port);

/** Queue DTMF digits (0-9 * # A-D) on a generator from cpjsua_dtmf_generator_create, each
 *  `on_ms` of its frequency pair followed by `off_ms` of silence. At most
 *  PJMEDIA_TONEGEN_MAX_DIGITS (32) digits may wait at a time: PJ_ETOOMANY beyond. */
pj_status_t cpjsua_dtmf_generator_play(pjmedia_port *port, const char *digits,
                                       unsigned on_ms, unsigned off_ms);

/** 1 while a tone generator still has tones or digits to play. */
int cpjsua_tonegen_busy(pjmedia_port *port);

/** Queue `tones` (1...PJMEDIA_TONEGEN_MAX_DIGITS) once, without looping, on an idle generator
 *  from cpjsua_dtmf_generator_create (one-shot beeps: UI sounds, the recording notice). */
pj_status_t cpjsua_tone_sequence_play_once(pjmedia_port *port, const pjmedia_tone_desc *tones,
                                           unsigned count);

/** Conference slots `src` currently transmits to (pjsua_conf_get_port_info listeners).
 *  Returns the count written to out (at most `max`), 0 for an unknown slot. */
unsigned cpjsua_conf_listeners(pjsua_conf_port_id src, pjsua_conf_port_id *out, unsigned max);

/** Create a looping WAV file player port (20 ms frames). */
pj_status_t cpjsua_wav_loop_create(pj_pool_t *pool, const char *path,
                                   pjmedia_port **out_port);

/** Open `dev_id` as a playback-only sound port matching `port`'s format
 *  and connect `port` to it (used for a ringtone on a separate device). */
pj_status_t cpjsua_snd_port_play(pj_pool_t *pool, int dev_id, pjmedia_port *port,
                                 pjmedia_snd_port **out_snd);

void cpjsua_snd_port_close(pjmedia_snd_port *snd);

/* --------------------------------------------------------- gain port --- */

/** Wraps `src` (16-bit PCM) in a port whose get_frame scales the samples by a gain that can
 *  change while it plays (0 = silence, 1 = unchanged, up to 2; clipped to 16 bits). Used for
 *  the ringtone volume, on the conference bridge and on a separate sound device alike.
 *  On success the new port owns `src` and `pool` (it is allocated from `pool`): destroying it
 *  with pjmedia_port_destroy, after it was removed from the bridge or its sound port was
 *  closed, destroys `src` and releases `pool` once nothing uses it any more (the bridge may
 *  hold a reference until its next frame). On failure the caller still owns both. */
pj_status_t cpjsua_gain_port_create(pj_pool_t *pool, pjmedia_port *src, float gain,
                                    pjmedia_port **out_port);
void  cpjsua_gain_port_set(pjmedia_port *port, float gain);
float cpjsua_gain_port_get(pjmedia_port *port);

/* ------------------------------------------------------------- codecs --- */

typedef struct cpjsua_codec_entry {
    char     id[64];
    unsigned priority;
} cpjsua_codec_entry;

/** Enumerate codecs. *count is in/out. */
pj_status_t cpjsua_codecs(cpjsua_codec_entry *out, unsigned *count);

/** Opus encoder options for streams created from now on (the codec's default parameters).
 *  fec != 0: expected packet loss 10 % (libopus adds in-band FEC/LBRR only when the expected
 *  loss is above 0 and the remote's SDP has useinbandfec=1); fec == 0: expected loss 0, no FEC.
 *  dtx != 0: setting.vad = 1, i.e. Opus-internal DTX (OPUS_SET_DTX) and usedtx=1 in our SDP.
 *  PLC and useinbandfec=1 in our SDP (we decode the remote's FEC) stay on in both cases.
 *  Returns PJ_ENOTFOUND when Opus is not compiled in. */
pj_status_t cpjsua_opus_set_options(int fec, int dtx);

/** Read back what cpjsua_opus_set_options applied (pjmedia_codec_opus_get_config and the
 *  codec manager's default parameters). `fmtp` receives our SDP's fmtp for Opus
 *  ("useinbandfec=1;usedtx=1"), NUL-terminated. */
typedef struct cpjsua_opus_options {
    unsigned packet_loss;      /* pjmedia_codec_opus_config.packet_loss */
    unsigned param_packet_loss;/* pjmedia_codec_param.setting.packet_loss */
    int      vad;              /* pjmedia_codec_param.setting.vad (Opus DTX) */
    int      plc;              /* pjmedia_codec_param.setting.plc */
    int      cbr;              /* pjmedia_codec_opus_config.cbr */
    unsigned complexity;
    char     fmtp[128];
} cpjsua_opus_options;
pj_status_t cpjsua_opus_get_options(cpjsua_opus_options *out);

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

/** Open capture/playback devices now (pjsua_set_snd_dev2 without NO_IMMEDIATE_OPEN). Used to
 *  reopen the sound device mid-call after its echo canceller options changed. */
pj_status_t cpjsua_open_snd_devs(int capture_dev, int playback_dev);

/* --------------------------------------------------- network changes --- */

/** Re-INVITE flags used after a network change (PJSUA_CALL_REINIT_MEDIA |
 *  PJSUA_CALL_UPDATE_CONTACT | PJSUA_CALL_UPDATE_VIA). */
unsigned cpjsua_ip_change_reinvite_flags(void);

/** pjsua_handle_ip_change with these parameters (restart_lis_delay in ms). */
pj_status_t cpjsua_handle_ip_change(int restart_listener, unsigned restart_delay_ms,
                                    int shutdown_transport);

/** Before pjsua_handle_ip_change: decides whether pjsua re-REGISTERs an account that has
 *  no registration session right now (pjsua decides by the last REGISTER status code).
 *  register_it != 0: it is re-registered (last code set to 200); 0: it is left alone
 *  (last code cleared, pjsua treats it as a permanent failure and skips it, including its
 *  calls). Accounts with a registration session are always re-registered by pjsua. */
void cpjsua_acc_prepare_ip_change(pjsua_acc_id acc_id, int register_it);

/** Re-INVITE a confirmed call after a network change: new media transport, Contact and
 *  Via (cpjsua_ip_change_reinvite_flags), local hold kept. */
pj_status_t cpjsua_call_reinvite_ip_change(pjsua_call_id call_id);

/** For on_call_tsx_state: a request we sent got its final response (transaction state
 *  COMPLETED or TERMINATED). Returns 1 for INVITE (initial or re-INVITE), 2 for OPTIONS,
 *  0 for anything else; *code = the status code. */
int cpjsua_tsx_final(const pjsip_transaction *tsx, int *code);

/** In-dialog OPTIONS on a call (a liveness probe; the answer arrives in on_call_tsx_state). */
pj_status_t cpjsua_call_send_options(pjsua_call_id call_id);

/** CANCEL the call's re-INVITE that is still waiting for a final response (PJSIP sends it
 *  once a provisional response arrived). */
pj_status_t cpjsua_call_cancel_reinvite(pjsua_call_id call_id);

/** Accounts whose registration currently uses transport `tp` (pjsua's own bookkeeping, as
 *  in pjsua_acc_on_tp_state_changed). Call from on_transport_state. Returns the count. */
unsigned cpjsua_accounts_on_transport(const pjsip_transport *tp, pjsua_acc_id *out, unsigned max);

/** Errors that make a REGISTER failure permanent: TLS certificate/configuration errors.
 *  Writes up to `max` codes, returns the count. */
unsigned cpjsua_permanent_transport_errors(pj_status_t *out, unsigned max);
pj_status_t cpjsua_err_resolve(void);      /* PJ_ERESOLVE (getaddrinfo failed) */
pj_status_t cpjsua_err_nxdomain(void);     /* PJLIB_UTIL_EDNS_NXDOMAIN */

/** PJSIP_TD_TIMEOUT, the compiled-in transaction timeout (ms). */
unsigned cpjsua_default_tsx_timeout(void);

/** pjsip_cfg()->endpt.keep_inv_after_tsx_timeout: a request timeout does not end an INVITE
 *  session. pjsua_handle_ip_change sets it and schedules a timer to clear it only when it
 *  was off; the engine sets it before each network change and clears it itself once no
 *  re-INVITE is pending (and after pjsua_destroy). */
void cpjsua_set_keep_inv_after_tsx_timeout(int on);

/** Remote end of a connection-oriented transport (TCP/TLS) for on_transport_state.
 *  PJ_EINVAL for datagram transports. `transport` as in cpjsua_rdata_source. */
pj_status_t cpjsua_transport_remote(const pjsip_transport *tp, cpjsua_pkt_source *out);

/** SIP transaction timeout (Timer B/F, 64*T1 = 32000 ms by default). Tests shorten it. */
unsigned cpjsua_tsx_timeout(void);
void cpjsua_set_tsx_timeout(unsigned ms);

/* --------------------------------------------------------- error codes --- */

pj_status_t cpjsua_err_no_rfc2833(void);   /* PJMEDIA_RTP_EREMNORFC2833 */
pj_status_t cpjsua_err_not_found(void);    /* PJ_ENOTFOUND */
pj_status_t cpjsua_err_invalid_op(void);   /* PJ_EINVALIDOP */
pj_status_t cpjsua_err_pj_busy(void);      /* PJ_EBUSY */
pj_status_t cpjsua_err_sip_busy(void);     /* PJSIP_EBUSY (transaction in progress) */
pj_status_t cpjsua_err_session_state(void); /* PJSIP_ESESSIONSTATE */

/** PJSIP_REGC_EXPIRATION_NOT_SPECIFIED (0xFFFFFFFF): 2xx without an Expires value. */
unsigned cpjsua_regc_expiration_not_specified(void);

#endif /* CPJSUA_H */
