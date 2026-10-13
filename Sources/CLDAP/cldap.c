// See include/CLDAP.h.
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#include "CLDAP.h"

#include <ldap.h>
#include <lber.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

struct cldap_conn {
    LDAP *ld;
    LDAPMessage *result;
    LDAPMessage *entry;
    int started;
    int tls_verification_set;
};

static struct timeval tv_from_ms(int ms) {
    struct timeval tv;
    if (ms < 1) ms = 1;
    tv.tv_sec = ms / 1000;
    tv.tv_usec = (ms % 1000) * 1000;
    return tv;
}

int cldap_open(const char *uri, int timeout_ms, cldap_conn **out) {
    *out = NULL;
    LDAP *ld = NULL;
    int rc = ldap_initialize(&ld, uri);
    if (rc != LDAP_SUCCESS) return rc;
    int version = LDAP_VERSION3;
    ldap_set_option(ld, LDAP_OPT_PROTOCOL_VERSION, &version);
    ldap_set_option(ld, LDAP_OPT_REFERRALS, LDAP_OPT_OFF);
    struct timeval tv = tv_from_ms(timeout_ms);
    ldap_set_option(ld, LDAP_OPT_NETWORK_TIMEOUT, &tv);
    ldap_set_option(ld, LDAP_OPT_TIMEOUT, &tv);
    int tls_set = 0;
#ifdef LDAP_OPT_X_TLS_REQUIRE_CERT
    int demand = LDAP_OPT_X_TLS_DEMAND;
    tls_set = ldap_set_option(ld, LDAP_OPT_X_TLS_REQUIRE_CERT, &demand) == LDAP_OPT_SUCCESS;
#endif
    cldap_conn *c = calloc(1, sizeof(cldap_conn));
    if (!c) { ldap_unbind_ext_s(ld, NULL, NULL); return LDAP_NO_MEMORY; }
    c->ld = ld;
    c->tls_verification_set = tls_set;
    *out = c;
    return LDAP_SUCCESS;
}

void cldap_set_timeout(cldap_conn *c, int timeout_ms) {
    struct timeval tv = tv_from_ms(timeout_ms);
    ldap_set_option(c->ld, LDAP_OPT_NETWORK_TIMEOUT, &tv);
    ldap_set_option(c->ld, LDAP_OPT_TIMEOUT, &tv);
}

int cldap_tls_verification_set(cldap_conn *c) { return c->tls_verification_set; }

int cldap_start_tls(cldap_conn *c) {
    return ldap_start_tls_s(c->ld, NULL, NULL);
}

int cldap_simple_bind(cldap_conn *c, const char *dn, const char *password) {
    struct berval cred;
    cred.bv_val = (char *)(password ? password : "");
    cred.bv_len = password ? strlen(password) : 0;
    const char *who = (dn && dn[0]) ? dn : NULL;
    return ldap_sasl_bind_s(c->ld, who, LDAP_SASL_SIMPLE, &cred, NULL, NULL, NULL);
}

int cldap_search(cldap_conn *c, const char *base, int scope, const char *filter, const char *const *attrs,
                 int size_limit, int timeout_ms, int *count_out) {
    if (c->result) { ldap_msgfree(c->result); c->result = NULL; }
    c->entry = NULL;
    c->started = 0;
    if (count_out) *count_out = 0;
    struct timeval tv = tv_from_ms(timeout_ms);
    LDAPMessage *res = NULL;
    int rc = ldap_search_ext_s(c->ld, base, scope, filter, (char **)attrs, 0, NULL, NULL, &tv,
                               size_limit > 0 ? size_limit : LDAP_NO_LIMIT, &res);
    if (res) {
        c->result = res;
        if (count_out) *count_out = ldap_count_entries(c->ld, res);
    }
    return rc;
}

int cldap_next_entry(cldap_conn *c) {
    if (!c->result) return 0;
    if (!c->started) {
        c->started = 1;
        c->entry = ldap_first_entry(c->ld, c->result);
    } else if (c->entry) {
        c->entry = ldap_next_entry(c->ld, c->entry);
    }
    return c->entry != NULL;
}

char *cldap_entry_dn(cldap_conn *c) {
    if (!c->entry) return NULL;
    char *dn = ldap_get_dn(c->ld, c->entry);
    if (!dn) return NULL;
    char *copy = strdup(dn);
    ldap_memfree(dn);
    return copy;
}

int cldap_entry_values(cldap_conn *c, const char *attr, char ***values_out) {
    *values_out = NULL;
    if (!c->entry) return 0;
    struct berval **vals = ldap_get_values_len(c->ld, c->entry, attr);
    if (!vals) return 0;
    int n = ldap_count_values_len(vals);
    if (n <= 0) { ldap_value_free_len(vals); return 0; }
    char **out = calloc((size_t)n, sizeof(char *));
    if (!out) { ldap_value_free_len(vals); return 0; }
    for (int i = 0; i < n; i++) {
        out[i] = malloc(vals[i]->bv_len + 1);
        if (out[i]) {
            memcpy(out[i], vals[i]->bv_val, vals[i]->bv_len);
            out[i][vals[i]->bv_len] = 0;
        }
    }
    ldap_value_free_len(vals);
    *values_out = out;
    return n;
}

void cldap_free(void *p) { free(p); }

void cldap_free_values(char **values, int count) {
    if (!values) return;
    for (int i = 0; i < count; i++) free(values[i]);
    free(values);
}

const char *cldap_error_string(int rc) { return ldap_err2string(rc); }

char *cldap_diagnostic(cldap_conn *c) {
    char *msg = NULL;
    if (ldap_get_option(c->ld, LDAP_OPT_DIAGNOSTIC_MESSAGE, &msg) != LDAP_OPT_SUCCESS || !msg) return NULL;
    char *copy = msg[0] ? strdup(msg) : NULL;
    ldap_memfree(msg);
    return copy;
}

void cldap_close(cldap_conn *c) {
    if (!c) return;
    if (c->result) ldap_msgfree(c->result);
    if (c->ld) ldap_unbind_ext_s(c->ld, NULL, NULL);
    free(c);
}

int cldap_rc_sizelimit_exceeded(void) { return LDAP_SIZELIMIT_EXCEEDED; }
int cldap_rc_timelimit_exceeded(void) { return LDAP_TIMELIMIT_EXCEEDED; }
int cldap_rc_timeout(void) { return LDAP_TIMEOUT; }
int cldap_rc_server_down(void) { return LDAP_SERVER_DOWN; }
int cldap_rc_connect_error(void) { return LDAP_CONNECT_ERROR; }
int cldap_rc_invalid_credentials(void) { return LDAP_INVALID_CREDENTIALS; }
