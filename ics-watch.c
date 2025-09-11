// SPDX-License-Identifier: Apache-2.0
// ICS watcher: toggle between "USB Gadget (client)" and "USB Gadget (shared)"
// using NetworkManager (libnm) + GLib
// ICS = "Internet Connection Sharing"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <time.h>

#include <glib.h>
#include <glib/gprintf.h>
#include <gio/gio.h>
#include <NetworkManager.h>

static const char *ENV_DEBUG = "ICS_DEBUG";
static const char *ENV_IFACE = "USB_GADGET_IFACE";
static const char *IFACE = "usb0";
static const char *CLIENT_ID = "USB Gadget (client)";
static const char *SHARED_ID = "USB Gadget (shared)";

// Win/mac/linux ICS gateway defaults
static const char *ICS_GWS[] = { "192.168.137.1", "192.168.2.1", "10.42.0.1" };
static const size_t ICS_GWS_N = 3;

// Tunables (seconds/ms)
static const guint  LOOP_MS             = 4000; // main loop tick
static const gint64 CLIENT_PROBE_WINDOW = 15;   // seconds we allow DHCP to succeed after switching to CLIENT
static const gint64 BACKOFF_AFTER_FAIL  = 15;   // seconds to wait in SHARED after a failed CLIENT try
static const gint64 MINDWELL            = 2;    // anti-flap
static const gint64 GW_LOSS_GRACE       = 10;   // how long to tolerate a dead gateway in CLIENT

static gboolean     g_debug     = FALSE;
static GMainLoop    *g_loop     = NULL;
static NMClient     *g_client   = NULL;

// State
static gint64 last_switch       = 0;
static gint64 client_deadline   = 0;  // 0 = not probing; otherwise time when CLIENT must have lease/gw
static gint64 backoff_until     = 0;  // 0 = no backoff; otherwise do not try CLIENT before this time
static gint64 last_gw_ok        = 0;  // last time we saw a working gateway in CLIENT mode

// --- helpers -----------------------------------------------------------------

static inline gint64 now_s(void) {
    return g_get_real_time() / G_USEC_PER_SEC;
}

static void log_msg(gboolean force, const char *fmt, ...) {
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

static const char *get_active_con_id(NMDevice *dev) {
    NMActiveConnection *ac = nm_device_get_active_connection(dev);
    if (!ac) {
        return "";
    }
    const char *id = nm_active_connection_get_id(ac);
    return id ? id : "";
}

static NMConnection *conn_by_id(const char *id) {
    const GPtrArray *conns = nm_client_get_connections(g_client);
    for (guint i = 0; i < conns->len; i++) {
        NMConnection *c = g_ptr_array_index((GPtrArray *)conns, i);
        const char *cid = nm_connection_get_id(c);
        if (cid && g_strcmp0(cid, id) == 0) return c;
    }
    return NULL;
}

static gboolean is_active_id(const char *want_id) {
    NMDevice *dev = get_device();
    if (!dev)
        return FALSE;
    const char *id = get_active_con_id(dev);
    return id && g_strcmp0(id, want_id) == 0;
}

static gboolean is_transitioning(NMDevice *dev) {
    NMDeviceState s = nm_device_get_state(dev);
    return (s > NM_DEVICE_STATE_DISCONNECTED && s < NM_DEVICE_STATE_ACTIVATED);
}

typedef struct { char *name; } ActivateCtx;

static void on_activate_cb(GObject *src, GAsyncResult *res, gpointer user_data) {
    ActivateCtx *ctx = user_data;
    GError *err = NULL;
    NMActiveConnection *ac =
        nm_client_activate_connection_finish(NM_CLIENT(src), res, &err);
    if (!ac) {
        log_msg(FALSE, "Activate '%s' failed: %s", ctx->name, err ? err->message : "unknown");
        g_clear_error(&err);
    } else {
        log_msg(FALSE, "Activated '%s'", ctx->name);
    }
    g_free(ctx->name);
    g_free(ctx);
}

static gboolean up(const char *name) {
    NMDevice *dev = get_device();
    if (!dev) {
        log_msg(FALSE, "up(): no device");
        return FALSE;
    }

    if (is_active_id(name)) {
        log_msg(FALSE, "'%s' already active", name);
        return TRUE;
    } else if (is_transitioning(dev)) {
        log_msg(FALSE, "Activation already in progress (state=%d); skip up('%s')",
                nm_device_get_state(dev), name);
        return TRUE; // treat as fine
    }
    
    NMConnection *c = conn_by_id(name);
    if (!c) {
        log_msg(FALSE, "up(): connection '%s' not found", name);
        return FALSE;
    }

    ActivateCtx *ctx = g_new0(ActivateCtx, 1);
    ctx->name = g_strdup(name);

    nm_client_activate_connection_async(
        g_client, c, dev, NULL, NULL, on_activate_cb, ctx);
    
    log_msg(FALSE, "Activating '%s'...", name);
    return TRUE;
}

typedef struct { GMainLoop *loop; gboolean ok; } DeactCtx;

static void on_deact_cb(GObject *src, GAsyncResult *res, gpointer user_data) {
    DeactCtx *ctx = user_data;
    GError *err = NULL;
    ctx->ok = nm_client_deactivate_connection_finish(NM_CLIENT(src), res, &err);
    if (!ctx->ok) {
        log_msg(FALSE, "Deactivate failed: %s", err ? err->message : "unknown");
        g_clear_error(&err);
    } else {
        log_msg(FALSE, "Deactivated connection");
    }
    if (ctx->loop)
        g_main_loop_quit(ctx->loop);
}

static gboolean quit_loop_cb(gpointer data) {
    g_main_loop_quit((GMainLoop *)data);
    return G_SOURCE_REMOVE;
}

static gboolean down_and_wait(const char *name, guint timeout_ms) {
    NMDevice *dev = get_device();
    if (!dev) {
        log_msg(FALSE, "down(): no device");
        return FALSE;
    }

    NMActiveConnection *ac = nm_device_get_active_connection(dev);
    if (!ac) {
        log_msg(FALSE, "down(): no active connection on device");
        return TRUE;
    }

    const char *active_id = nm_active_connection_get_id(ac);
    if (!active_id || g_strcmp0(active_id, name) != 0) {
        log_msg(FALSE, "down(): '%s' not active (active is '%s'), skipping",
             name, active_id ? active_id : "");
        return TRUE;
    }

    DeactCtx ctx = {0};
    ctx.loop = g_main_loop_new(NULL, FALSE);

    nm_client_deactivate_connection_async(g_client, ac, NULL, on_deact_cb, &ctx);

    guint to = g_timeout_add(timeout_ms, quit_loop_cb, ctx.loop);
    g_main_loop_run(ctx.loop);
    g_source_remove(to);
    g_main_loop_unref(ctx.loop);

    return ctx.ok;
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
        if (g_str_has_prefix(s, "169.254."))
            continue;
        return TRUE;
    }
    return FALSE;
}

