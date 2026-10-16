#include "Ipc.hpp"

#include "Plugin.hpp"
#include "core/Protocol.hpp"

#include <hyprland/src/managers/EventManager.hpp>

#include <lua.hpp>

#include <string>

namespace gf::ipc {

    void postEvent(const std::string& json) {
        if (!g_pEventManager) {
            log(Log::WARN, "event manager unavailable, dropped event {}", json);
            return;
        }
        g_pEventManager->postEvent(SHyprIPCEvent{.event = std::string{gfc::kEventName}, .data = json});
    }

    void postCapabilities() {
        postEvent(gfc::capabilitiesJson());
    }

    namespace {
        void helloNoThrow() noexcept {
            guarded("hl.plugin.grassfield.hello", [] { postCapabilities(); });
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

        std::string hyprctlGrassfield(eHyprCtlOutputFormat /*format*/, std::string /*args*/) noexcept {
            // Same JSON for both output formats: the payload is already machine-readable.
            std::string out;
            if (!guarded("hyprctl grassfield", [&] { out = gfc::capabilitiesJson(); }))
                out = R"({"v":"gfc/1","type":"error"})";
            return out;
        }

    } // namespace

    bool registerAll() {
        auto& s  = state();
        bool  ok = true;

        // No HyprlandAPI::addDispatcherV2: with Hyprland's Lua config, `hyprctl dispatch X` (and
        // Quickshell's Hyprland.dispatch) evaluate `return hl.dispatch(X)`, so a legacy plugin
        // dispatcher name such as "grassfield:hello" is a Lua syntax error and can never be reached
        // (measured in spike S2, see docs/specs/compositor.md). Lua functions are the entry points.
        s.luaHelloRegistered = HyprlandAPI::addLuaFunction(s.handle, std::string{gfc::kLuaNamespace}, std::string{gfc::kLuaHello}, luaHello);
        if (!s.luaHelloRegistered) {
            log(Log::ERR, "addLuaFunction({}.{}) failed", gfc::kLuaNamespace, gfc::kLuaHello);
            ok = false;
        }

        s.hyprctlCommand = HyprlandAPI::registerHyprCtlCommand(s.handle, SHyprCtlCommand{.name = std::string{gfc::kHyprctlCommand}, .exact = true, .fn = hyprctlGrassfield});
        if (!s.hyprctlCommand) {
            log(Log::ERR, "registerHyprCtlCommand({}) failed", gfc::kHyprctlCommand);
            ok = false;
        }

        return ok;
    }

    void unregisterAll() {
        auto& s = state();
        if (s.luaHelloRegistered) {
            HyprlandAPI::removeLuaFunction(s.handle, std::string{gfc::kLuaNamespace}, std::string{gfc::kLuaHello});
            s.luaHelloRegistered = false;
        }
        if (s.hyprctlCommand) {
            HyprlandAPI::unregisterHyprCtlCommand(s.handle, s.hyprctlCommand);
            s.hyprctlCommand.reset();
        }
    }

} // namespace gf::ipc
