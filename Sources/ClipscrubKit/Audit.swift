import Foundation

/// Per-type entity counts (identifier → count) — the payload `clipscrub --report` prints and the
/// CLI usage log stores. Counts only, never a raw value, so it can never become a second PHI store.
public func entityCounts(_ entities: [DetectedEntity]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for entity in entities { counts[entity.type.identifier, default: 0] += 1 }
    return counts
}
