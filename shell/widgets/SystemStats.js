.pragma library

// /proc parsers for the System widget (pure).

// First line of /proc/stat ("cpu  user nice system idle iowait irq softirq steal ...") to
// {idle, total} jiffies; null when it cannot be read.
function parseCpu(text) {
    const m = text.match(/^cpu\s+(.*)$/m);
    if (!m)
        return null;
    const f = m[1].trim().split(/\s+/).map(Number);
    if (f.length < 4 || f.some(n => !isFinite(n)))
        return null;
    // guest and guest_nice (fields 9 and 10) are already counted in user and nice.
    const used = f.slice(0, 8);
    const total = used.reduce((a, b) => a + b, 0);
    return {idle: f[3] + (f.length > 4 ? f[4] : 0), total: total};
}

// Load 0..1 between two samples.
function cpuLoad(prev, now) {
    const total = now.total - prev.total;
    if (!(total > 0))
        return 0;
    return Math.max(0, Math.min(1, 1 - (now.idle - prev.idle) / total));
}

// /proc/meminfo to {used, total} in kB (used = MemTotal - MemAvailable); null when unreadable.
function parseMemory(text) {
    const total = text.match(/^MemTotal:\s*(\d+) kB/m);
    const avail = text.match(/^MemAvailable:\s*(\d+) kB/m);
    if (!total || !avail)
        return null;
    const t = Number(total[1]);
    const a = Number(avail[1]);
    if (!(t > 0))
        return null;
    return {used: Math.max(0, t - a), total: t};
}
