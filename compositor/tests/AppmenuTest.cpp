#include "core/Appmenu.hpp"

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

using namespace gf::appmenu;

namespace {
    constexpr uint64_t SURFACE   = 0x1000;
    constexpr uint64_t SURFACE_2 = 0x2000;
    constexpr uint64_t OBJECT    = 0x3000;
    constexpr uint64_t OBJECT_2  = 0x4000;
    constexpr uint64_t WINDOW    = 0x55d3c2a0b1f0;
    constexpr uint64_t WINDOW_2  = 0x55d3c2a0c000;

    Registration reg(std::string service, std::string path) {
        return Registration{.service = std::move(service), .path = std::move(path)};
    }

    Announcement shows(uint64_t window, std::string service, std::string path) {
        return Announcement{.window = window, .registration = reg(std::move(service), std::move(path))};
    }

    Announcement cleared(uint64_t window) {
        return Announcement{.window = window};
    }
} // namespace

TEST(AppmenuBusName, AcceptsUniqueAndWellKnownNames) {
    for (const std::string_view name : {":1.42", ":1.0", ":42.7.9", "org.kde.Foo", "org.foo.Bar", "a.b", "org.kde.StatusNotifierItem-1234-1", "org._x.y-z",
                                        "com.canonical.AppMenu.Registrar"})
        EXPECT_TRUE(isValidBusName(name)) << name;
}

TEST(AppmenuBusName, RejectsMalformedNames) {
    for (const std::string_view name : {"", ":", ":1", ":1.", ":.1", "org", ".org.foo", "org.foo.", "org..foo", "org.1foo", "1org.foo", "org.foo bar", "org.foo/bar",
                                        "org.foo\"", "org.f\xc3\xa9", "org.foo\n", "org.foo:", "::1.2", "org.*"})
        EXPECT_FALSE(isValidBusName(name)) << name;
    EXPECT_FALSE(isValidBusName(std::string_view("org.foo\0x", 9)));
}

TEST(AppmenuBusName, LengthLimitIs255) {
    std::string name = "a." + std::string(253, 'b');
    ASSERT_EQ(name.size(), 255U);
    EXPECT_TRUE(isValidBusName(name));
    name += 'b';
    EXPECT_FALSE(isValidBusName(name));
    EXPECT_FALSE(isValidBusName(":1." + std::string(300, '2')));
}

TEST(AppmenuObjectPath, AcceptsValidPaths) {
    for (const std::string_view path : {"/", "/MenuBar/1", "/a/b", "/com/canonical/menu/1A2B", "/org/ayatana/bamf/window/_42", "/A_b_9"})
        EXPECT_TRUE(isValidObjectPath(path)) << path;
}

TEST(AppmenuObjectPath, RejectsMalformedPaths) {
    for (const std::string_view path : {"", "a/b", "MenuBar", "//", "/a//b", "/a/", "/a-b", "/a.b", "/a b", "/a/b\n", "/\xc3\xa9", "/a\"", "/a/../b"})
        EXPECT_FALSE(isValidObjectPath(path)) << path;
    EXPECT_FALSE(isValidObjectPath(std::string_view("/a\0b", 4)));
}

TEST(AppmenuObjectPath, LengthLimitIs255) {
    std::string path = "/" + std::string(254, 'p');
    ASSERT_EQ(path.size(), 255U);
    EXPECT_TRUE(isValidObjectPath(path));
    path += 'p';
    EXPECT_FALSE(isValidObjectPath(path));
}

TEST(AppmenuAddress, BothPartsMustBeValid) {
    EXPECT_TRUE(isValidAddress(":1.42", "/MenuBar/1"));
    EXPECT_FALSE(isValidAddress("", ""));
    EXPECT_FALSE(isValidAddress(":1.42", ""));
    EXPECT_FALSE(isValidAddress("", "/MenuBar/1"));
    EXPECT_FALSE(isValidAddress("/MenuBar/1", ":1.42")); // swapped
}

TEST(AppmenuRegistry, AddressBeforeMapIsAnnouncedAtMap) {
    CRegistry r;
    EXPECT_EQ(r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), 0), std::nullopt);
    EXPECT_EQ(r.query(WINDOW), cleared(WINDOW));
    EXPECT_EQ(r.windowMapped(SURFACE, WINDOW), shows(WINDOW, ":1.42", "/MenuBar/1"));
    EXPECT_EQ(r.query(WINDOW), shows(WINDOW, ":1.42", "/MenuBar/1"));
}

