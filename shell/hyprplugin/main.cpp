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

// Hyprland 0.57 gave each window a "backend" (Wayland or X11) that passes on
// what the app asks for, minimising included (which Hyprland still drops),
// and moved the event socket to IPC::Socket2. Before it, the request was on
// the app's own XDG or XWayland surface.
#if __has_include(<hyprland/src/desktop/view/window/Window.hpp>)
#define HYPRSHELL_BACKENDS 1
#include <hyprland/src/desktop/view/window/Window.hpp>
#include <hyprland/src/desktop/view/window/WindowBackend.hpp>
#include <hyprland/src/ipc/s2/S2.hpp>
#else
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/protocols/XDGShell.hpp>
#include <hyprland/src/xwayland/XSurface.hpp>
#include <hyprland/src/managers/EventManager.hpp>
#endif

#include <format>
#include <unordered_map>

static HANDLE PHANDLE = nullptr;

namespace {
    // The window open event's listener, and one per window for its requests.
    CHyprSignalListener                                         g_onOpen;
    CHyprSignalListener                                         g_onClose;
    std::unordered_map<const void*, CHyprSignalListener>       g_watch;

    // `event` is "minimized" (an app's minimise button) or "maximize" (its
    // maximise button: ADDRESS,1 to fill the screen, ADDRESS,0 to give it back).
    void announce(const PHLWINDOW& w, bool on, const char* event = "minimized") {
        if (!w)
            return;
        const auto data = std::format("{:x},{}", reinterpret_cast<uintptr_t>(w.get()), on ? 1 : 0);
#ifdef HYPRSHELL_BACKENDS
        if (const auto& sock = IPC::Socket2::sock())
            sock->postEvent({.event = event, .data = data});
#else
        if (g_pEventManager)
            g_pEventManager->postEvent(SHyprIPCEvent{.event = event, .data = data});
#endif
    }

    void watch(PHLWINDOW w) {
        if (!w || g_watch.contains(w.get()))
            return;
        const PHLWINDOWREF ref = w;
#ifdef HYPRSHELL_BACKENDS
        g_watch[w.get()] = w->backend().m_events.stateRequest.listen([ref](const Desktop::View::SBackendStateRequest& r) {
            if (r.minimized.value_or(false))
                announce(ref.lock(), true);
            // Hyprland's own answer to a maximise request is to flip the
            // window between floating and tiled; the shell does the real one.
            if (r.maximized.has_value())
                announce(ref.lock(), *r.maximized, "maximize");
        });
#else
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
#endif
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
