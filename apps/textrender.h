// The render type of the Grassfield apps' static text (ADR-0039 Q5, design polish step 19): native by default, set once in
// each app's main before any window. GRASSFIELD_TEXT_RENDER=qt or =curve picks Qt's distance-field or curve rendering
// instead, for a side-by-side check on a real screen (the owner's 1.25-scale panel showed coarse text on rc1-16, and an
// offscreen grab rasterises every type the same, so only a real window can settle it). Any other value keeps native.
#pragma once

#include <QQuickWindow>
#include <QString>

namespace grassfield::apps {

inline QQuickWindow::TextRenderType textRenderType(const QString &value)
{
    if (value == QLatin1String("qt"))
        return QQuickWindow::QtTextRendering;
    if (value == QLatin1String("curve"))
        return QQuickWindow::CurveTextRendering;
    return QQuickWindow::NativeTextRendering;
}

inline void applyTextRenderType()
{
    QQuickWindow::setTextRenderType(textRenderType(qEnvironmentVariable("GRASSFIELD_TEXT_RENDER")));
}

} // namespace grassfield::apps
