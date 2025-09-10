// SPDX-License-Identifier: GPL-2.0-or-later
// ICS watcher: toggle between "USB Gadget (client)" and "USB Gadget (shared)"
// using NetworkManager (libnm) + GLib, ported from Python version.
// ICS = "Internet Connection Sharing"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>

#include <glib.h>
#include <gio/gio.h>
#include <NetworkManager.h>

static const char *ENV_DEBUG = "ICS_DEBUG";
static const char *IFACE = "usb0";
static const char *CLIENT_ID = "USB Gadget (client)";
static const char *SHARED_ID = "USB Gadget (shared)";

// Win/mac/linux ICS gateway defaults
static const char *ICS_GWS[] = { "192.168.137.1", "192.168.2.1", "10.42.0.1" };
static const size_t ICS_GWS_N = 3;

// Tunables (seconds/ms)
static const guint LOOP_MS = 4000;
static const gint64 FALLBACK_DELAY = 5;
static const gint64 MINDWELL = 1;
static const gint64 GW_UNREACH_GRACE = 1;
static const gint64 PROBE_EVERY = 12;
static const gint64 PROBE_TIMEOUT = 4;

static gboolean g_debug = FALSE;
static GMainLoop *g_loop = NULL;
static NMClient *g_client = NULL;

static gint64 last_switch = 0;
static gint64 last_link_up = 0;
static gint64 last_probe = 0;
static gint64 last_gw_ok = 0;

// --- helpers -----------------------------------------------------------------

static inline gint64 now_s(void) {
    return g_get_real_time() / G_USEC_PER_SEC;
}

static void logf(gboolean force, const char *fmt, ...) {
    if (!g_debug && !force) return;
    va_list ap;
    va_start(ap, fmt);
    GDateTime *dt = g_date_time_new_now_local();
    gchar *ts = g_date_time_format(dt, "%F %T");
    g_print("[ics-watch | %s] ", ts);
    g_vprintf(fmt, ap);
    g_print("\n");
    g_free(ts);
    g_date_time_unref(dt);
    va_end(ap);
}

static NMDevice *get_device(void) {
    NMDevice *d = nm_client_get_device_by_iface(g_client, IFACE);
    if (!d) {
        return NULL;
    }
    if (nm_device_get_device_type(d) == NM_DEVICE_TYPE_ETHERNET) {
        return d;
    }

    return NULL;
}

static const char *get_active_con_name(NMDevice *dev) {
    NMActiveConnection *ac = nm_device_get_active_connection(dev);
    if (!ac) {
        return "";
    }
    const char *id = nm_active_connection_get_id(ac);
    return id ? id : "";
}

typedef struct {
    char *name;
} ActivateCtx;

static NMConnection *conn_by_id(const char *id) {
    const GPtrArray *conns = nm_client_get_connections(g_client);
    for (guint i = 0; i < conns->len; i++) {
        NMConnection *c = g_ptr_array_index((GPtrArray *)conns, i);
        const char *cid = nm_connection_get_id(c);
        if (cid && g_strcmp0(cid, id) == 0) return c;
    }
    return NULL;
}

static void on_activate_cb(GObject *src, GAsyncResult *res, gpointer user_data) {
    ActivateCtx *ctx = user_data;
    GError *err = NULL;
    NMActiveConnection *ac =
        nm_client_activate_connection_finish(NM_CLIENT(src), res, &err);
    if (!ac) {
        logf(FALSE, "Activate '%s' failed: %s", ctx->name, err ? err->message : "unknown");
        g_clear_error(&err);
    } else {
        logf(FALSE, "Activated '%s'", ctx->name);
    }
    g_free(ctx->name);
    g_free(ctx);
}

static gboolean up(const char *name) {
    NMConnection *c = conn_by_id(name);
    if (!c) {
        logf(FALSE, "up(): connection '%s' not found", name);
        return FALSE;
    }
    NMDevice *dev = get_device();
    if (!dev) {
        logf(FALSE, "up(): device not found");
        return FALSE;
    }

    ActivateCtx *ctx = g_new0(ActivateCtx, 1);
    ctx->name = g_strdup(name);

    nm_client_activate_connection_async(
        g_client, c, dev, NULL, NULL, on_activate_cb, ctx);
    
    logf(FALSE, "Activated '%s'", name);
    return TRUE;
}

