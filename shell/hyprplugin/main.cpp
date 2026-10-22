// hyprshell-minimize: an app's own minimise button, passed on.
//
// Hyprland drops the minimise request an app sends from its title bar
// (xdg_toplevel.set_minimized, or _NET_WM_STATE_HIDDEN from an X11 app):
// it has no minimised state of its own. This passes the request on as the
// "minimized" event a taskbar's request already raises on Hyprland's
// socket — minimized>>ADDRESS,1 — and the shell puts the window away
// (services/Compositor.qml), the same way as Super+Down or the dock.
//
// Built against the installed Hyprland's headers by install.sh, and
// loaded by hyprland.lua at start; rebuilt whenever Hyprland updates.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/managers/EventManager.hpp>

#include <format>
#include <unordered_map>

static HANDLE PHANDLE = nullptr;

namespace {
    // The window open event's listener, and one per window for its requests.
    CHyprSignalListener                                         g_onOpen;
    CHyprSignalListener                                         g_onClose;
    std::unordered_map<const void*, CHyprSignalListener>       g_watch;

    void announce(const PHLWINDOW& w, bool minimised) {
        if (!w || !g_pEventManager)
            return;
        g_pEventManager->postEvent(SHyprIPCEvent{
            .event = "minimized",
            .data  = std::format("{:x},{}", reinterpret_cast<uintptr_t>(w.get()), minimised ? 1 : 0),
        });
    }

    void watch(PHLWINDOW w) {
        if (!w || g_watch.contains(w.get()))
            return;
        const PHLWINDOWREF ref = w;
        if (const auto xdg = w->m_xdgSurface.lock(); xdg && xdg->m_toplevel) {
            const WP<CXDGToplevelResource> top = xdg->m_toplevel;
            g_watch[w.get()] = top->m_events.stateChanged.listen([ref, top] {
                const auto T = top.lock();
                if (T && T->m_state.requestsMinimize.value_or(false))
                    announce(ref.lock(), true);
            });
        } else if (const auto x = w->m_xwaylandSurface.lock()) {
            const WP<CXWaylandSurface> xs = x;
            g_watch[w.get()] = x->m_events.stateChanged.listen([ref, xs] {
                const auto X = xs.lock();
                if (X && X->m_state.requestsMinimize.has_value())
                    announce(ref.lock(), *X->m_state.requestsMinimize);
            });
        }
    }
}

APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    // Built for another Hyprland than this one: refuse rather than crash.
    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();
    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(PHANDLE, "[hyprshell-minimize] Built for another Hyprland: the shell builds it again shortly",
                                     CHyprColor{1.0, 0.4, 0.3, 1.0}, 8000);
        throw std::runtime_error("[hyprshell-minimize] version mismatch");
    }

    g_onOpen  = Event::bus()->m_events.window.open.listen([](PHLWINDOW w) { watch(w); });
    g_onClose = Event::bus()->m_events.window.close.listen([](PHLWINDOW w) {
        if (w)
            g_watch.erase(w.get());
    });

    return {"hyprshell-minimize", "Passes an app's own minimise request on to the shell", "hyprshell", "1.0"};
}

APICALL EXPORT void PLUGIN_EXIT() {
    g_watch.clear();
    g_onOpen.reset();
    g_onClose.reset();
}