// check if is gateway reachable via ARP
static gboolean arping(const char *gw) {
    gchar *arp = g_find_program_in_path("arping");
    if (!arp) {
        log_msg(FALSE, "arping not found in PATH");
        return FALSE;
    }

    gchar *argv1[] = { arp, "-q", "-c", "1", "-w", "1",
                        "-I", (gchar*)IFACE, (gchar*)gw, NULL };
    GError *err = NULL;
    gint status = 0;
    gboolean ok = FALSE;

    if (g_spawn_sync(NULL, argv1, NULL,
                     G_SPAWN_STDOUT_TO_DEV_NULL |
                     G_SPAWN_STDERR_TO_DEV_NULL,
                     NULL, NULL, NULL, NULL, &status, &err)) {
        ok = g_spawn_check_wait_status(status, NULL);
    } else {
        log_msg(FALSE, "arping spawn failed: %s", err ? err->message : "unknown");
        g_clear_error(&err);
    }

    g_free(arp);
    return ok;
}

static gboolean ics_gw_is_reachable(void) {
    for (size_t i = 0; i < ICS_GWS_N; i++)
        if (arping(ICS_GWS[i]))
            return TRUE;
    return FALSE;
}

static void maybe_switch(const char *target) {
    NMDevice *dev = get_device();
    if (!dev) {
        log_msg(FALSE, "maybe_switch(): device not found");
        return;
    }

    const char *active = get_active_con_id(dev);
    if (g_strcmp0(active, target) == 0) {
        log_msg(FALSE, "maybe_switch(): already on %s", target);
        return;
    }
    gint64 t = now_s();
    if (t - last_switch < MINDWELL) {
        log_msg(FALSE, "maybe_switch(): switch too recent");
        return;
    }

    const char *other = (g_strcmp0(target, SHARED_ID) == 0) ? CLIENT_ID : SHARED_ID;
    log_msg(FALSE, "Switching to %s", target);

    if (down_and_wait(other, 5000)) {
        last_switch = now_s();
        if (up(target)) {
            if (g_strcmp0(target, CLIENT_ID) == 0) {
                client_deadline = now_s() + CLIENT_PROBE_WINDOW;
                last_gw_ok = 0; // <- reset; we haven't proved the GW yet
                log_msg(TRUE, "Trying DHCP client mode (deadline in %lds)", (long)CLIENT_PROBE_WINDOW);
            } else {
                log_msg(TRUE, "Switched to shared mode");
            }
        }
    } else {
        log_msg(FALSE, "failed to drop other profile; not switching");
    }
}

// --- main loop -------------------------------------------------------------