static gboolean down_and_wait(const char *name, guint timeout_ms) {
    NMDevice *dev = get_device();
    if (!dev) {
        logf(FALSE, "down(): no device");
        return FALSE;
    }

    NMActiveConnection *ac = nm_device_get_active_connection(dev);
    if (!ac) {
        logf(FALSE, "down(): no active connection on device");
        return TRUE;
    }

    const char *active_id = nm_active_connection_get_id(ac);
    if (!active_id || g_strcmp0(active_id, name) != 0) {
        logf(FALSE, "down(): '%s' not active (active is '%s'), skipping",
             name, active_id ? active_id : "");
        return TRUE;
    }

    GError *err = NULL;
    if (!nm_client_deactivate_connection(g_client, ac, NULL, &err)) {
        logf(FALSE, "Disconnect ignored: %s", err ? err->message : "unknown");
        g_clear_error(&err);
        return FALSE;
    }

    // poll until inactive or timeout
    guint waited = 0;
    while (waited < timeout_ms) {
        g_usleep(50 * 1000); // 50ms
        waited += 50;
        ac = nm_device_get_active_connection(dev);
        if (!ac) {
            logf(FALSE, "Disconnected from '%s'", name);
            return TRUE;
        }
        const char *cur = nm_active_connection_get_id(ac);
        if (!cur || g_strcmp0(cur, name) != 0) {
            logf(FALSE, "Deactivated '%s'", name);
            return TRUE;
        }
    }
    logf(FALSE, "down(): timeout waiting for '%s' to deactivate", name);
    return FALSE;
}

static gboolean carrier_up(NMDevice *dev) {
    if (NM_IS_DEVICE_ETHERNET(dev)) {
        NMDeviceEthernet *eth = NM_DEVICE_ETHERNET(dev);
        return nm_device_ethernet_get_carrier(eth);
    }
    return nm_device_get_state(dev) == NM_DEVICE_STATE_ACTIVATED;
}

static void ip4_config(NMDevice *dev, GPtrArray **addrs_out, const char **gw_out) {
    *gw_out = NULL;
    *addrs_out = g_ptr_array_new_with_free_func(g_free);

    NMIPConfig *cfg = nm_device_get_ip4_config(dev);
    if (!cfg)
        return;

    const GPtrArray *addrs = nm_ip_config_get_addresses(cfg);
    if (addrs) {
        for (guint i = 0; i < addrs->len; i++) {
            NMIPAddress *ipa = g_ptr_array_index((GPtrArray *)addrs, i);
            const char *s = nm_ip_address_get_address(ipa);
            if (s)
                g_ptr_array_add(*addrs_out, g_strdup(s));
        }
    }
    const char *gw = nm_ip_config_get_gateway(cfg);
    if (gw) *gw_out = gw;
}

static gboolean has_non_apipa(GPtrArray *addrs) {
    for (guint i = 0; i < addrs->len; i++) {
        const char *s = addrs->pdata[i];
        if (g_str_has_prefix(s, "169.254.")) continue;
        return TRUE;
    }
    return FALSE;
}

// prefer arping; fallback to ping
static gboolean arping(const char *gw) {
    gchar *argv1[] = { "arping", "-q", "-c", "1", "-w", "1", "-I", (gchar*)IFACE, (gchar*)gw, NULL };
    gchar *argv2[] = { "ping", "-c", "1", "-W", "1", "-I", (gchar*)IFACE, (gchar*)gw, NULL };
    GError *err = NULL;
    gint status = 0;

    if (g_spawn_sync(NULL, argv1, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, NULL, NULL, &status, &err)) {
        if (g_spawn_check_exit_status(status, NULL))
            return TRUE;
    } else {
        g_clear_error(&err);
    }

    if (g_spawn_sync(NULL, argv2, NULL, G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, NULL, NULL, &status, &err)) {
        if (g_spawn_check_exit_status(status, NULL))
            return TRUE;
    } else {
        g_clear_error(&err);
    }
    return FALSE;
}

static gboolean any_ics_gateway_reachable(void) {
    for (size_t i = 0; i < ICS_GWS_N; i++) {
        if (arping(ICS_GWS[i]))
            return TRUE;
    }
    return FALSE;
}

static void maybe_switch(const char *target) {
    NMDevice *dev = get_device();
    if (!dev) {
        logf(FALSE, "maybe_switch(): device not found");
        return;
    }

    const char *active = get_active_con_name(dev);
    if (g_strcmp0(active, target) == 0) {
        logf(FALSE, "maybe_switch(): already on %s", target);
        return;
    }
    gint64 t = now_s();
    if (t - last_switch < MINDWELL) {
        logf(FALSE, "maybe_switch(): switched too recently (%lds ago)", (long)(t - last_switch));
        return;
    }

    const char *other = (g_strcmp0(target, SHARED_ID) == 0) ? CLIENT_ID : SHARED_ID;
    logf(FALSE, "Switching to %s", target);
    if (down_and_wait(other, 5000)) {
        last_switch = now_s();
        if (up(target)) {
            if (g_strcmp0(target, CLIENT_ID) == 0)
                logf(TRUE, "ICS Gateway detected; switched to DHCP client mode");
            else
                logf(TRUE, "No ICS Gateway detected; switched to shared mode");
        }
    } else {
        logf(FALSE, "maybe_switch(): failed to drop other profile; not switching");
    }
}

