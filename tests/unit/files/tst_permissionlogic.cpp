// Get Info's Sharing & Permissions (PermissionLogic, ADR-0028): the Finder's privileges over mode bits.
#include "permissionlogic.h"

#include <gtest/gtest.h>

using namespace PermissionLogic;

TEST(Permissions, PrivilegesOfAMode)
{
    EXPECT_EQ(accessOf(0754, Who::Owner), Access::ReadWrite);
    EXPECT_EQ(accessOf(0754, Who::Group), Access::ReadOnly);
    EXPECT_EQ(accessOf(0754, Who::Others), Access::ReadOnly);
    EXPECT_EQ(accessOf(0720, Who::Group), Access::WriteOnly);
    EXPECT_EQ(accessOf(0700, Who::Others), Access::NoAccess);
}

TEST(Permissions, ChangingAPrivilege)
{
    // A file keeps its execute bit; nothing else of the class changes.
    EXPECT_EQ(withAccess(0755, Who::Group, Access::ReadWrite, false), 0775u);
    EXPECT_EQ(withAccess(0644, Who::Others, Access::NoAccess, false), 0640u);
    EXPECT_EQ(withAccess(0750, Who::Group, Access::NoAccess, false), 0710u) << "the file's group execute bit stays";
    // A folder: Read is r-x, No Access is ---.
    EXPECT_EQ(withAccess(0700, Who::Group, Access::ReadOnly, true), 0750u);
    EXPECT_EQ(withAccess(0755, Who::Others, Access::NoAccess, true), 0750u);
    EXPECT_EQ(withAccess(0700, Who::Others, Access::WriteOnly, true), 0703u);
    // Special bits are kept, never added.
    EXPECT_EQ(withAccess(04755, Who::Others, Access::NoAccess, false), 04751u);
    EXPECT_EQ(withAccess(02775, Who::Group, Access::ReadOnly, true), 02755u);
    EXPECT_EQ(withAccess(0644, Who::Owner, Access::ReadWrite, false) & 07000u, 0u);
}

TEST(Permissions, RecursiveOperatorsKeepSpecialBits)
{
    EXPECT_EQ(recursiveOperators(Access::ReadWrite, Access::ReadOnly, Access::NoAccess), QStringLiteral("u+rwX,g+rX,g-w,o-rwx"));
    EXPECT_EQ(recursiveOperators(Access::ReadOnly, Access::WriteOnly, Access::ReadWrite), QStringLiteral("u+rX,u-w,g+wX,g-r,o+rwX"));
    EXPECT_FALSE(recursiveOperators(Access::ReadWrite, Access::ReadWrite, Access::ReadWrite).contains(QLatin1Char('='))) << "= would clear setuid";
}

TEST(Permissions, ModeText)
{
    EXPECT_EQ(modeText(0754), QStringLiteral("rwxr-xr--"));
    EXPECT_EQ(modeText(04755), QStringLiteral("rwsr-xr-x"));
    EXPECT_EQ(modeText(02640), QStringLiteral("rw-r-S---"));
    EXPECT_EQ(modeText(01777), QStringLiteral("rwxrwxrwt"));
}
