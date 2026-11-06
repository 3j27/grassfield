// The text side of a memo window (ADR-0051 D-4): styles applied with QTextCursor to the window's TextEdit document, plain
// text inserted for every paste and drop, and the HTML of a stored memo cleaned before it is shown (no image, no link: Qt
// Quick's rich text would load a remote image over the network).
#pragma once

#include <QObject>
#include <QString>

class QQuickTextDocument;
class QTextDocument;

namespace memos {

// Pure Qt Gui: cleaning HTML has its unit test (tests/unit/memos/tst_memostore.cpp).
QString cleanHtml(const QString &html);
// The memo's text without markup, its first non-empty line trimmed (the collapsed strip shows it).
QString firstLine(const QString &html);

class MemoFormatter : public QObject
{
    Q_OBJECT

public:
    using QObject::QObject;

    // Each takes the TextEdit's textDocument and its selection (start == end: the word at the cursor for the character
    // styles, the paragraph for the list). The TextEdit reports the change through its own signals.
    Q_INVOKABLE void toggleBold(QQuickTextDocument *doc, int start, int end);
    Q_INVOKABLE void toggleItalic(QQuickTextDocument *doc, int start, int end);
    Q_INVOKABLE void toggleUnderline(QQuickTextDocument *doc, int start, int end);
    // The text's pixel size changed by `delta`, kept in [minPx, maxPx]; `basePx` is the size of unsized text.
    Q_INVOKABLE void changeSize(QQuickTextDocument *doc, int start, int end, int delta, int basePx, int minPx, int maxPx);
    // A bulleted list on the selected paragraphs, or back to plain paragraphs when the first one is in a list.
    Q_INVOKABLE void toggleList(QQuickTextDocument *doc, int start, int end);
    // Replaces the selection with `text` as plain text in the style at the cursor; returns the cursor position after it.
    Q_INVOKABLE int insertPlain(QQuickTextDocument *doc, int start, int end, const QString &text);

    // The same on a QTextDocument (the unit tests' entry points).
    static void toggleBold(QTextDocument *doc, int start, int end);
    static void toggleItalic(QTextDocument *doc, int start, int end);
    static void toggleUnderline(QTextDocument *doc, int start, int end);
    static void changeSize(QTextDocument *doc, int start, int end, int delta, int basePx, int minPx, int maxPx);
    static void toggleList(QTextDocument *doc, int start, int end);
    static int insertPlain(QTextDocument *doc, int start, int end, const QString &text);
};

} // namespace memos
