// Prints what Files' Applications location lists, one "<id>\t<name>" line per application in the location's order, for the
// environment of this process (XDG_DATA_HOME, XDG_DATA_DIRS, XDG_CURRENT_DESKTOP, LANG). Built and compared with the Apps grid
// by tests/unit/files/apps_grid_vs_files.sh.
#include "applicationslogic.h"

#include <QCoreApplication>

#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    for (const auto &e : ApplicationsLogic::listApplications(ApplicationsLogic::processEnvironment()))
        std::printf("%s\t%s\n", qPrintable(e.id), qPrintable(e.name));
    return 0;
}
