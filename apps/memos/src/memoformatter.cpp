#include "memoformatter.h"

#include <QQuickTextDocument>
#include <QTextBlock>
#include <QTextCursor>
#include <QTextDocument>
#include <QTextDocumentFragment>
#include <QTextFrame>
#include <QTextList>
#include <QTextTable>

#include <functional>

namespace memos {

namespace {

// A cursor over [start, end], or over the word at `start` when the range is empty.
QTextCursor selectionCursor(QTextDocument *doc, int start, int end)
{
    QTextCursor c(doc);
    const int last = qMax(0, doc->characterCount() - 1);
    start = qBound(0, start, last);
    end = qBound(0, end, last);
    if (start > end)
        std::swap(start, end);
    c.setPosition(start);
    if (start == end)
        c.select(QTextCursor::WordUnderCursor);
    else
        c.setPosition(end, QTextCursor::KeepAnchor);
    return c;
}

// Whether every character of the selection has the property (`test` of its format).
bool allHave(const QTextCursor &c, const std::function<bool(const QTextCharFormat &)> &test)
{
    if (!c.hasSelection())
        return false;
    QTextCursor probe(c.document());
    for (int pos = c.selectionStart(); pos < c.selectionEnd(); ++pos) {
        probe.setPosition(pos + 1); // the format of the character before the position
        if (!test(probe.charFormat()))
            return false;
    }
    return true;
}

void toggle(QTextDocument *doc, int start, int end, const std::function<bool(const QTextCharFormat &)> &has,
            const std::function<void(QTextCharFormat &, bool)> &set)
{
    if (!doc)
        return;
    QTextCursor c = selectionCursor(doc, start, end);
    if (!c.hasSelection())
        return;
    const bool on = !allHave(c, has);
    QTextCharFormat f;
    set(f, on);
    c.mergeCharFormat(f);
}

// A format without a background image (the HTML `background` attribute and CSS `background-image` become one; Qt Quick
// would load it, a remote one over the network). Returns whether it held one.
bool dropBackgroundImage(QTextFormat &f)
{
    bool had = false;
    if (f.hasProperty(QTextFormat::BackgroundImageUrl)) {
        f.clearProperty(QTextFormat::BackgroundImageUrl);
        had = true;
    }
    if (f.hasProperty(QTextFormat::BackgroundBrush) && f.background().style() == Qt::TexturePattern) {
        f.clearBackground();
        had = true;
    }
    return had;
}

void clearFrameBackgrounds(QTextFrame *frame)
{
    QTextFrameFormat ff = frame->frameFormat();
    if (dropBackgroundImage(ff))
        frame->setFrameFormat(ff);
    if (auto *table = qobject_cast<QTextTable *>(frame)) {
        for (int r = 0; r < table->rows(); ++r) {
            for (int c = 0; c < table->columns(); ++c) {
                QTextTableCell cell = table->cellAt(r, c);
                QTextCharFormat cf = cell.format();
                if (dropBackgroundImage(cf))
                    cell.setFormat(cf);
            }
        }
    }
    const QList<QTextFrame *> children = frame->childFrames();
    for (QTextFrame *child : children)
        clearFrameBackgrounds(child);
}

// Every frame (the body's is the root frame), table, cell, paragraph and run of `doc` loses its background image.
void clearBackgroundImages(QTextDocument *doc)
{
    clearFrameBackgrounds(doc->rootFrame());
    for (QTextBlock block = doc->begin(); block.isValid(); block = block.next()) {
        QTextBlockFormat bf = block.blockFormat();
        if (dropBackgroundImage(bf))
            QTextCursor(block).setBlockFormat(bf);
        struct Run { int position; int length; QTextCharFormat format; };
        QList<Run> runs;
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            QTextCharFormat cf = it.fragment().charFormat();
            if (dropBackgroundImage(cf))
                runs.append({it.fragment().position(), it.fragment().length(), cf});
        }
        for (const Run &run : std::as_const(runs)) {
            QTextCursor c(doc);
            c.setPosition(run.position);
            c.setPosition(run.position + run.length, QTextCursor::KeepAnchor);
            c.setCharFormat(run.format);
        }
    }
}

} // namespace

