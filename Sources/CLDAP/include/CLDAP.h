// CLDAP - a small C shim over the system OpenLDAP client library (libldap in the macOS SDK).
// Swift sees only these functions and an opaque handle, never <ldap.h>: the SDK marks the whole
// libldap API deprecated, and its macros and varargs do not import well. Calls are synchronous;
// MacroSIPCore runs them off the cooperative pool (LDAPDirectoryProvider).

#ifndef CLDAP_H
#define CLDAP_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct cldap_conn cldap_conn;

enum {
    CLDAP_SUCCESS = 0,
    CLDAP_SCOPE_BASE = 0,
    CLDAP_SCOPE_ONELEVEL = 1,
    CLDAP_SCOPE_SUBTREE = 2,
};

/// Creates a handle for `uri` ("ldap://host:port" or "ldaps://host:port"); LDAPv3, no referrals, and
/// `timeout_ms` for connecting and for each synchronous operation. Does not connect yet.
/// Returns an LDAP result code; on success `*out` must be released with cldap_close.
int cldap_open(const char *uri, int timeout_ms, cldap_conn **out);

/// Changes the connect and per-operation timeout of a handle (the Swift side spends one deadline on
/// connect, StartTLS, bind and search together).
void cldap_set_timeout(cldap_conn *c, int timeout_ms);

/// 1 when the library accepted "verify the server certificate" (LDAP_OPT_X_TLS_REQUIRE_CERT = demand) for
/// this handle, 0 when it refused the option (then its default applies; the Swift side logs that once).
int cldap_tls_verification_set(cldap_conn *c);

/// StartTLS extended operation (RFC 4513) on an ldap:// connection. The server certificate is verified.
int cldap_start_tls(cldap_conn *c);

/// Simple bind. `dn` NULL or empty and `password` NULL or empty = anonymous bind.
int cldap_simple_bind(cldap_conn *c, const char *dn, const char *password);

/// Synchronous search. `attrs` is NULL-terminated (NULL = all user attributes). `size_limit` 0 = server
/// limit. Partial results (size or time limit exceeded) are kept and reported through the return code.
/// The entries replace those of the previous search; iterate them with cldap_next_entry.
int cldap_search(cldap_conn *c, const char *base, int scope, const char *filter, const char *const *attrs,
                 int size_limit, int timeout_ms, int *count_out);

/// Moves to the first (then the next) entry of the last search. 1 = on an entry, 0 = no more.
int cldap_next_entry(cldap_conn *c);

/// DN of the current entry (malloc'ed; release with cldap_free), or NULL.
char *cldap_entry_dn(cldap_conn *c);

/// Values of `attr` in the current entry, as NUL-terminated malloc'ed strings. Returns the count
/// (0 when absent); release with cldap_free_values(values, count).
int cldap_entry_values(cldap_conn *c, const char *attr, char ***values_out);

void cldap_free(void *p);
void cldap_free_values(char **values, int count);

/// Static text for a result code.
const char *cldap_error_string(int rc);

/// The server's diagnostic message of the last operation (malloc'ed; release with cldap_free), or NULL.
char *cldap_diagnostic(cldap_conn *c);

/// Unbinds, closes the connection and frees the handle.
void cldap_close(cldap_conn *c);

/// Result codes the Swift side tells apart.
int cldap_rc_sizelimit_exceeded(void);
int cldap_rc_timelimit_exceeded(void);
int cldap_rc_timeout(void);
int cldap_rc_server_down(void);
int cldap_rc_connect_error(void);
int cldap_rc_invalid_credentials(void);

#ifdef __cplusplus
}
#endif

#endif
