// Arch's AppStream (ADR-0037 c, owner ST5): the catalog XML of archlinux-appstream-data (usr/share/swcatalog/xml/*.xml.gz),
// installed, or fetched and checked by its own signature (appstreamsource.h). Read for display only: a package it names
// must exist in pacman's database, and the sheet shows the package that will be installed. Every text comes out plain
// (ADR-0037 c "Display"): the description's <p>, <ul> and <li> become paragraphs and bullets, other markup is dropped,
// control characters are removed except line feeds, and lengths are bounded. Pure: bytes in, components out.
#pragma once

#include "catalog.h"

#include <QByteArray>
#include <QList>
#include <QMap>
#include <QString>
#include <QStringList>

namespace grassfield::store {

// One <release> of a component, newest first as AppStream lists them (What's New, spec SR10).
struct AppStreamRelease {
    QString version;
    QString date; // yyyy-MM-dd, from `date` or `timestamp`; "" when neither parses
    LocalizedText description;
};

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
    QStringList screenshotCaptions; // the same length: each one's caption in English, "" when it has none
    QString homepage;     // https only
    QString bugtracker;   // https only
    QList<AppStreamRelease> releases; // at most 3
    QStringList languages; // the <lang> codes of <languages> (at least half translated when a percentage is given)
    // <content_rating type="oars-1.0|oars-1.1">: whether there is one, and the strongest intensity of each OARS group
    // (violence, drugs, sex, language, social, money) as 1 mild, 2 moderate, 3 intense; a group at none is left out.
    bool rated = false;
    QMap<QString, int> rating;
    // Flathub's AppStream (step 3c): the app id of its <bundle type="flatpak">app/<id>/<arch>/<branch></bundle>, the
    // runtime that bundle names ("org.gnome.Platform/x86_64/50"), and Flathub's verified-developer flag (its custom key
    // flathub::verification::verified). A component with a Flatpak bundle needs no pkgname.
    QString flatpak;
    QString runtime;
    bool verified = false;
};

// gzip (RFC 1952) to bytes; empty when it is not gzip, is damaged, or would pass maxBytes.
QByteArray gunzip(const QByteArray &gz, qint64 maxBytes);

// The components of one catalog XML. Components without an id, or without a pkgname and a Flatpak bundle, are skipped (the
// Store shows packages and Flatpaks).
QList<AppStreamComponent> parseAppStream(const QByteArray &xml);
// A Flatpak runtime as a bundle names it: <id>/<arch>/<branch>.
bool isFlatpakRuntime(const QString &runtime);

} // namespace grassfield::store
