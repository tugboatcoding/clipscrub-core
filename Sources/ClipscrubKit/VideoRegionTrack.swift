import CoreGraphics
import Foundation

/// PHI detected across a clip, keyed by time. Each sample holds the regions found on one frame.
///
/// A track comes in two shapes and they are read differently. A **frame-verified** track's sample
/// times are the presentation times of real frames somebody read, and only the frames it names may
/// be shown. A plain track's sample times are thresholds — apply these boxes from here on — which
/// suits a fixed set of boxes that holds for the whole clip. Handing unread frames the boxes from a
/// neighbouring frame is how text on a scrolling page slides out of its box, so the two shapes stay
/// apart and `VideoRedactor` asks which one it has.
public struct VideoRegionTrack: Sendable {
    public struct Sample: Sendable {
        public let time: Double
        public let regions: [DetectedEntity]
        public init(time: Double, regions: [DetectedEntity]) {
            self.time = time
            self.regions = regions
        }
    }

    /// Sorted by time ascending. Empty means no frame was sampled.
    public let samples: [Sample]
    /// True when each sample time is the exact presentation time of a real frame of the source.
    ///
    /// Nothing here can check that — only the code that read the frames knows — so this is a claim by
    /// whoever built the track, and `verified(samples:frameDuration:)` is how the reader makes it.
    public let verifiedFrames: Bool
    /// How long one frame of the source lasts, when known. Sets how close a presentation time has to
    /// be to count as the same frame.
    private let frameDuration: Double

    /// A track of boxes to apply from a time onward. Nothing claims these times name real frames.
    public init(samples: [Sample]) {
        self.init(samples: samples, verifiedFrames: false, frameDuration: 0)
    }

    /// A track whose samples are frames somebody read, at the times they carry in the source.
    /// `frameDuration` comes from the source's nominal frame rate and decides how much clock drift
    /// still counts as the same frame.
    public static func verified(samples: [Sample], frameDuration: Double) -> VideoRegionTrack {
        VideoRegionTrack(samples: samples, verifiedFrames: true, frameDuration: frameDuration)
    }

    private init(samples: [Sample], verifiedFrames: Bool, frameDuration: Double) {
        self.samples = samples.sorted { $0.time < $1.time }
        self.verifiedFrames = verifiedFrames
        self.frameDuration = frameDuration
    }

    /// Regions to apply at `time` — the nearest sample at or before it. Falls back to the first
    /// sample for times before it starts so the clip head is never left uncovered.
    ///
    /// Only for a plain track. A frame-verified one is read with `verifiedRegions(at:)`, which hands
    /// back the boxes found on that frame or nothing at all.
    public func regions(at time: Double) -> [DetectedEntity] {
        guard let first = samples.first else { return [] }
        if time <= first.time { return first.regions }
        var chosen = first
        for sample in samples where sample.time <= time { chosen = sample }
        return chosen.regions
    }

    /// The boxes found on the frame at `time`, or nil when no frame was read there.
    ///
    /// One lookup answers both "may this frame be shown" and "what covers it", because two lookups
    /// with different rules is how a frame gets admitted on one and handed a neighbour's boxes by the
    /// other. A time matches when it is within a fifth of a frame, which absorbs the rounding a
    /// presentation time picks up on its way through a container without reaching the next frame.
    public func verifiedRegions(at time: Double) -> [DetectedEntity]? {
        let slack = frameDuration > 0 ? frameDuration / 5 : 0.004
        return samples.first { abs($0.time - time) < slack }?.regions
    }

    /// The frame an export is showing at `time`: the last one read at or before it, since each is held
    /// until the next arrives. Nil before the first one, which an export drops. A preview reads this so
    /// it shows the same picture and the same boxes the file will.
    public func shownSample(at time: Double) -> Sample? {
        var shown: Sample?
        for sample in samples where sample.time <= time { shown = sample }
        return shown
    }

    /// Every distinct region across the whole clip. Region hits are deduped by type plus rounded rect
    /// so the same box on many frames counts once. Non-region hits are kept as-is. Drives the Details
    /// pane so it lists what is redacted anywhere in the video not just on the first frame.
    public var unionRegions: [DetectedEntity] {
        var seen = Set<String>()
        var result: [DetectedEntity] = []
        for sample in samples {
            for region in sample.regions {
                let key = dedupeKey(region)
                if seen.insert(key).inserted { result.append(region) }
            }
        }
        return result
    }

