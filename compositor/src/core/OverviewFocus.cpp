#include "OverviewFocus.hpp"

#include "Json.hpp"
#include "Minimize.hpp"
#include "Protocol.hpp"

#include <algorithm>
#include <cmath>
#include <format>

namespace gf::overviewfocus {

    namespace {
        using Error = std::unexpected<std::string>;

        std::optional<Target> targetFromName(std::string_view name) {
            if (name == "window")
                return Target::Window;
            if (name == "workspace")
                return Target::Workspace;
            if (name == "remembered")
                return Target::Remembered;
            if (name == "none")
                return Target::None;
            return std::nullopt; // "press" is never requested
        }

        // An integer in min..max read as a JSON number (a finite double holding an integer value).
        std::optional<int64_t> integer(gf::json::CReader& in, int64_t min, int64_t max) {
            const auto n = in.number();
            if (!n || *n != std::floor(*n) || *n < static_cast<double>(min) || *n > static_cast<double>(max))
                return std::nullopt;
            return static_cast<int64_t>(*n);
        }
    } // namespace

    std::string_view targetName(Target target) {
        switch (target) {
            case Target::Window: return "window";
            case Target::Workspace: return "workspace";
            case Target::Remembered: return "remembered";
            case Target::None: return "none";
            case Target::Press: return "press";
        }
        return "none";
    }

    std::expected<Request, std::string> parseRequest(std::string_view json) {
        if (json.size() > kMaxPayloadBytes)
            return Error{std::format("payload larger than {} bytes", kMaxPayloadBytes)};
        gf::json::CReader in{json, kMaxStringBytes, kMaxDepth};
        Request           request;
        bool              haveTarget = false, haveAddress = false, haveWorkspace = false, haveId = false;
        if (!in.take('{'))
            return Error{"not a JSON object"};
        const auto once = [](bool& seen) {
            const bool first = !seen;
            seen             = true;
            return first;
        };
        if (!in.take('}')) {
            do {
                const auto key = in.string();
                if (!key || !in.take(':'))
                    return Error{"malformed member"};
                if (*key == "target") {
                    if (!once(haveTarget))
                        return Error{"target given twice"};
                    const auto name   = in.string();
                    const auto target = name ? targetFromName(*name) : std::nullopt;
                    if (!target)
                        return Error{"target is not \"window\", \"workspace\", \"remembered\" or \"none\""};
                    request.target = *target;
                } else if (*key == "address") {
                    if (!once(haveAddress))
                        return Error{"address given twice"};
                    const auto text    = in.string();
                    const auto address = text ? gf::minimize::parseAddress(*text) : std::nullopt;
                    if (!address || *address == 0)
                        return Error{"address is not 1-16 hex digits (\"0x\" optional), not 0"};
                    request.window = *address;
                } else if (*key == "workspace") {
                    if (!once(haveWorkspace))
                        return Error{"workspace given twice"};
                    const auto id = integer(in, 1, kMaxWorkspaceId);
                    if (!id)
                        return Error{std::format("workspace is not an integer in 1..{}", kMaxWorkspaceId)};
                    request.workspace = *id;
                } else if (*key == "id") {
                    if (!once(haveId))
                        return Error{"id given twice"};
                    const auto id = integer(in, 0, static_cast<int64_t>(kMaxRequestId));
                    if (!id)
                        return Error{std::format("id is not an integer in 0..{}", kMaxRequestId)};
                    request.id = static_cast<uint32_t>(*id);
                } else if (!in.skipValue())
                    return Error{std::format("malformed value of {}", *key)};
            } while (in.take(','));
            if (!in.take('}'))
                return Error{"malformed object"};
        }
        if (!in.atEnd())
            return Error{"trailing characters after the object"};
        if (!haveTarget)
            return Error{"target is required"};
        switch (request.target) {
            case Target::Window:
                if (!haveAddress)
                    return Error{"target window needs an address"};
                if (haveWorkspace)
                    return Error{"target window takes no workspace (the window's own Desktop is used)"};
                break;
            case Target::Workspace:
                if (!haveWorkspace)
                    return Error{"target workspace needs a workspace"};
                if (haveAddress)
                    return Error{"target workspace takes no address"};
                break;
            case Target::Remembered:
                if (!haveAddress)
                    return Error{"target remembered needs an address (no window remembered: target none)"};
                break;
            case Target::None:
                if (haveAddress || haveWorkspace)
                    return Error{"target none takes no address and no workspace"};
                break;
            case Target::Press: return Error{"target press cannot be requested"};
        }
        return request;
    }

    Step step(const Gate& gate) {
        if (gate.locked)
            return Step::Refuse;
        if (gate.exclusive)
            return gate.expired ? Step::Timeout : Step::Wait;
        return Step::Apply;
    }