QString cleanHtml(const QString &html)
{
    QTextDocument doc;
    doc.setHtml(html);
    // Images out (a remote or local resource the view would load), links made plain text. The ranges are collected first and
    // changed from the last one back, so no change moves a range still to come.
    QList<QPair<int, int>> images;
    struct Link { int position; int length; QTextCharFormat format; };
    QList<Link> links;
    for (QTextBlock block = doc.begin(); block.isValid(); block = block.next()) {
        for (auto it = block.begin(); !it.atEnd(); ++it) {
            const QTextFragment fragment = it.fragment();
            if (!fragment.isValid())
                continue;
            const QTextCharFormat f = fragment.charFormat();
            if (f.isImageFormat())
                images.append({fragment.position(), fragment.length()});
            else if (f.isAnchor() || !f.anchorHref().isEmpty() || !f.anchorNames().isEmpty())
                links.append({fragment.position(), fragment.length(), f});
        }
    }
    for (const Link &link : std::as_const(links)) {
        QTextCursor c(&doc);
        c.setPosition(link.position);
        c.setPosition(link.position + link.length, QTextCursor::KeepAnchor);
        QTextCharFormat f = link.format;
        f.setAnchor(false);
        f.setAnchorHref(QString());
        f.setAnchorNames({});
        c.setCharFormat(f);
    }
    for (auto it = images.crbegin(); it != images.crend(); ++it) {
        QTextCursor c(&doc);
        c.setPosition(it->first);
        c.setPosition(it->first + it->second, QTextCursor::KeepAnchor);
        c.removeSelectedText();
    }
    clearBackgroundImages(&doc);
    return doc.toHtml();
}

QString firstLine(const QString &html)
{
    QTextDocument doc;
    doc.setHtml(html);
    const QStringList lines = doc.toPlainText().split(QLatin1Char('\n'));
    for (const QString &line : lines) {
        const QString t = line.trimmed();
        if (!t.isEmpty())
            return t;
    }
    return {};
}

void MemoFormatter::toggleBold(QTextDocument *doc, int start, int end)
{
    toggle(doc, start, end, [](const QTextCharFormat &f) { return f.fontWeight() >= QFont::Bold; },
           [](QTextCharFormat &f, bool on) { f.setFontWeight(on ? QFont::Bold : QFont::Normal); });
}

void MemoFormatter::toggleItalic(QTextDocument *doc, int start, int end)
{
    toggle(doc, start, end, [](const QTextCharFormat &f) { return f.fontItalic(); }, [](QTextCharFormat &f, bool on) { f.setFontItalic(on); });
}

void MemoFormatter::toggleUnderline(QTextDocument *doc, int start, int end)
{
    toggle(doc, start, end, [](const QTextCharFormat &f) { return f.fontUnderline(); }, [](QTextCharFormat &f, bool on) { f.setFontUnderline(on); });
}

void MemoFormatter::changeSize(QTextDocument *doc, int start, int end, int delta, int basePx, int minPx, int maxPx)
{
    if (!doc)
        return;
    QTextCursor c = selectionCursor(doc, start, end);
    if (!c.hasSelection())
        return;
    // Each run keeps its own size relative to the others (Bigger on a mixed selection makes every run bigger).
    QTextCursor probe(doc);
    int pos = c.selectionStart();
    const int stop = c.selectionEnd();
    while (pos < stop) {
        probe.setPosition(pos + 1);
        const QTextCharFormat current = probe.charFormat();
        const int px = current.hasProperty(QTextFormat::FontPixelSize) ? current.intProperty(QTextFormat::FontPixelSize) : basePx;
        int runEnd = pos + 1;
        while (runEnd < stop) {
            probe.setPosition(runEnd + 1);
            const QTextCharFormat next = probe.charFormat();
            const int nextPx = next.hasProperty(QTextFormat::FontPixelSize) ? next.intProperty(QTextFormat::FontPixelSize) : basePx;
            if (nextPx != px)
                break;
            ++runEnd;
        }
        QTextCursor run(doc);
        run.setPosition(pos);
        run.setPosition(runEnd, QTextCursor::KeepAnchor);
        QTextCharFormat f;
        f.setProperty(QTextFormat::FontPixelSize, qBound(minPx, px + delta, maxPx));
        run.mergeCharFormat(f);
        pos = runEnd;
    }
}

