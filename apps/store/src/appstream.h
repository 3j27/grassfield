// Arch's AppStream (ADR-0037 c, owner ST5): the catalog XML of archlinux-appstream-data (usr/share/swcatalog/xml/*.xml.gz),
// installed, or fetched and checked by its own signature (appstreamsource.h). Read for display only: a package it names
// must exist in pacman's database, and the sheet shows the package that will be installed. Every text comes out plain
// (ADR-0037 c "Display"): the description's <p>, <ul> and <li> become paragraphs and bullets, other markup is dropped,
// control characters are removed except line feeds, and lengths are bounded. Pure: bytes in, components out.
#pragma once

#include "catalog.h"

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>

namespace grassfield::store {

struct AppStreamComponent {
    QString id;      // as AppStream spells it (some end in .desktop)
    QString pkgname;
    QString type;    // desktop-application, console-application, …
    QString origin;  // the <components origin="…"> it came from: names its icon folder
    LocalizedText name, summary, description, developer;
    QString license;  // project_license
    QStringList categories;
    QStringList keywords; // English
    QString desktopId;    // the launchable of type desktop-id
    QString cachedIcon;   // the largest cached icon: "<width>x<height>/<file>"
    QStringList screenshots; // https URLs of the source images, default first
    QString homepage;     // https only
};

// gzip (RFC 1952) to bytes; empty when it is not gzip, is damaged, or would pass maxBytes.
QByteArray gunzip(const QByteArray &gz, qint64 maxBytes);

// The components of one catalog XML. Components without an id or a pkgname are skipped (the Store shows packages).
QList<AppStreamComponent> parseAppStream(const QByteArray &xml);

} // namespace grassfield::store
