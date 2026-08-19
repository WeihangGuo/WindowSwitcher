import Darwin

/// Per-app RAM usage, measured the way Activity Monitor groups it:
/// the app's own physical footprint plus every process it is responsible
/// for (browser/Electron helpers), attributed to the app's pid.
/// Same-user processes only — no permissions needed.
enum MemorySampler {
    /// Groups helper processes under their app. Private but long-stable;
    /// loaded via dlsym so absence degrades to main-process-only numbers.
    private static let responsiblePid: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_LAZY), "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// Physical footprint in bytes per app pid (summed over helpers).
    static func sample(appPids: Set<pid_t>) -> [pid_t: UInt64] {
        guard !appPids.isEmpty else { return [:] }
        let declaredCount = proc_listallpids(nil, 0)
        guard declaredCount > 0 else { return [:] }
        var pids = [pid_t](repeating: 0, count: Int(declaredCount) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [:] }

        var result: [pid_t: UInt64] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var owner = pid
            if !appPids.contains(pid) {
                guard let responsiblePid else { continue }
                owner = responsiblePid(pid)
                guard appPids.contains(owner) else { continue }
            }
            if let footprint = physFootprint(of: pid) {
                result[owner, default: 0] += footprint
            }
        }
        return result
    }

    private static func physFootprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard status == 0 else { return nil }
        return info.ri_phys_footprint
    }
}