void MemoFormatter::toggleList(QTextDocument *doc, int start, int end)
{
    if (!doc)
        return;
    QTextCursor c(doc);
    const int last = qMax(0, doc->characterCount() - 1);
    c.setPosition(qBound(0, qMin(start, end), last));
    c.setPosition(qBound(0, qMax(start, end), last), QTextCursor::KeepAnchor);
    QTextBlock first = doc->findBlock(c.selectionStart());
    const QTextBlock lastBlock = doc->findBlock(c.selectionEnd());
    c.beginEditBlock();
    if (first.textList()) {
        for (QTextBlock b = first; b.isValid(); b = b.next()) {
            if (QTextList *list = b.textList()) {
                list->remove(b);
                QTextBlockFormat bf = b.blockFormat();
                bf.setIndent(0);
                QTextCursor bc(b);
                bc.setBlockFormat(bf);
            }
            if (b == lastBlock)
                break;
        }
    } else {
        QTextListFormat lf;
        lf.setStyle(QTextListFormat::ListDisc);
        c.createList(lf);
    }
    c.endEditBlock();
}

int MemoFormatter::insertPlain(QTextDocument *doc, int start, int end, const QString &text)
{
    if (!doc)
        return 0;
    QTextCursor c(doc);
    const int last = qMax(0, doc->characterCount() - 1);
    c.setPosition(qBound(0, qMin(start, end), last));
    c.setPosition(qBound(0, qMax(start, end), last), QTextCursor::KeepAnchor);
    // Line ends as the document's paragraphs; any control character but tab and newline dropped.
    QString clean;
    clean.reserve(text.size());
    const QString unified = QString(text).replace(QStringLiteral("\r\n"), QStringLiteral("\n")).replace(QLatin1Char('\r'), QLatin1Char('\n'));
    for (const QChar ch : unified) {
        if (ch == QLatin1Char('\n') || ch == QLatin1Char('\t') || ch.unicode() >= 0x20)
            clean.append(ch == QChar(0x7f) ? QChar() : ch);
    }
    clean.remove(QChar());
    c.insertText(clean);
    return c.position();
}

void MemoFormatter::toggleBold(QQuickTextDocument *doc, int start, int end)
{
    toggleBold(doc ? doc->textDocument() : nullptr, start, end);
}

void MemoFormatter::toggleItalic(QQuickTextDocument *doc, int start, int end)
{
    toggleItalic(doc ? doc->textDocument() : nullptr, start, end);
}

void MemoFormatter::toggleUnderline(QQuickTextDocument *doc, int start, int end)
{
    toggleUnderline(doc ? doc->textDocument() : nullptr, start, end);
}

void MemoFormatter::changeSize(QQuickTextDocument *doc, int start, int end, int delta, int basePx, int minPx, int maxPx)
{
    changeSize(doc ? doc->textDocument() : nullptr, start, end, delta, basePx, minPx, maxPx);
}

void MemoFormatter::toggleList(QQuickTextDocument *doc, int start, int end)
{
    toggleList(doc ? doc->textDocument() : nullptr, start, end);
}

int MemoFormatter::insertPlain(QQuickTextDocument *doc, int start, int end, const QString &text)
{
    return insertPlain(doc ? doc->textDocument() : nullptr, start, end, text);
}

} // namespace memos
