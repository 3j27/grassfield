// The Grassfield Store catalog as the Store reads it (ADR-0037 g): grassfield-catalog.v1.json, built and signed in
// grassfieldhq/grassfield-packages (tools/catalog.py applies the same rules and refuses any break). Parse only after the
// signature is verified (signature.h). Pure Qt Core: no file, no network.
//
// The whole file is refused when its top level breaks a rule (not version 1, another channel, a bad serial, more than
// 1 MiB, a list over its bound); an entry that breaks a rule is dropped with the rest kept, and so is what only
// pointed to it (an item of a dropped app, a block left empty, a section left without blocks).
#pragma once

#include <QByteArray>
#include <QList>
#include <QString>
#include <QStringList>

#include <optional>

namespace grassfield::store {

constexpr qint64 kCatalogMaxBytes = 1024 * 1024;
constexpr qint64 kIconMaxBytes = 256 * 1024;

// A text in English (required) and French (optional); v1 reads no other language.
struct LocalizedText {
    QString en;
    QString fr;
    bool isEmpty() const { return en.isEmpty(); }
    // French when asked and present, else English.
    QString pick(const QString &language) const;
};

struct CatalogIcon {
    QString sha256; // 64 lowercase hex digits: the file catalog/<sha256>.png beside the catalog
    qint64 bytes = 0;
    QString license;
    QString origin;
};

struct CatalogSource {
    enum class Kind { Repo, Aur, OmarchySetup, WebApp, Flatpak };
    Kind kind = Kind::Repo;
    QString repo;     // Repo: core, extra, multilib, omarchy
    QString package;  // Repo, Aur
    QString install;  // OmarchySetup: omarchy-install-*
    QStringList args;
    QString remove;   // OmarchySetup: omarchy-remove-*
    QStringList removeArgs;
    QStringList packages; // OmarchySetup: they say when it is installed
    LocalizedText changes;
    LocalizedText removes;
    QString url;       // WebApp
    QString flatpakId; // Flatpak (remote flathub)
};

struct CatalogApp {
    QString id;
    CatalogSource source;
    LocalizedText name, summary, description, developer;
    QString license, homepage, desktopId;
    std::optional<CatalogIcon> icon;
    QStringList categories;
};

struct CatalogItem {
    QString app;
    LocalizedText eyebrow, title, text;
};

struct CatalogBlock {
    enum class Kind { Hero, Cards, Row };
    Kind kind = Kind::Row;
    LocalizedText title;      // Row
    QList<CatalogItem> items; // Hero, Cards
    QStringList apps;         // Row
};

struct CatalogSection {
    QString id;
    LocalizedText title;
    QString symbol;
    QList<CatalogBlock> blocks;
};

struct CatalogCategory {
    QString id;
    LocalizedText title;
    QString symbol;
    QStringList freedesktop;
};

struct Catalog {
    QString channel;
    qint64 serial = 0;
    QString generated;
    QList<CatalogSection> sections;
    QList<CatalogCategory> categories;
    QList<CatalogApp> apps;
};

struct CatalogParse {
    std::optional<Catalog> catalog; // empty: refused
    QString refusal;                // why the whole file was refused
    QStringList dropped;            // "where: why" of each entry dropped
};

// expectedChannel: the channel the file was fetched for (stable or beta); another value refuses the file.
CatalogParse parseCatalog(const QByteArray &json, const QString &expectedChannel);

// The text rule (ADR-0037 g): not empty, no space at an end, at most `limit` code points, Unicode NFC, no control,
// format (bidirectional, zero-width, BOM, soft hyphen) or line/paragraph separator character (line feeds only when
// allowed), and no markup (`<`, `>`, `&entity;`). "" when the text passes.
QString plainTextProblem(const QString &text, int limit, bool lineFeeds);

// Third-party text made plain (ADR-0037 c "Display"): control and format characters removed (line feeds kept when
// allowed), runs of spaces collapsed, trimmed, NFC, and cut at `limit` code points with an ellipsis.
QString cleanPlainText(const QString &text, int limit, bool lineFeeds);

// Patterns of ADR-0037 e.5.
bool isPackageName(const QString &name);
bool isAppId(const QString &id);
bool isDesktopId(const QString &id);
bool isFlatpakId(const QString &id);
// https://, no whitespace, control or format character, at most 2048 bytes, a host name, no user information.
bool isHttpsUrl(const QString &url);
// A web app's name, which Omarchy's installer makes a file of: plain text of 1 to 64 characters, no '/', no leading '.'.
bool isWebAppName(const QString &name);

} // namespace grassfield::store