    WindowVerdict judgeWindow(const WindowFacts& facts) {
        if (!facts.exists)
            return WindowVerdict::Gone;
        if (facts.minimized)
            return WindowVerdict::Minimized;
        if (facts.hidden)
            return WindowVerdict::Hidden;
        if (!facts.shown)
            return WindowVerdict::NotShown;
        return WindowVerdict::Eligible;
    }

    PlanResult plan(Target target, WindowVerdict window, const WorkspaceFacts& workspace) {
        switch (target) {
            case Target::Window:
            case Target::Remembered:
            case Target::Press:
                switch (window) {
                    case WindowVerdict::Eligible: return {.plan = Plan::FocusWindow, .why = ""};
                    case WindowVerdict::Gone: return {.plan = Plan::Fallback, .why = "gone"};
                    case WindowVerdict::Hidden: return {.plan = Plan::Fallback, .why = "hidden"};
                    case WindowVerdict::Minimized: return {.plan = Plan::Fallback, .why = "minimized"};
                    case WindowVerdict::NotShown: return {.plan = Plan::Fallback, .why = "not-shown"};
                }
                return {.plan = Plan::Fallback, .why = "gone"};
            case Target::Workspace:
                if (!workspace.exists)
                    return {.plan = Plan::Fallback, .why = "no-workspace"};
                return {.plan = workspace.shown ? Plan::Front : Plan::SwitchThenFront, .why = ""};
            case Target::None: return {.plan = Plan::Fallback, .why = "none"};
        }
        return {.plan = Plan::Fallback, .why = "none"};
    }

    FallbackSpace fallbackSpace(Target target, bool rememberedShown) {
        return target == Target::Remembered && rememberedShown ? FallbackSpace::Remembered : FallbackSpace::FocusedMonitor;
    }

    std::vector<WindowId> frontOrder(std::span<const Candidate> bottomToTop) {
        const auto eligible = [](const Candidate& c) { return c.id != 0 && c.onWorkspace && c.mapped && !c.hidden && c.takesInput && c.focusable; };
        std::vector<WindowId> out;
        struct SRanked {
            WindowId id    = 0;
            uint64_t seq   = 0;
            size_t   level = 0; // stack position, higher is closer to the top
        };
        std::vector<SRanked> ranked;
        for (size_t i = 0; i < bottomToTop.size(); ++i) {
            const auto& c = bottomToTop[i];
            if (eligible(c) && std::ranges::none_of(ranked, [&c](const SRanked& r) { return r.id == c.id; }))
                ranked.push_back(SRanked{.id = c.id, .seq = c.focusSeq, .level = i});
        }
        std::ranges::sort(ranked, [](const SRanked& a, const SRanked& b) { return a.seq != b.seq ? a.seq > b.seq : a.level > b.level; });
        out.reserve(ranked.size());
        for (const auto& r : ranked)
            out.push_back(r.id);
        return out;
    }

    PressEffect pressEffect(const gf::deferredfocus::PressRecord& press) {
        switch (press.scope) {
            case gf::deferredfocus::PressScope::None: return PressEffect::None;
            case gf::deferredfocus::PressScope::ThisPress: return PressEffect::Supersede;
            case gf::deferredfocus::PressScope::UntilFocus: return press.target != 0 ? PressEffect::Retarget : PressEffect::None;
        }
        return PressEffect::None;
    }

    bool supersedes(gf::deferredfocus::FocusOrigin origin, bool isTarget) {
        return origin == gf::deferredfocus::FocusOrigin::UserChoice && !isTarget;
    }

    std::string_view outcomeName(Outcome outcome) {
        switch (outcome) {
            case Outcome::Pending: return "pending";
            case Outcome::Focused: return "focused";
            case Outcome::Fallback: return "fallback";
            case Outcome::Timeout: return "timeout";
            case Outcome::Refused: return "refused";
            case Outcome::Superseded: return "superseded";
            case Outcome::Unavailable: return "unavailable";
            case Outcome::Invalid: return "invalid";
        }
        return "pending";
    }

    std::string eventJson(const Event& event) {
        std::string out{R"({"v":")"};
        out += gf::gfc::jsonEscape(gf::gfc::kVersion);
        out += R"(","type":"overview-focus","outcome":")";
        out += outcomeName(event.outcome);
        out += R"(","target":")";
        out += targetName(event.target);
        out += std::format(R"(","id":{})", event.id);
        if (event.window)
            out += std::format(R"(,"address":"{:x}")", *event.window);
        if (event.workspace)
            out += std::format(R"(,"workspace":{})", *event.workspace);
        if (!event.reason.empty()) {
            out += R"(,"reason":")";
            out += gf::gfc::jsonEscape(event.reason);
            out += '"';
        }
        out += '}';
        return out;
    }

} // namespace gf::overviewfocus
