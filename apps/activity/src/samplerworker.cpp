#include "samplerworker.h"

namespace activity {

SamplerWorker::SamplerWorker(Options options, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
{
}

SamplerWorker::~SamplerWorker() = default;

void SamplerWorker::sample(unsigned reads, double interval, bool forget)
{
    if (!m_sampler) {
        m_sampler = std::make_unique<Sampler>(m_options);
        m_sampler->setWindowOwners(m_windowOwners);
    }
    m_sampler->setInterval(interval);
    if (forget)
        m_sampler->forgetRates();
    emit sampled(std::make_shared<const Snapshot>(m_sampler->sample(reads)), reads);
}

void SamplerWorker::setWindowOwners(const QList<int> &pids)
{
    m_windowOwners = std::unordered_set<int>(pids.cbegin(), pids.cend());
    if (m_sampler)
        m_sampler->setWindowOwners(m_windowOwners);
}

} // namespace activity
