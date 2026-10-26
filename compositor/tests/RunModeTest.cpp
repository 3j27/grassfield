// The run-mode rule (ADR-0019) in the plugin, against the vectors the shell (shell/lib/RunMode.js) and the apps are held
// to: tests/fixtures/run-mode-vectors.json, read here with the plugin's own strict JSON reader (no Qt in the plugin).
// A Grassfield session with a leaked GRASSFIELD_DEV=1 is no dev run, so the dev fault injection stays closed there.

#include "core/Json.hpp"
#include "core/Minimize.hpp"
#include "core/RunMode.hpp"

#include <gtest/gtest.h>

#include <fstream>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

#ifndef GF_RUN_MODE_VECTORS
#error "GF_RUN_MODE_VECTORS: the path of tests/fixtures/run-mode-vectors.json (set by CMakeLists.txt / build-direct.sh)"
#endif

namespace {

    struct ModeVector {
        std::string                        name;
        std::map<std::string, std::string> env; // a missing key is an unset variable
        bool                               dev        = false;
        bool                               session    = false;
        bool                               hasDev     = false; // the vector states "dev"
        bool                               hasSession = false; // the vector states "session"
    };

    std::optional<std::map<std::string, std::string>> readEnv(gf::json::CReader& r) {
        std::map<std::string, std::string> env;
        if (!r.take('{'))
            return std::nullopt;
        if (r.take('}'))
            return env;
        do {
            const auto key = r.string();
            if (!key || !r.take(':'))
                return std::nullopt;
            const auto value = r.string();
            if (!value)
                return std::nullopt;
            env[*key] = *value;
        } while (r.take(','));
        return r.take('}') ? std::optional{env} : std::nullopt;
    }

    std::optional<ModeVector> readMode(gf::json::CReader& r) {
        ModeVector m;
        if (!r.take('{'))
            return std::nullopt;
        do {
            const auto key = r.string();
            if (!key || !r.take(':'))
                return std::nullopt;
            if (*key == "name") {
                const auto name = r.string();
                if (!name)
                    return std::nullopt;
                m.name = *name;
            } else if (*key == "env") {
                auto env = readEnv(r);
                if (!env)
                    return std::nullopt;
                m.env = std::move(*env);
            } else if (*key == "dev" || *key == "session") {
                const std::optional<bool> b = r.boolean();
                if (!b.has_value())
                    return std::nullopt;
                if (*key == "dev") {
                    m.dev    = b.value();
                    m.hasDev = true;
                } else {
                    m.session    = b.value();
                    m.hasSession = true;
                }
            } else if (!r.skipValue()) {
                return std::nullopt;
            }
        } while (r.take(','));
        return r.take('}') ? std::optional{m} : std::nullopt;
    }

    // The "modes" array of the vectors file; nothing when the file cannot be read as expected.
    std::optional<std::vector<ModeVector>> loadModes() {
        std::ifstream in(GF_RUN_MODE_VECTORS);
        if (!in)
            return std::nullopt;
        std::stringstream text;
        text << in.rdbuf();
        const std::string json = text.str();
        gf::json::CReader r(json, 4096, 16);
        std::vector<ModeVector> modes;
        bool                    found = false;
        if (!r.take('{'))
            return std::nullopt;
        do {
            const auto key = r.string();
            if (!key || !r.take(':'))
                return std::nullopt;
            if (*key != "modes") {
                if (!r.skipValue())
                    return std::nullopt;
                continue;
            }
            found = true;
            if (!r.take('['))
                return std::nullopt;
            if (!r.take(']')) {
                do {
                    auto m = readMode(r);
                    if (!m)
                        return std::nullopt;
                    modes.push_back(std::move(*m));
                } while (r.take(','));
                if (!r.take(']'))
                    return std::nullopt;
            }
        } while (r.take(','));
        if (!r.take('}') || !r.atEnd() || !found)
            return std::nullopt;
        return modes;
    }

    const char* value(const ModeVector& m, const std::string& variable) {
        const auto it = m.env.find(variable);
        return it == m.env.end() ? nullptr : it->second.c_str();
    }

} // namespace

TEST(RunMode, TheSharedVectorsHold) {
    const std::vector<ModeVector> modes = loadModes().value_or(std::vector<ModeVector>{});
    ASSERT_GE(modes.size(), 10U) << "cannot read the modes of " << GF_RUN_MODE_VECTORS << ", or they look truncated";
    for (const auto& m : modes) {
        ASSERT_TRUE(m.hasDev && m.hasSession) << m.name << ": no dev or session expectation";
        const char* dev     = value(m, "GRASSFIELD_DEV");
        const char* session = value(m, "GRASSFIELD_SESSION");
        EXPECT_EQ(gf::runmode::dev(dev, session), m.dev) << m.name;
        EXPECT_EQ(gf::runmode::session(session), m.session) << m.name;
        // The dev fault injection follows the rule exactly (the plugin's only dev hook).
        EXPECT_EQ(gf::minimize::isFunnelShaderFault(gf::minimize::kConfigTestFault, gf::minimize::kTestFaultFunnelShader, gf::runmode::dev(dev, session)), m.dev)
            << m.name << ": testFault";
    }
}

TEST(RunMode, ALeakedDevInAGrassfieldSessionOpensNoDevHook) {
    EXPECT_FALSE(gf::runmode::dev("1", "1")) << "GRASSFIELD_DEV=1 leaked into the session";
    EXPECT_TRUE(gf::runmode::session("1"));
    EXPECT_FALSE(gf::minimize::isFunnelShaderFault(gf::minimize::kConfigTestFault, gf::minimize::kTestFaultFunnelShader, gf::runmode::dev("1", "1")));
    EXPECT_TRUE(gf::runmode::dev("1", nullptr)) << "the nested development session (GRASSFIELD_SESSION unset)";
    EXPECT_TRUE(gf::runmode::dev("1", "")) << "an empty value is not \"1\"";
    EXPECT_FALSE(gf::runmode::dev(nullptr, nullptr));
    EXPECT_FALSE(gf::runmode::dev("true", nullptr)) << "only the exact string \"1\"";
    EXPECT_FALSE(gf::runmode::session(nullptr));
}