    /// Fills in a box the detector dropped for a frame or two, when the same box was read in the same
    /// place on both sides of the gap AND `confirm` says the picture under it never changed.
    ///
    /// The detector reads each frame on its own and text recognition does not return the same thing
    /// every time, so a label that never moved can go missing for one read. Its box comes off for a
    /// quarter of a second and goes back on, over and over down the clip, which makes the result
    /// impossible to review or edit.
    ///
    /// Position alone is not enough to close a gap, and this is the whole reason `confirm` exists. On a
    /// page of evenly spaced identical rows, a box sits at a spot before the gap and a DIFFERENT row
    /// has scrolled into that same spot after it — coordinates cannot tell those apart, so filling on
    /// position would drop a box onto whatever is passing through. `confirm` is asked whether the
    /// pixels under the box are the same on the gap frame as on the frames bracketing it; only then is
    /// the box the same box. Coverage is only ever added: every box the detector found on a frame is
    /// still on that frame.
    ///
    /// `window` is how long a stretch of missed reads may be bridged, measured between the two reads
    /// that bracket it. It is not this frame's distance to each of them — that reading closed the
    /// middle of a long gap and left both ends open.
    ///
    /// `confirm` receives the box and three times — the gap frame, the read before it, the read after.
    public func fillingMissedReads(
        within window: Double,
        confirm: (_ box: CGRect, _ gap: Double, _ before: Double, _ after: Double) async -> Bool
    ) async -> VideoRegionTrack {
        guard window > 0, samples.count > 2 else { return self }
        var filled: [Sample] = []
        filled.reserveCapacity(samples.count)
        var low = 0, high = 0
        for (index, sample) in samples.enumerated() {
            while low < index, samples[low].time < sample.time - window { low += 1 }
            while high + 1 < samples.count, samples[high + 1].time <= sample.time + window { high += 1 }
            // Nothing after this frame inside the window means nothing can be bracketed by it — and
            // an empty range here is `(index + 1)...index`, which traps rather than being empty.
            let later = high > index ? Array(samples[(index + 1)...high]) : []
            // Nearest read first on both sides: the closer the frames bracketing a gap, the less can
            // have happened in between, so a fill confirmed against them is the better evidenced one.
            let earlier = later.isEmpty ? [] : Array(samples[low..<index]).reversed()
            var additions: [DetectedEntity] = []
            for before in earlier {
                for candidate in before.regions {
                    guard case let .region(box) = candidate.locus else { continue }
                    // Already covered on this frame — the detector found it itself.
                    if sample.regions.contains(where: { sameBox($0, candidate) }) { continue }
                    if additions.contains(where: { sameBox($0, candidate) }) { continue }
                    // Bracketed: the same box has to come back after the gap, not just lead into it.
                    guard let after = later.first(where: { later in
                        later.regions.contains { sameBox($0, candidate) }
                    }) else { continue }
                    guard let match = after.regions.first(where: { sameBox($0, candidate) }) else { continue }
                    // One gap, one answer: the window spans the two reads bracketing it, so every
                    // frame between them fills or none does. Per frame, the ends of a run stayed open.
                    guard after.time - before.time <= window else { continue }
                    // …and the picture under it has to be the one that was read, not whatever scrolled
                    // into its place.
                    guard await confirm(box, sample.time, before.time, after.time) else { continue }
                    additions.append(union(candidate, match))
                }
            }
            filled.append(Sample(time: sample.time, regions: sample.regions + additions))
        }
        return VideoRegionTrack(samples: filled, verifiedFrames: verifiedFrames,
                                frameDuration: frameDuration)
    }

    /// Two reads of one label differ by a pixel or two, so a filled box covers both of the reads that
    /// bracket it — union, never the bigger box alone.
    private func union(_ a: DetectedEntity, _ b: DetectedEntity) -> DetectedEntity {
        guard case let .region(first) = a.locus, case let .region(second) = b.locus else { return a }
        var merged = a.confidence >= b.confidence ? a : b
        merged.locus = .region(first.union(second))
        return merged
    }

    /// The same box read twice: one type, covering mostly the same pixels. Deliberately loose on
    /// position (reads jitter) and strict on type.
    private func sameBox(_ a: DetectedEntity, _ b: DetectedEntity) -> Bool {
        guard a.type.identifier == b.type.identifier,
              case let .region(first) = a.locus, case let .region(second) = b.locus else { return false }
        let shared = first.intersection(second)
        guard !shared.isNull, shared.width > 0, shared.height > 0 else { return false }
        let smaller = min(first.width * first.height, second.width * second.height)
        guard smaller > 0 else { return false }
        return (shared.width * shared.height) / smaller >= 0.6
    }

    private func dedupeKey(_ entity: DetectedEntity) -> String {
        // Key on the stable lowercase identifier — the type's canonical id, not the display tokenPrefix.
        guard case let .region(rect) = entity.locus else { return entity.id.uuidString }
        let x = Int(rect.minX.rounded()), y = Int(rect.minY.rounded())
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())
        return "\(entity.type.identifier):\(x),\(y),\(w),\(h)"
    }

    /// The track to hand a per-frame redactor at export: every sample carries the always-applied
    /// manual boxes plus that frame's own. Sample times are left alone — they name frames of the clip
    /// being redacted, and redaction runs before any trim so those frames are still the source's.
    /// An empty track still redacts the manual boxes, via a plain one-sample track.
    public func forExport(manual: [DetectedEntity]) -> VideoRegionTrack {
        forExport { _ in manual }
    }

    /// As above, but the hand-drawn boxes are asked for per frame, because a box drawn over something
    /// that moves has to move with it. `manualAt` is given a frame time and returns the boxes for that
    /// frame.
    public func forExport(manualAt: (Double) -> [DetectedEntity]) -> VideoRegionTrack {
        guard !samples.isEmpty else {
            return VideoRegionTrack(samples: [Sample(time: 0, regions: manualAt(0))])
        }
        return VideoRegionTrack(
            samples: samples.map { Sample(time: $0.time, regions: manualAt($0.time) + $0.regions) },
            verifiedFrames: verifiedFrames,
            frameDuration: frameDuration
        )
    }
}
