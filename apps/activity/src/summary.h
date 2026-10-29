// The summary under the table (ADR-0038 step 2b; spec AM5, AM29, AM32 to AM35, AM39, AM42, AM44): each tab's figures and
// graphs, from the sampler's system snapshot and UPower's battery. Every graph keeps the last `capacity` samples (the
// historySamples token, set by the window), each tab's at every sample: the sampler reads every system file whatever the
// tab (2b), so a graph has its history when its tab is shown again, as on macOS. Energy Impact is the exception: its sum
// needs the Energy tab's reads, so its graph takes only the samples that computed it. A rate the sampler could not give
// (the first sample, or the one after the window was hidden, AM8) is a gap in its graph, never a zero.
#pragma once

#include "battery.h"
#include "sampler.h"

#include <QDateTime>
#include <QLocale>
#include <QObject>
#include <QVariantList>

#include <deque>

namespace activity {

// A graph's last samples, oldest first; a negative value is a gap.
class History
{
public:
    void setCapacity(size_t capacity);
    void add(double value);
    const std::deque<double> &values() const { return m_values; }
    // The largest value kept (0 when none is above 0).
    double peak() const;
    QVariantList toList() const;

private:
    std::deque<double> m_values;
    size_t m_capacity = 1;
};

class Summary : public QObject
{
    Q_OBJECT
    // The tab's blocks, left to right: {kind: "figures", rows: [{label, value, swatch}]} where `swatch` names the colour token
    // of the graph a figure draws ("" for none), or {kind: "graph", key, title, style, max, series: [{values, xs, color}],
    // levels, levelColors, modes: [{key, title}], mode}. Style "stacked" puts series[1] on series[0] (CPU Load), "mirrored"
    // draws series[0] above the middle and series[1] below it (Disk, Network), "bars" colours each bar by its level (Memory
    // Pressure), "area" fills one series (Energy Impact, Battery). `xs`, when present, places each value (0 to 1, the
    // battery's times); otherwise the newest value is at the right edge, one slot per sample of `capacity`.
    Q_PROPERTY(QVariantList blocks READ blocks NOTIFY changed)
    // AM5: the graphs keep this many samples (Tokens.activityHistorySamples, set by the window).
    Q_PROPERTY(int capacity READ capacity WRITE setCapacity NOTIFY capacityChanged)

public:
    explicit Summary(QObject *parent = nullptr);

    QVariantList blocks() const { return m_blocks; }
    int capacity() const { return static_cast<int>(m_capacity); }
    void setCapacity(int capacity);

    void setTab(Tab tab);
    void setLocale(const QLocale &locale);
    // AM42, AM44: what the Disk ("io" or "data") and Network ("packets" or "data") graphs show.
    void setDiskMode(const QString &mode);
    void setNetworkMode(const QString &mode);
    void addSample(const Snapshot &snapshot);
    // `now`: for the time on battery or on AC, and the battery graph's twelve hours (tests give their own).
    void setBattery(const BatteryState &battery, const QDateTime &now = QDateTime::currentDateTimeUtc());

    static QString durationText(qint64 seconds); // "h:mm" (AM39)

signals:
    void changed();
    void capacityChanged();

private:
    void rebuild();
    QVariantMap figure(const QString &label, const QString &value, const QString &swatch = QString()) const;
    QVariantMap figures(const QVariantList &rows) const;
    QVariantMap graph(const QString &key, const QString &title, const QString &style, double max, const QVariantList &series) const;
    QString percent(double fraction) const;

    size_t m_capacity = 1;
    Tab m_tab = Tab::Cpu;
    QLocale m_locale;
    QString m_diskMode = QStringLiteral("io"), m_networkMode = QStringLiteral("packets");
    SystemSnapshot m_system; // the last sample's
    bool m_haveSample = false;
    BatteryState m_battery;
    QDateTime m_batteryAt;
    History m_cpuSystem, m_cpuUser, m_memInUse, m_memLevel, m_energy;
    History m_diskReads, m_diskWrites, m_diskReadBytes, m_diskWriteBytes;
    History m_netPacketsIn, m_netPacketsOut, m_netBytesIn, m_netBytesOut;
    QVariantList m_blocks;
};

} // namespace activity
