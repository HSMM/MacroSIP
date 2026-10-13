// pjsip-smoke: proves Swift can link and drive the static PJSIP build through CPJSUA.
//
// create -> init (log level 3) -> UDP transport on a random port -> start ->
// print version, codecs, audio devices, compiled-in features -> TLS transport
// on port 0 -> destroy -> exit 0. Any failure exits non-zero with pj_strerror text.

import CPJSUA
import Foundation

// MARK: - helpers

func errorText(_ status: pj_status_t) -> String {
    var buf = [CChar](repeating: 0, count: 256)
    return String(cString: cpjsua_strerror(status, &buf, buf.count))
}

func check(_ status: pj_status_t, _ what: String) {
    if cpjsua_succeeded(status) != 0 {
        print("[ok]   \(what)")
        return
    }
    print("[FAIL] \(what): \(errorText(status)) (status \(status))")
    pjsua_destroy()
    exit(1)
}

/// Fixed-size C char arrays are imported as tuples; read them as a C string.
func cString<T>(tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
}

func string(_ s: pj_str_t) -> String {
    var copy = s
    var buf = [CChar](repeating: 0, count: Int(max(s.slen, 0)) + 1)
    let n = cpjsua_str_copy(&copy, &buf, buf.count)
    return String(decoding: buf.prefix(n).map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func yesNo(_ v: Int32) -> String { v != 0 ? "yes" : "no" }

// MARK: - lifecycle

print("== pjsip-smoke ==")
check(pjsua_create(), "pjsua_create")

var cfg = pjsua_config()
var logCfg = pjsua_logging_config()
var mediaCfg = pjsua_media_config()
pjsua_config_default(&cfg)
pjsua_logging_config_default(&logCfg)
pjsua_media_config_default(&mediaCfg)
logCfg.level = 3
logCfg.console_level = 3
cfg.user_agent = cpjsua_str("MacroSIP-smoke")   // string literal lives for the process
check(pjsua_init(&cfg, &logCfg, &mediaCfg), "pjsua_init (log level 3)")

var udpId = pjsua_transport_id(PJSUA_INVALID_ID.rawValue)
check(cpjsua_transport_create(PJSIP_TRANSPORT_UDP, 0, &udpId), "UDP transport")
print("       UDP transport id \(udpId) bound to port \(cpjsua_transport_port(udpId))")

check(pjsua_start(), "pjsua_start")

// MARK: - report

print("")
print("PJSIP version : \(String(cString: cpjsua_version()))")
print("SSL backend   : \(String(cString: cpjsua_ssl_backend()))")
print("TLS transport : \(yesNo(cpjsua_has_tls()))")
print("SRTP          : \(yesNo(cpjsua_has_srtp()))")
print("IPv6          : \(yesNo(cpjsua_has_ipv6()))")
print("WebRTC AEC    : \(yesNo(cpjsua_has_webrtc_aec()))")
print("Video         : \(yesNo(cpjsua_has_video()))")

print("")
var codecs = [pjsua_codec_info](repeating: pjsua_codec_info(), count: 32)
var codecCount = UInt32(codecs.count)
check(pjsua_enum_codecs(&codecs, &codecCount), "pjsua_enum_codecs")
print("Codecs (\(codecCount)):")
for c in codecs.prefix(Int(codecCount)) {
    let id = string(c.codec_id).padding(toLength: 22, withPad: " ", startingAt: 0)
    print("  \(id) priority \(c.priority)")
}

print("")
let devCount = pjmedia_aud_dev_count()
print("Audio devices (\(devCount)):")
for i in 0..<devCount {
    var info = pjmedia_aud_dev_info()
    let st = pjmedia_aud_dev_get_info(pjmedia_aud_dev_index(i), &info)
    guard cpjsua_succeeded(st) != 0 else {
        print("  [\(i)] <error: \(errorText(st))>")
        continue
    }
    print("  [\(i)] \(cString(tuple: info.name))  (driver \(cString(tuple: info.driver)), in \(info.input_count), out \(info.output_count), \(info.default_samples_per_sec) Hz)")
}

print("")
var tlsId = pjsua_transport_id(PJSUA_INVALID_ID.rawValue)
check(cpjsua_transport_create(PJSIP_TRANSPORT_TLS, 0, &tlsId), "TLS transport on port 0")
print("       TLS transport id \(tlsId) bound to port \(cpjsua_transport_port(tlsId))")

var callOpt = pjsua_call_setting()
cpjsua_call_setting_defaults(&callOpt)
print("[ok]   call setting defaults: aud_cnt \(callOpt.aud_cnt), vid_cnt \(callOpt.vid_cnt)")

print("")
check(pjsua_destroy(), "pjsua_destroy")
print("== smoke test passed ==")
exit(0)
