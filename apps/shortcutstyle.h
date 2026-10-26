// Menu shortcut style of the Grassfield apps (owner decision 2026-10-26, ADR-0024 C-8), shared by Files and Preview: the
// `keyboard.shortcutStyle` setting, "automatic" resolved from the device. Same rule as ui/Grassfield/Ui/MenuShortcut.js (macDevice,
// style), which the shell and Settings use; tests/unit/preview/tst_shortcutstyle.cpp runs this copy on the cases of
// tests/unit/tst_menushortcut.qml.
#pragma once

#include <QFile>
#include <QRegularExpression>
#include <QString>

namespace grassfield::apps {

// Apple hardware (the firmware's system vendor) or an Apple keyboard among the input devices (/proc/bus/input/devices: a block
// with the USB vendor 05ac, or the Bluetooth vendor 004c on bus 0005, whose handlers include "kbd").
inline bool isMacDevice(const QString &sysVendor, const QString &inputDevices)
{
    if (sysVendor.trimmed() == QLatin1String("Apple Inc."))
        return true;
    static const QRegularExpression blank(QStringLiteral("\\n\\s*\\n"));
    static const QRegularExpression usb(QStringLiteral("\\bVendor=05ac\\b"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression bluetoothBus(QStringLiteral("\\bBus=0005\\b"));
    static const QRegularExpression bluetoothVendor(QStringLiteral("\\bVendor=004c\\b"), QRegularExpression::CaseInsensitiveOption);
    static const QRegularExpression keyboard(QStringLiteral("^H: Handlers=.*\\bkbd\\b"), QRegularExpression::MultilineOption);
    for (const QString &block : inputDevices.split(blank)) {
        const bool apple = usb.match(block).hasMatch() || (bluetoothBus.match(block).hasMatch() && bluetoothVendor.match(block).hasMatch());
        if (apple && keyboard.match(block).hasMatch())
            return true;
    }
    return false;
}

// "mac" or "pc" for the stored setting and the device; anything but "mac" and "pc" reads as "automatic".
inline QString shortcutStyle(const QString &setting, bool mac)
{
    if (setting == QLatin1String("mac") || setting == QLatin1String("pc"))
        return setting;
    return mac ? QStringLiteral("mac") : QStringLiteral("pc");
}

// This machine's facts, read once at start (a keyboard attached later counts from the next start). Never a Mac in a visual
// fixture session (GRASSFIELD_VISUAL_FIXTURES), whose captures must not depend on the machine (as the shell's SystemInfo).
inline bool macDeviceHere()
{
    if (!qEnvironmentVariableIsEmpty("GRASSFIELD_VISUAL_FIXTURES"))
        return false;
    const auto read = [](const QString &path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? QString::fromUtf8(f.read(1 << 20)) : QString();
    };
    return isMacDevice(read(QStringLiteral("/sys/class/dmi/id/sys_vendor")), read(QStringLiteral("/proc/bus/input/devices")));
}

} // namespace grassfield::apps
