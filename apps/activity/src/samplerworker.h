// The sampler on a thread of its own (ADR-0038 AD35): a sample costs up to 17 ms on the reference machine's CPU tab and
// more on Energy and Network (AM-P2), too long for the window's thread. One sample at a time; the window asks for the next
// one when the interval passes, and the snapshot comes back as a copy the window keeps.
#pragma once

#include "sampler.h"

#include <QList>
#include <QObject>

#include <memory>
#include <unordered_set>

namespace activity {

using SnapshotPtr = std::shared_ptr<const Snapshot>;

class SamplerWorker : public QObject
{
    Q_OBJECT

public:
    explicit SamplerWorker(Options options, QObject *parent = nullptr);
    ~SamplerWorker() override;

public slots:
    // `interval`: AM9's, for AD32's pauses. `forget`: AM8, the window comes back after a time hidden.
    void sample(unsigned reads, double interval, bool forget);
    // AM60, AM65: the pids that own a window (the shell's projection), from the next sample on.
    void setWindowOwners(const QList<int> &pids);

signals:
    void sampled(activity::SnapshotPtr snapshot, unsigned reads);

private:
    Options m_options;
    std::unordered_set<int> m_windowOwners;
    std::unique_ptr<Sampler> m_sampler; // made on the worker's thread at its first sample
};

} // namespace activity

Q_DECLARE_METATYPE(activity::SnapshotPtr)
