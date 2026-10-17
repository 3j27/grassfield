#include "Protocol.hpp"

#include <array>
#include <cstdint>

namespace gf::gfc {

    std::string jsonEscape(std::string_view in) {
        static constexpr std::array<char, 16> HEX = {'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'};

        std::string out;
        out.reserve(in.size() + 2);
        for (const char c : in) {
            switch (c) {
                case '"': out += "\\\""; break;
                case '\\': out += "\\\\"; break;
                case '\b': out += "\\b"; break;
                case '\f': out += "\\f"; break;
                case '\n': out += "\\n"; break;
                case '\r': out += "\\r"; break;
                case '\t': out += "\\t"; break;
                default: {
                    const auto u = static_cast<uint8_t>(c);
                    if (u < 0x20) {
                        out += "\\u00";
                        out += HEX[u >> 4];
                        out += HEX[u & 0xF];
                    } else
                        out += c; // UTF-8 bytes >= 0x80 pass through unchanged
                }
            }
        }
        return out;
    }

    namespace {
        void appendHeader(std::string& out, std::string_view type) {
            out += R"({"v":")";
            out += jsonEscape(kVersion);
            out += R"(","type":")";
            out += jsonEscape(type);
            out += '"';
        }
    } // namespace

    std::string capabilitiesJson(std::span<const std::string_view> features) {
        std::string out;
        appendHeader(out, "capabilities");
        out += R"(,"features":[)";
        bool first = true;
        for (const auto& f : features) {
            if (!first)
                out += ',';
            first = false;
            out += '"';
            out += jsonEscape(f);
            out += '"';
        }
        out += "]}";
        return out;
    }

    namespace {
        std::string windowEventJson(std::string_view type, std::string_view windowAddress) {
            std::string out;
            appendHeader(out, type);
            out += R"(,"address":")";
            out += jsonEscape(windowAddress);
            out += "\"}";
            return out;
        }
    } // namespace

    std::string minimizeRequestJson(std::string_view windowAddress) {
        return windowEventJson("minimize-request", windowAddress);
    }

    std::string minimizedJson(std::string_view windowAddress) {
        return windowEventJson("minimized", windowAddress);
    }

    std::string restoredJson(std::string_view windowAddress) {
        return windowEventJson("restored", windowAddress);
    }

    std::string appmenuJson(std::string_view windowAddress, std::string_view service, std::string_view path) {
        std::string out;
        appendHeader(out, "appmenu");
        out += R"(,"address":")";
        out += jsonEscape(windowAddress);
        out += R"(","service":")";
        out += jsonEscape(service);
        out += R"(","path":")";
        out += jsonEscape(path);
        out += "\"}";
        return out;
    }

    std::vector<std::string_view> features(bool minimize, bool config, bool appmenu) {
        std::vector<std::string_view> out{kFeatureDecorations};
        if (minimize)
            out.push_back(kFeatureMinimize);
        if (config)
            out.push_back(kFeatureConfig);
        if (appmenu)
            out.push_back(kFeatureAppmenu);
        return out;
    }

    std::optional<DoubleClickAction> parseDoubleClickAction(std::string_view key, std::string_view value) {
        if (key != kConfigTitlebarDoubleClick)
            return std::nullopt;
        if (value == "zoom")
            return DoubleClickAction::Zoom;
        if (value == "minimize")
            return DoubleClickAction::Minimize;
        if (value == "none")
            return DoubleClickAction::None;
        return std::nullopt;
    }

    std::string luaDispatchRequest(std::string_view verb) {
        std::string out{"hl.plugin."};
        out += kLuaNamespace;
        out += '.';
        out += verb;
        out += "()";
        return out;
    }

    std::string socket2Line(std::string_view json) {
        std::string out{kEventName};
        out += ">>";
        out += json;
        return out;
    }

} // namespace gf::gfc
