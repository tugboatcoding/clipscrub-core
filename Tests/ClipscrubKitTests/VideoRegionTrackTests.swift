import XCTest
@testable import ClipscrubKit

// Synthetic regions only — no real PHI.
final class VideoRegionTrackTests: XCTestCase {
    private func region(_ x: CGFloat, type: EntityType = .name) -> DetectedEntity {
        DetectedEntity(type: type, value: "x", confidence: 0.9, source: .vision,
                       locus: .region(CGRect(x: x, y: 0, width: 10, height: 10)))
    }

    func testEmptyTrackReturnsNothing() {
        let track = VideoRegionTrack(samples: [])
        XCTAssertTrue(track.regions(at: 5).isEmpty)
        XCTAssertTrue(track.unionRegions.isEmpty)
    }

    func testNearestSampleAtOrBeforeTime() {
        let track = VideoRegionTrack(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 1, regions: [region(1)]),
            .init(time: 2, regions: [region(2)]),
        ])
        // Before the first sample falls back to the head so the clip start stays covered.
        XCTAssertEqual(rectX(track.regions(at: -1)), [0])
        XCTAssertEqual(rectX(track.regions(at: 0.4)), [0])
        XCTAssertEqual(rectX(track.regions(at: 1)), [1])
        XCTAssertEqual(rectX(track.regions(at: 1.9)), [1])
        XCTAssertEqual(rectX(track.regions(at: 99)), [2])
    }

    func testUnionDedupesByTypeAndRect() {
        let track = VideoRegionTrack(samples: [
            .init(time: 0, regions: [region(0), region(5)]),
            .init(time: 1, regions: [region(0)]), // same rect + type as frame-0 → deduped
            .init(time: 2, regions: [region(0, type: .email)]), // same rect, other type → kept
        ])
        XCTAssertEqual(track.unionRegions.count, 3)
    }

    func testSamplesSortOnInit() {
        let track = VideoRegionTrack(samples: [
            .init(time: 2, regions: [region(2)]),
            .init(time: 0, regions: [region(0)]),
        ])
        XCTAssertEqual(track.samples.map(\.time), [0, 2])
    }

    // Redaction runs before any trim, so sample times keep naming frames of the clip being redacted.
    // Shifting them would point every box at a frame that is not the one it was found on.
    func testForExportKeepsTimesAndUnionsManual() {
        let manual = region(100)
        let track = VideoRegionTrack(samples: [
            .init(time: 5, regions: [region(5)]),
            .init(time: 7, regions: [region(7)]),
        ]).forExport(manual: [manual])
        XCTAssertEqual(track.samples.map(\.time), [5, 7])
        XCTAssertEqual(rectX(track.regions(at: 5)).sorted(), [5, 100]) // manual rides every sample
        XCTAssertEqual(rectX(track.regions(at: 7)).sorted(), [7, 100])
    }

    func testForExportEmptyTrackFallsBackToManualOnly() {
        let track = VideoRegionTrack(samples: []).forExport(manual: [region(3)])
        XCTAssertEqual(rectX(track.regions(at: 99)), [3])
    }

    func testNegativeTimeSamplesResolveAcrossZero() {
        let track = VideoRegionTrack(samples: [
            .init(time: -2, regions: [region(0)]),
            .init(time: -1, regions: [region(1)]),
            .init(time: 0.5, regions: [region(2)]),
        ])
        XCTAssertEqual(rectX(track.regions(at: -3)), [0]) // before head → head
        XCTAssertEqual(rectX(track.regions(at: 0)), [1])  // nearest at or before 0 is -1
        XCTAssertEqual(rectX(track.regions(at: 0.5)), [2])
    }

    func testUnionKeepsDistinctTypesAtSameRect() {
        // Different types at the same rect are distinct hits and must not merge.
        let track = VideoRegionTrack(samples: [
            .init(time: 0, regions: [region(0, type: .ssn), region(0, type: .email)]),
        ])
        XCTAssertEqual(track.unionRegions.count, 2)
    }

    // This one lookup decides both whether a frame may be shown and what covers it. A wrong answer
    // either shows a frame nobody read or hands a frame its neighbour's boxes.
    func testVerifiedRegionsMatchOnlyTheirOwnFrame() {
        let track = VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: [region(1)]),
        ], frameDuration: 1 / 30.0)
        XCTAssertEqual(rectX(track.verifiedRegions(at: 0) ?? []), [0])
        XCTAssertEqual(rectX(track.verifiedRegions(at: 0.2501) ?? []), [1]) // container rounding
        // Either neighbour at 30 fps must miss, and must NOT come back holding sample 0.25's boxes.
        XCTAssertNil(track.verifiedRegions(at: 0.25 - 1 / 30.0))
        XCTAssertNil(track.verifiedRegions(at: 0.25 + 1 / 30.0))
        XCTAssertNil(track.verifiedRegions(at: 0.125))
    }

    // A 120 fps source puts frames 0.0083 apart, so the slack has to shrink with the frame rate or a
    // frame nobody read starts matching its neighbour's sample.
    func testToleranceFollowsTheSourceFrameRate() {
        let fast = VideoRegionTrack.verified(samples: [.init(time: 0.25, regions: [region(1)])],
                                             frameDuration: 1 / 120.0)
        XCTAssertNil(fast.verifiedRegions(at: 0.25 + 1 / 120.0))
        XCTAssertNotNil(fast.verifiedRegions(at: 0.2501))
    }

    func testForExportKeepsTheVerifiedFlag() {
        let verified = VideoRegionTrack.verified(samples: [.init(time: 0, regions: [region(0)])],
                                                 frameDuration: 1 / 30.0)
        XCTAssertTrue(verified.forExport(manual: []).verifiedFrames)
        XCTAssertFalse(VideoRegionTrack(samples: [.init(time: 0, regions: [region(0)])])
            .forExport(manual: []).verifiedFrames)
        // An empty scan falls back to manual boxes only, which no frame verified — so every frame is
        // redacted with them rather than the clip being cut down to nothing.
        XCTAssertFalse(VideoRegionTrack.verified(samples: [], frameDuration: 1 / 30.0)
            .forExport(manual: [region(3)]).verifiedFrames)
    }

    // The reason this exists: one missed read on a label that never moved took its box away for a
    // quarter second and gave it back, which is unreviewable.
    func testGapBetweenTwoReadsOfTheSameBoxIsFilled() async {
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: []), // detector missed it on this frame
            .init(time: 0.5, regions: [region(0)]),
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        XCTAssertEqual(rectX(track.samples[1].regions), [0])
    }

    // The scrolling case, and the reason both sides are required: content that leaves the frame has
    // reads before the gap and none after. Carrying that box forward would park it over a place the
    // content has left while the content itself moves on uncovered.
    func testABoxWithNothingAfterItIsNotCarriedForward() async {
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: [region(40)]), // same label, scrolled on
            .init(time: 0.5, regions: [region(80)]),
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        XCTAssertEqual(rectX(track.samples[1].regions), [40])
        XCTAssertEqual(rectX(track.samples[2].regions), [80])
    }

    func testGapWiderThanTheWindowStaysOpen() async {
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 2, regions: []), // both neighbours are outside a 1s window
            .init(time: 4, regions: [region(0)]),
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        XCTAssertTrue(track.samples[1].regions.isEmpty)
    }

    // Two reads of one label differ by a pixel or two, so the box filled into the gap has to cover
    // both of them — union, not whichever read got there first.
    func testFilledBoxCoversBothReadsThatBracketIt() async {
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: []),
            .init(time: 0.5, regions: [region(1)]), // same label, read one pixel over
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        guard case let .region(rect) = track.samples[1].regions[0].locus else { return XCTFail("no rect") }
        XCTAssertEqual(rect.minX, 0)
        XCTAssertEqual(rect.maxX, 11)
    }

    func testFillingNeverTakesCoverageAway() async {
        // Every box the detector found on a frame is still on that frame afterwards.
        let samples: [VideoRegionTrack.Sample] = [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: [region(50)]),
            .init(time: 0.5, regions: [region(0), region(50)]),
        ]
        let filled = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        for (index, sample) in samples.enumerated() {
            let covered = rectX(filled.samples[index].regions)
            for x in rectX(sample.regions) { XCTAssertTrue(covered.contains(x), "frame \(index) lost \(x)") }
        }
    }

    // An empty "after" window is a range whose end is before its start, which traps rather than
    // reading as empty. A last frame, or a gap with nothing on the far side, hits it.
    func testNothingAfterTheFrameIsNotACrash() async {
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: [region(0)]),
            .init(time: 9, regions: []), // far outside the window of the two before it
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        XCTAssertTrue(track.samples[2].regions.isEmpty)
    }

    // The identical-rows scroll: the box sits in the same place before and after the gap, but a
    // DIFFERENT row has moved into it. Coordinates cannot tell that apart — the pixels can, and a
    // refusal from `confirm` has to leave the frame alone.
    func testUnconfirmedPixelsLeaveTheGapOpen() async {
        let samples: [VideoRegionTrack.Sample] = [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: []),
            .init(time: 0.5, regions: [region(0)]),
        ]
        let refused = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 1, confirm: { _, _, _, _ in false })
        XCTAssertTrue(refused.samples[1].regions.isEmpty)
    }

    func testConfirmIsAskedAboutTheGapAndBothNeighbours() async {
        actor Asked { var times: [[Double]] = []; func note(_ t: [Double]) { times.append(t) } }
        let asked = Asked()
        _ = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: []),
            .init(time: 0.5, regions: [region(0)]),
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1) { _, gap, before, after in
            await asked.note([gap, before, after])
            return true
        }
        let times = await asked.times
        XCTAssertEqual(times, [[0.25, 0, 0.5]])
    }

    func testFillingKeepsTypesApart() async {
        // A name gap is not closed by an email box sitting in the same place.
        let track = await VideoRegionTrack.verified(samples: [
            .init(time: 0, regions: [region(0)]),
            .init(time: 0.25, regions: []),
            .init(time: 0.5, regions: [region(0, type: .email)]),
        ], frameDuration: 1 / 30.0).fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        XCTAssertTrue(track.samples[1].regions.isEmpty)
    }

    // A run of five missed reads bracketed 1.5s apart, judged against a 1s window. The old rule
    // measured this frame's distance to each neighbour, so the three frames in the middle sat inside
    // 1s of both and filled while the two at the ends did not — box on, off, on, off, on, which is
    // the reported failure. Too far apart to bridge now means the whole run stays open.
    func testALongRunFillsWholeOrNotAtAll() async {
        var samples: [VideoRegionTrack.Sample] = [.init(time: 0, regions: [region(0)])]
        for index in 1...5 { samples.append(.init(time: Double(index) * 0.25, regions: [])) }
        samples.append(.init(time: 1.5, regions: [region(0)]))
        let track = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 1, confirm: { _, _, _, _ in true })
        for index in 1...5 {
            XCTAssertTrue(track.samples[index].regions.isEmpty,
                          "frame \(index) filled while the ends of its own run stayed open")
        }
    }

    // The same run at the window the app ships (`VideoRegionSampler.defaultGapWindowSeconds`), which
    // is what keeps the rule above from costing coverage: a bracket this close bridges every frame.
    func testARunInsideTheWindowFillsCompletely() async {
        var samples: [VideoRegionTrack.Sample] = [.init(time: 0, regions: [region(0)])]
        for index in 1...5 { samples.append(.init(time: Double(index) * 0.25, regions: [])) }
        samples.append(.init(time: 1.5, regions: [region(0)]))
        let track = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 2, confirm: { _, _, _, _ in true })
        for index in 1...5 {
            XCTAssertEqual(rectX(track.samples[index].regions), [0],
                           "frame \(index) of the run came back uncovered")
        }
    }

    // The other half of one gap, one answer: too long to bridge means NOTHING fills, not the middle
    // of it. A run that fills at both ends of itself and not in the middle is the same blink.
    func testARunTooLongToBridgeIsLeftEntirelyOpen() async {
        var samples: [VideoRegionTrack.Sample] = [.init(time: 0, regions: [region(0)])]
        for index in 1...9 { samples.append(.init(time: Double(index) * 0.25, regions: [])) }
        samples.append(.init(time: 2.5, regions: [region(0)]))
        let track = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 2, confirm: { _, _, _, _ in true })
        for index in 1...9 {
            XCTAssertTrue(track.samples[index].regions.isEmpty,
                          "frame \(index) was filled from a bracket too far apart to trust")
        }
    }

    // Every frame of a run is its own question to `confirm`. Filling the interior on the strength of
    // the edges would put a box on a frame whose pixels nobody looked at.
    func testConfirmIsAskedForEveryFrameOfTheRun() async {
        actor Asked { var times: [[Double]] = []; func note(_ t: [Double]) { times.append(t) } }
        let asked = Asked()
        var samples: [VideoRegionTrack.Sample] = [.init(time: 0, regions: [region(0)])]
        for index in 1...3 { samples.append(.init(time: Double(index) * 0.25, regions: [])) }
        samples.append(.init(time: 1, regions: [region(0)]))
        _ = await VideoRegionTrack.verified(samples: samples, frameDuration: 1 / 30.0)
            .fillingMissedReads(within: 2) { _, gap, before, after in
                await asked.note([gap, before, after])
                return true
            }
        let times = await asked.times
        XCTAssertEqual(times, [[0.25, 0, 1], [0.5, 0, 1], [0.75, 0, 1]])
    }

    private func rectX(_ entities: [DetectedEntity]) -> [CGFloat] {
        entities.compactMap { if case let .region(r) = $0.locus { return r.minX } else { return nil } }
    }
}
