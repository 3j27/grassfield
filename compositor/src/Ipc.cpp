#include "Ipc.hpp"

#include "AppmenuServer.hpp"
#include "Minimize.hpp"
#include "Plugin.hpp"
#include "core/Minimize.hpp"
#include "core/Protocol.hpp"

#include <hyprland/src/managers/EventManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>

#include <lua.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace gf::ipc {

    namespace {
        struct SEvents {
            events::CEventThrottle           throttle;
            SP<CEventLoopTimer>              timer;    // CEventLoopManager keeps only a weak reference
            std::optional<events::TimePoint> armedFor; // when the timer fires, if armed
            bool                             running       = false;
            uint64_t                         seenCoalesced = 0;
        };

        // Constructed on first use inside a guarded call (R13); stopEvents() removes the timer before dlclose.
        SEvents& evs() {
            static SEvents s;
            return s;
        }

        void postNow(const std::string& json) {
            if (!g_pEventManager)
                return; // shutting down: nobody listens
            g_pEventManager->postEvent(SHyprIPCEvent{.event = std::string{gfc::kEventName}, .data = json});
        }

        void postAll(const std::vector<std::string>& payloads) {
            for (const auto& p : payloads)
                postNow(p);
        }

        // One line per power of ten (1, 10, 100, ...): a flood shows in the log without flooding it.
        void noteCoalesced() {
            auto&          s = evs();
            const uint64_t c = s.throttle.coalesced();
            if (c == s.seenCoalesced)
                return;
            s.seenCoalesced = c;
            if (events::isLogMilestone(c))
                log(Log::INFO, "events: {} superseded by a newer event of the same window before posting (coalesced, at most one per window per 100 ms)", c);
        }

        void schedule(events::TimePoint now);

        void onTimer() {
            guarded("event throttle timer", [] {
                auto& s = evs();
                s.armedFor.reset(); // CEventLoopTimer::call() disarms the timer before calling back
                if (!s.running)
                    return;
                const auto now = events::Clock::now();
                postAll(s.throttle.due(now));
                schedule(now);
            });
        }

        // Arms the timer for the next waiting event (only when that is earlier than what it is armed for).
        void schedule(events::TimePoint now) {
            auto&      s    = evs();
            const auto next = s.throttle.nextDue(now);
            if (!next || (s.armedFor && *s.armedFor <= *next))
                return;
            if (!g_pEventLoopManager) {
                postAll(s.throttle.drain()); // no event loop (should not happen): no coalescing, nothing lost
                return;
            }
            if (!s.timer) {
                s.timer = makeShared<CEventLoopTimer>(std::nullopt, [](const SP<CEventLoopTimer>& /*self*/, void* /*data*/) { onTimer(); }, nullptr);
                g_pEventLoopManager->addTimer(s.timer);
            }
            s.timer->updateTimeout(std::max<events::Duration>(*next - now, std::chrono::milliseconds(1)));
            s.armedFor = *next;
        }
    } // namespace

    void postEvent(events::Key key, std::string json) {
        auto& s = evs();
        if (!s.running) {
            postNow(json); // before startEvents() or while unloading: no timer may be created
            return;
        }
        const auto now = events::Clock::now();
        postAll(s.throttle.submit(key, std::move(json), now));
        noteCoalesced();
        schedule(now);
    }

    void startEvents() {
        evs().running = true;
    }

    void stopEvents() {
        auto& s   = evs();
        s.running = false;
        if (s.timer) {
            if (g_pEventLoopManager)
                g_pEventLoopManager->removeTimer(s.timer);
            s.timer.reset();
        }
        s.armedFor.reset();
        postAll(s.throttle.drain()); // the final state of every key still reaches the shell
    }

    bool minimizeAvailable() {
        const auto& s = state();
        return s.luaMinimizeRegistered && s.luaRestoreRegistered && minimizer::ready();
    }

    bool appmenuAvailable() {
        return state().luaAppmenuRegistered && appmenuServer::ready();
    }

    namespace {
        std::string currentCapabilities() {
            const auto features = gfc::features(minimizeAvailable(), state().luaConfigRegistered, appmenuAvailable());
            return gfc::capabilitiesJson(features);
        }
    } // namespace

    void postCapabilities() {
        postEvent(events::Key{.channel = events::Channel::Capabilities, .id = 0}, currentCapabilities());
    }

    namespace {
        // Lua C functions report errors with longjmp, so their own frames hold only trivially destructible
        // values: the arguments are copied into these plain structs with non-raising Lua calls (lua_type,
        // lua_tolstring on strings, lua_tonumberx), and all C++ work runs in separate noexcept functions that
        // have returned before any further Lua call.
        template <size_t N>
        struct SLuaString {
            std::array<char, N> text{};
            size_t              size = 0;
            bool                ok   = false;

            std::string_view    view() const {
                return {text.data(), size};
            }
        };

        template <size_t N>
        SLuaString<N> readString(lua_State* L, int idx) {
            SLuaString<N> out;
            if (lua_type(L, idx) != LUA_TSTRING)
                return out;
            size_t      len = 0;
            const char* s   = lua_tolstring(L, idx, &len);
            if (!s || len >= N)
                return out;
            std::memcpy(out.text.data(), s, len);
            out.size = len;
            out.ok   = true;
            return out;
        }

        struct SWindowCall {
            SLuaString<24>        address;     // "0x" + 16 hex digits fits
            std::array<double, 4> rect{};      // x, y, w, h (layout coordinates)
            bool                  rectOk = false;
        };

        SWindowCall readWindowCall(lua_State* L) {
            SWindowCall call;
            call.address = readString<24>(L, 1);
            call.rectOk  = true;
            for (int i = 0; i < 4; ++i) {
                int isNumber = 0;
                if (lua_type(L, 2 + i) != LUA_TNUMBER) {
                    call.rectOk = false;
                    break;
                }
                call.rect[static_cast<size_t>(i)] = lua_tonumberx(L, 2 + i, &isNumber);
                if (!isNumber) {
                    call.rectOk = false;
                    break;
                }
            }
            return call;
        }

        void windowCallNoThrow(const SWindowCall& call, bool isMinimize) noexcept {
            guarded(isMinimize ? "hl.plugin.grassfield.minimize" : "hl.plugin.grassfield.restore", [&] {
                const auto address = call.address.ok ? minimize::parseAddress(call.address.view()) : std::nullopt;
                if (!address) {
                    log(Log::WARN, "{}: rejected: invalid window address", isMinimize ? "minimize" : "restore");
                    return;
                }
                std::optional<minimize::Box> target;
                if (call.rectOk)
                    target = minimizer::validTarget(minimize::Box{call.rect[0], call.rect[1], call.rect[2], call.rect[3]});
                if (!target)
                    log(Log::INFO, "{} {:x}: no valid Dock rectangle, no animation", isMinimize ? "minimize" : "restore", *address);
                if (isMinimize)
                    minimizer::minimize(*address, target);
                else
                    minimizer::restore(*address, target);
            });
        }

        void configNoThrow(const SLuaString<64>& key, const SLuaString<16>& value) noexcept {
            guarded("hl.plugin.grassfield.config", [&] {
                const auto action = key.ok && value.ok ? gfc::parseDoubleClickAction(key.view(), value.view()) : std::nullopt;
                if (!action) {
                    log(Log::WARN, "config: rejected (only {} = zoom|minimize|none is accepted)", gfc::kConfigTitlebarDoubleClick);
                    return;
                }
                state().doubleClickAction = *action;
                log(Log::INFO, "config: {} = {}", gfc::kConfigTitlebarDoubleClick, value.view());
            });
        }

        void helloNoThrow() noexcept {
            guarded("hl.plugin.grassfield.hello", [] { postCapabilities(); });
        }

        void appmenuNoThrow(const SLuaString<24>& address) noexcept {
            guarded("hl.plugin.grassfield.appmenu", [&] {
                const auto window = address.ok ? minimize::parseAddress(address.view()) : std::nullopt;
                if (!window) {
                    log(Log::WARN, "appmenu: rejected: invalid window address");
                    return;
                }
                if (!appmenuServer::announce(*window))
                    log(Log::WARN, "appmenu: no mapped window {:x} (or appmenu inactive)", *window);
            });
        }

        // Pushes the result of hl.dsp.no_op() so that `hl.dispatch(hl.plugin.grassfield.hello())` (what
        // `hyprctl dispatch` / Quickshell's Hyprland.dispatch() evaluate under the Lua config) succeeds.
        // Pushes nothing if the dispatcher can't be obtained. Only trivially destructible values live in
        // this frame, because Lua reports errors with longjmp.
        int pushNoOpDispatcher(lua_State* L) {
            const int top = lua_gettop(L);

            const int hlType = lua_getglobal(L, "hl");
            if (hlType != LUA_TTABLE && hlType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            const int dspType = lua_getfield(L, -1, "dsp");
            if (dspType != LUA_TTABLE && dspType != LUA_TUSERDATA) {
                lua_settop(L, top);
                return 0;
            }
            if (lua_getfield(L, -1, "no_op") != LUA_TFUNCTION) {
                lua_settop(L, top);
                return 0;
            }
            if (lua_pcall(L, 0, 1, 0) != LUA_OK) {
                lua_settop(L, top);
                return 0;
            }

            lua_replace(L, top + 1); // result replaces `hl`
            lua_settop(L, top + 1);
            return 1;
        }

        int luaHello(lua_State* L) {
            helloNoThrow();
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.minimize(address, x, y, w, h): address "0x<hex>" of a mapped window; the rect is
        // the Dock tile (layout coordinates) the window shrinks into. Untrusted: validated, never interpolated.
        int luaMinimize(lua_State* L) {
            const SWindowCall call = readWindowCall(L);
            windowCallNoThrow(call, true);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.restore(address, x, y, w, h): the rect is the Dock tile it grows from.
        int luaRestore(lua_State* L) {
            const SWindowCall call = readWindowCall(L);
            windowCallNoThrow(call, false);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.config(key, value): allowlisted settings only.
        int luaConfig(lua_State* L) {
            const auto key   = readString<64>(L, 1);
            const auto value = readString<16>(L, 2);
            configNoThrow(key, value);
            return pushNoOpDispatcher(L);
        }

        // hl.plugin.grassfield.appmenu(address): re-posts the appmenu event of a mapped window (the shell calls it
        // after a restart). Untrusted: the address is parsed and compared with the live windows.
        int luaAppmenu(lua_State* L) {
            const auto address = readString<24>(L, 1);
            appmenuNoThrow(address);
            return pushNoOpDispatcher(L);
        }

        std::string hyprctlGrassfield(eHyprCtlOutputFormat /*format*/, const std::string& /*args*/) noexcept {
            // Same JSON for both output formats: the payload is already machine-readable.
            std::string out;
            if (!guarded("hyprctl grassfield", [&] { out = currentCapabilities(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

        bool addLua(std::string_view name, PLUGIN_LUA_FN fn) {
            const bool ok = HyprlandAPI::addLuaFunction(state().handle, std::string{gfc::kLuaNamespace}, std::string{name}, fn);
            if (!ok)
                log(Log::ERR, "addLuaFunction({}.{}) failed", gfc::kLuaNamespace, name);
            return ok;
        }

        void removeLua(bool& registered, std::string_view name) {
            if (!registered)
                return;
            HyprlandAPI::removeLuaFunction(state().handle, std::string{gfc::kLuaNamespace}, std::string{name});
            registered = false;
        }

    } // namespace

    bool registerAll() {
        auto& s = state();

        // No HyprlandAPI::addDispatcherV2: with Hyprland's Lua config, `hyprctl dispatch X` (and
        // Quickshell's Hyprland.dispatch) evaluate `return hl.dispatch(X)`, so a legacy plugin
        // dispatcher name such as "grassfield:hello" is a Lua syntax error and can never be reached
        // (measured in spike S2, see docs/specs/compositor.md). Lua functions are the entry points.
        s.luaHelloRegistered    = addLua(gfc::kLuaHello, luaHello);
        s.luaMinimizeRegistered = addLua(gfc::kLuaMinimize, luaMinimize);
        s.luaRestoreRegistered  = addLua(gfc::kLuaRestore, luaRestore);
        s.luaConfigRegistered   = addLua(gfc::kLuaConfig, luaConfig);
        s.luaAppmenuRegistered  = appmenuServer::ready() && addLua(gfc::kLuaAppmenu, luaAppmenu); // only with the global
        bool ok                 = s.luaHelloRegistered && s.luaMinimizeRegistered && s.luaRestoreRegistered && s.luaConfigRegistered;

        s.hyprctlCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{gfc::kHyprctlCommand}, .exact = true, .fn = hyprctlGrassfield});
        if (!s.hyprctlCommand) {
            log(Log::ERR, "registerHyprCtlCommand({}) failed", gfc::kHyprctlCommand);
            ok = false;
        }

        return ok;
    }

    void unregisterAll() {
        auto& s = state();
        removeLua(s.luaHelloRegistered, gfc::kLuaHello);
        removeLua(s.luaMinimizeRegistered, gfc::kLuaMinimize);
        removeLua(s.luaRestoreRegistered, gfc::kLuaRestore);
        removeLua(s.luaConfigRegistered, gfc::kLuaConfig);
        removeLua(s.luaAppmenuRegistered, gfc::kLuaAppmenu);
        if (s.hyprctlCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlCommand);
            s.hyprctlCommand.reset();
        }
    }

} // namespace gf::ipc