static void client_probe(void) {
    gint64 t = now_s();
    if (t - last_probe < PROBE_EVERY) return;
    last_probe = t;

    logf(FALSE, "Client probe: trying DHCP in CLIENT");
    up(CLIENT_ID);
    gint64 start = now_s();

    while (now_s() - start < PROBE_TIMEOUT) {
        NMDevice *dev = get_device();
        const char *gw = NULL;
        GPtrArray *addrs = NULL;
        if (dev) ip4_config(dev, &addrs, &gw);

        gboolean ok = (gw && arping(gw));
        if (addrs) g_ptr_array_free(addrs, TRUE);

        if (ok) {
            logf(FALSE, "Client probe succeeded; staying CLIENT");
            last_switch = now_s();
            last_gw_ok = now_s();
            return;
        }
        g_usleep(1000 * 1000);
    }

    logf(FALSE, "Client probe failed; reverting to SHARED");
    up(SHARED_ID);
    last_switch = now_s();
}

static gboolean periodic_check(gpointer user_data) {
    (void)user_data;
    logf(FALSE, "Periodic check");

    NMDevice *dev = get_device();
    if (!dev) {
        logf(FALSE, "No device %s", IFACE);
        return G_SOURCE_CONTINUE;
    }

    if (carrier_up(dev)) {
        logf(FALSE, "Link is up");
        if (last_link_up == 0) last_link_up = now_s();
    } else {
        logf(FALSE, "Link is down");
        return G_SOURCE_CONTINUE;
    }

    const char *name = get_active_con_name(dev);
    GPtrArray *addrs = NULL;
    const char *gw = NULL;
    ip4_config(dev, &addrs, &gw);

    if (g_strcmp0(name, CLIENT_ID) == 0) {
        // CLIENT mode
        gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata); // best-effort; requires NULL-terminated, so skip print if odd
        logf(FALSE, "CLIENT: addrs=%s gw=%s", joined ? joined : "(…)", gw ? gw : "(none)");
        g_free(joined);

        if (gw && arping(gw)) {
            logf(FALSE, "CLIENT: gateway reachable");
            last_gw_ok = now_s();
            g_ptr_array_free(addrs, TRUE);
            return G_SOURCE_CONTINUE;
        }

        logf(FALSE, "CLIENT: gateway unreachable");
        gint64 since_ok = now_s() - (last_gw_ok ? last_gw_ok : last_link_up);
        if (since_ok >= GW_UNREACH_GRACE) {
            logf(FALSE, "CLIENT: no gateway; switching to SHARED");
            maybe_switch(SHARED_ID);
        } else if ((now_s() - last_link_up) >= FALLBACK_DELAY && !has_non_apipa(addrs)) {
            logf(FALSE, "CLIENT: APIPA only; switching to SHARED");
            maybe_switch(SHARED_ID);
        } else {
            logf(FALSE, "CLIENT: waiting");
        }
        g_ptr_array_free(addrs, TRUE);
        return G_SOURCE_CONTINUE;
    }

    if (g_strcmp0(name, SHARED_ID) == 0) {
        // SHARED mode
        gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata);
        logf(FALSE, "SHARED: addrs=%s gw=%s", joined ? joined : "(…)", gw ? gw : "(none)");
        g_free(joined);

        if (any_ics_gateway_reachable()) {
            logf(FALSE, "SHARED: ICS gw detected; switching to CLIENT");
            maybe_switch(CLIENT_ID);
        } else {
            logf(FALSE, "SHARED: no ICS gw detected; staying SHARED");
        }
        g_ptr_array_free(addrs, TRUE);
        return G_SOURCE_CONTINUE;
    }

    // No profile active yet: prefer CLIENT
    up(CLIENT_ID);
    last_link_up = now_s();
    g_ptr_array_free(addrs, TRUE);
    return G_SOURCE_CONTINUE;
}

// --- main --------------------------------------------------------------------

static void on_sigint(int signum) {
    (void)signum;
    logf(TRUE, "SIGINT received, exiting");
    if (g_loop) g_main_loop_quit(g_loop);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    const char *dbg = g_getenv(ENV_DEBUG);
    g_debug = (dbg && strcmp(dbg, "0") != 0);

    GError *err = NULL;
    g_client = nm_client_new(NULL, &err);
    if (!g_client) {
        g_printerr("Failed to create NMClient: %s\n", err ? err->message : "unknown error");
        g_clear_error(&err);
        return 1;
    }

    logf(TRUE, "Starting ICS watcher (debug=%d) on %s", g_debug, IFACE);

    g_loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(LOOP_MS, periodic_check, NULL);

    // SIGINT
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_restorer = on_sigint;
    sigaction(SIGINT, &sa, NULL);

    g_main_loop_run(g_loop);

    g_main_loop_unref(g_loop);
    g_clear_object(&g_client);
    return 0;
}