static gboolean periodic_check(gpointer user_data) {
    (void)user_data;

    NMDevice *dev = get_device();
    if (!dev) {
        log_msg(FALSE, "No device %s", IFACE);
        return G_SOURCE_CONTINUE;
    } else if (!carrier_up(dev)) {
        log_msg(FALSE, "Link down");
        return G_SOURCE_CONTINUE;
    }

    const char *name = get_active_con_id(dev);
    GPtrArray *addrs = NULL;
    const char *gw = NULL;
    ip4_config(dev, &addrs, &gw);

    if (g_strcmp0(name, CLIENT_ID) == 0) {
        // CLIENT mode
        const gboolean ok_ip = has_non_apipa(addrs);
        const gint64   now   = now_s();

        // If we don't even have a non-APIPA or a default GW yet, keep probing until deadline expires.
        if (!ok_ip || !gw) {
            if (client_deadline == 0)
                client_deadline = now + CLIENT_PROBE_WINDOW;
            const gint64 left = client_deadline - now;
            gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata);
            if (left > 0) {
                log_msg(FALSE, "CLIENT waiting: addrs=%s gw=%s (deadline %lds)",
                        joined ? joined : "(…)", gw ? gw : "(none)", (long)left);
            } else {
                log_msg(FALSE, "CLIENT failed (APIPA/no GW); back to SHARED, backoff %lds",
                        (long)BACKOFF_AFTER_FAIL);
                backoff_until = now + BACKOFF_AFTER_FAIL;
                maybe_switch(SHARED_ID);
            }

            g_free(joined);
            g_ptr_array_free(addrs, TRUE);
            return G_SOURCE_CONTINUE;
        }

        // We have non-APIPA and a GW configured — validate that the GW actually answers ARP.
        if (arping(gw)) {
            last_gw_ok = now;
            gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata);
            log_msg(FALSE, "CLIENT OK: addrs=%s gw=%s", joined ? joined : "(…)", gw);
            g_free(joined);
            g_ptr_array_free(addrs, TRUE);
            return G_SOURCE_CONTINUE;
        }

        // GW not responding; hold CLIENT for a short grace, then fall back to SHARED.
        if (last_gw_ok == 0)
            last_gw_ok = now; // start the grace window the first time it fails
        const gint64 since_ok = now - last_gw_ok;
        const gint64 left = (since_ok < GW_LOSS_GRACE) ? (GW_LOSS_GRACE - since_ok) : 0;

        if (left > 0) {
            gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata);
            log_msg(FALSE, "CLIENT: GW %s not responding; grace %lds left (addrs=%s)",
                    gw, (long)left, joined ? joined : "(…)");
            g_free(joined);
        } else {
            log_msg(FALSE, "CLIENT: GW %s lost for >=%lds; back to SHARED (backoff %lds)",
                    gw, (long)GW_LOSS_GRACE, (long)BACKOFF_AFTER_FAIL);
            backoff_until = now + BACKOFF_AFTER_FAIL;
            maybe_switch(SHARED_ID);
        }

        g_ptr_array_free(addrs, TRUE);
        return G_SOURCE_CONTINUE;
    }
    
    if (g_strcmp0(name, SHARED_ID) == 0) {
        // SHARED: stay put unless backoff expired AND ICS GW looks present -> try CLIENT once
        gchar *joined = g_strjoinv(",", (gchar **)addrs->pdata);
        log_msg(FALSE, "SHARED: addrs=%s", joined ? joined : "(…)"); g_free(joined);

        if (now_s() >= backoff_until && ics_gw_is_reachable()) {
            log_msg(FALSE, "SHARED: ICS GW responded; trying CLIENT");
            maybe_switch(CLIENT_ID);
        } else if (now_s() < backoff_until) {
            log_msg(FALSE, "SHARED: backoff active (%lds left)", (long)(backoff_until - now_s()));
        } else {
            log_msg(FALSE, "SHARED: no ICS GW; staying");
        }

        g_ptr_array_free(addrs, TRUE);
        return G_SOURCE_CONTINUE;
    }

    // No profile yet: start by trying CLIENT once (then logic above handles fallback/backoff)
    if (!is_transitioning(dev)) {
        up(CLIENT_ID);
        client_deadline = now_s() + CLIENT_PROBE_WINDOW;
        last_switch = now_s();
    } else {
        log_msg(FALSE, "Activation in progress; not reissuing up()");
    }

    g_ptr_array_free(addrs, TRUE);
    return G_SOURCE_CONTINUE;
}

// --- boilerplate -----------------------------------------------------------

static void on_sigint(int signum) {
    (void)signum;
    log_msg(TRUE, "SIGINT received, exiting");
    if (g_loop)
        g_main_loop_quit(g_loop);
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;

    const char *dbg = g_getenv(ENV_DEBUG);
    g_debug = (dbg && strcmp(dbg, "0") != 0);

    const char *iface_env = g_getenv(ENV_IFACE);
    if (iface_env && *iface_env)
        IFACE = iface_env;

    GError *err = NULL;
    g_client = nm_client_new(NULL, &err);
    if (!g_client) {
        g_printerr("Failed to create NMClient: %s\n", err ? err->message : "unknown error");
        g_clear_error(&err);
        return 1;
    }

    log_msg(TRUE, "Starting ICS watcher (debug=%d) on %s", g_debug, IFACE);

    g_loop = g_main_loop_new(NULL, FALSE);
    g_timeout_add(LOOP_MS, periodic_check, NULL);

    // SIGINT
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_sigint;
    sigaction(SIGINT, &sa, NULL);

    g_main_loop_run(g_loop);

    g_main_loop_unref(g_loop);
    g_clear_object(&g_client);
    return 0;
}