TEST(AppmenuRegistry, AddressOnMappedWindowIsAnnouncedOnceAndOnChange) {
    CRegistry r;
    EXPECT_EQ(r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW), shows(WINDOW, ":1.42", "/MenuBar/1"));
    EXPECT_EQ(r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW), std::nullopt); // unchanged
    EXPECT_EQ(r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/2"), WINDOW), shows(WINDOW, ":1.42", "/MenuBar/2"));
    EXPECT_EQ(r.size(), 1U);
}

TEST(AppmenuRegistry, MapWithoutRegistrationAnnouncesNothing) {
    CRegistry r;
    EXPECT_EQ(r.windowMapped(SURFACE, WINDOW), std::nullopt);
    EXPECT_EQ(r.windowGone(WINDOW), std::nullopt);
}

TEST(AppmenuRegistry, UnmapClearsAndRemapAnnouncesAgain) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    EXPECT_EQ(r.windowGone(WINDOW), cleared(WINDOW));
    EXPECT_EQ(r.windowGone(WINDOW), std::nullopt); // already cleared
    EXPECT_EQ(r.query(WINDOW), cleared(WINDOW));
    EXPECT_EQ(r.windowMapped(SURFACE, WINDOW_2), shows(WINDOW_2, ":1.42", "/MenuBar/1"));
}

TEST(AppmenuRegistry, ReleaseClearsOnlyTheLatestWritersRegistration) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    r.setAddress(SURFACE, OBJECT_2, reg(":1.42", "/MenuBar/2"), WINDOW);
    EXPECT_EQ(r.objectGone(OBJECT), std::nullopt); // superseded by OBJECT_2
    EXPECT_EQ(r.query(WINDOW), shows(WINDOW, ":1.42", "/MenuBar/2"));
    EXPECT_EQ(r.objectGone(OBJECT_2), cleared(WINDOW));
    EXPECT_EQ(r.size(), 0U);
}

TEST(AppmenuRegistry, ReleaseBeforeMapPostsNothing) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), 0);
    EXPECT_EQ(r.objectGone(OBJECT), std::nullopt);
    EXPECT_EQ(r.windowMapped(SURFACE, WINDOW), std::nullopt);
}

TEST(AppmenuRegistry, SurfaceDestroyClears) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    r.setAddress(SURFACE_2, OBJECT_2, reg(":1.43", "/MenuBar/1"), WINDOW_2);
    EXPECT_EQ(r.surfaceGone(SURFACE), cleared(WINDOW));
    EXPECT_EQ(r.surfaceGone(SURFACE), std::nullopt);
    EXPECT_EQ(r.query(WINDOW_2), shows(WINDOW_2, ":1.43", "/MenuBar/1"));
}

TEST(AppmenuRegistry, WindowsAreIndependent) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    r.setAddress(SURFACE_2, OBJECT_2, reg(":1.43", "/MenuBar/7"), WINDOW_2);
    EXPECT_EQ(r.windowGone(WINDOW), cleared(WINDOW));
    EXPECT_EQ(r.query(WINDOW_2), shows(WINDOW_2, ":1.43", "/MenuBar/7"));
}

TEST(AppmenuRegistry, QueryOfUnknownOrZeroWindowIsEmpty) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), 0); // not mapped: window 0 inside
    EXPECT_EQ(r.query(0), cleared(0));
    EXPECT_EQ(r.query(WINDOW), cleared(WINDOW));
}

TEST(AppmenuRegistry, WindowsListsLinkedWindowsOnly) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    r.setAddress(SURFACE_2, OBJECT_2, reg(":1.43", "/MenuBar/1"), 0);
    EXPECT_EQ(r.windows(), std::vector<uint64_t>{WINDOW});
    r.windowGone(WINDOW);
    EXPECT_TRUE(r.windows().empty());
}

TEST(AppmenuRegistry, ClearReturnsAnnouncedWindowsOnly) {
    CRegistry r;
    r.setAddress(SURFACE, OBJECT, reg(":1.42", "/MenuBar/1"), WINDOW);
    r.setAddress(SURFACE_2, OBJECT_2, reg(":1.43", "/MenuBar/1"), 0);
    const auto clears = r.clear();
    ASSERT_EQ(clears.size(), 1U);
    EXPECT_EQ(clears[0], cleared(WINDOW));
    EXPECT_EQ(r.size(), 0U);
}
