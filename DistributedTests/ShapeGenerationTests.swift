import Foundation
import Testing
@testable import PuzzleSolver

/// This fixture is only for acceptance checks. Search/benchmark code never reads it.
enum FullPuzzleFixture {
    static let rows = [
        "AAAABCDDDDD", "BBBBBCCCEEE", "BFFFFCGCEHE", "IFFFFCCCEHE",
        "IIFFFFJCKHH", "IFFFFFJJKHL",
        "IIIMFFFJJHH", "NNIMOFFFFFH", "NIIOOFFFFHH",
        "NNINOPFFFFH", "NNNNPPFFFFH"
    ]
    static var labels: [Int] { rows.flatMap { $0.utf8.map { Int($0 - 65) } } }
}

struct ShapeGenerationTests {
    private func config(rows: Int, cols: Int, clues: [Int]) -> RunConfig {
        var c = RunConfig.example
        c.rowNum = rows; c.colNum = cols
        c.Target = OriginalCondition(Status: (0..<rows).map { Array(clues[$0*cols..<($0+1)*cols]) })
        c.pathEvaluation = .cpu; c.consoleLogging = false
        return c
    }

    @Test func fullPuzzleAcceptanceFixture() {
        let context = SearchContext(config: RunConfig.fullPuzzle)
        let labels = FullPuzzleFixture.labels
        #expect(labels.count == 121)
        let state = context.evaluate(labels: labels)
        let report = ExactValidator().validate(state.board, target: context.config.Target)
        #expect(state.validation.valid && report.valid)
        #expect(report.answer?.sumOfSquares == 408951)
        #expect(report.answer?.rowSums == [58,86,202,215,211,221,180,234,212,208,206])
        #expect(Set(report.capitols) == Set([
            GridCell(row: 1, col: 2), GridCell(row: 1, col: 9), GridCell(row: 2, col: 6),
            GridCell(row: 5, col: 7), GridCell(row: 5, col: 10), GridCell(row: 6, col: 1),
            GridCell(row: 6, col: 5), GridCell(row: 10, col: 5)
        ]))
        #expect(context.groups(labels).allSatisfy { context.permits($0) })
        for part in context.groups(labels) {
            guard let cap = context.regions.geometry(part).capitol else { continue }
            let rs = part.map { $0 / 11 }, cs = part.map { $0 % 11 }
            for transform in 0..<7 {
                let mapped = part.compactMap { RegionCache.map($0, transform: transform,
                    top: rs.min()!, bottom: rs.max()!, left: cs.min()!, right: cs.max()!, cols: 11) }
                guard mapped.count == part.count && Set(mapped) == Set(part) else { continue }
                let space = context.capitolOrbitSpace(cap: cap, transform: transform, patch: Set(0..<121))
                #expect(part.allSatisfy { space[$0] != nil })
            }
        }
    }

    @Test func shortPathsAndForcedSingletonPropagate() {
        let context = SearchContext(config: RunConfig.fullPuzzle)
        let c = context.constraints
        #expect(c.forcedSingletons.contains(5*11+10))
        #expect(c.distanceUpperBounds[6*11+10] == 1)
        #expect(c.minimumSizes[6*11+10] >= 12 && c.minimumSizes[7*11+10] >= 12)
        #expect(c.minimumSizes[2*11+3] >= 22 && c.minimumSizes[3*11+2] >= 22)
        #expect(c.minimumSizes[7*11+8] >= 18 && c.minimumSizes[8*11+7] >= 18)
        #expect(c.pairBounds.contains { $0.first == 10*11+6 && $0.second == 10*11+7 && $0.minimum >= 52 })
        #expect(!context.permits([5*11+10, 6*11+10]))
    }

    @Test func singletonDeductionsDoNotGuessAndHandleLargeClues() {
        let ambiguous = SearchContext(config: config(rows: 3, cols: 3, clues: [-1,-1,-1,-1,1,-1,-1,-1,-1]))
        #expect(ambiguous.constraints.forcedSingletons.isEmpty)
        let large = SearchContext(config: config(rows: 1, cols: 4, clues: [0,-1,-1,Int.max]))
        #expect(large.constraints.pairBounds.contains {
            $0.first == 1 && $0.second == 2 && $0.minimum == 2*(Int.max/3)+(2*(Int.max%3)+2)/3
        })
        let impossible = SearchContext(config: config(rows: 1, cols: 2, clues: [1,2]))
        #expect(impossible.constraints.forcedSingletons.isEmpty)
        #expect(!impossible.permits([0]) && !impossible.permits([1]))
    }

    @Test func deductionsPreserveIndependentlyValidatedPartitions() {
        let blank = Array(repeating: -1, count: 9)
        let base = SearchContext(config: config(rows: 3, cols: 3, clues: blank))
        var fixtures = 0
        for mask in 1..<(1 << 9) {
            let labels = (0..<9).map { mask & (1 << $0) != 0 ? 0 : $0+1 }
            let report = ExactValidator().validate(base.board(labels: labels), target: OriginalCondition(Status: Array(repeating: Array(repeating: 0, count: 3), count: 3)))
            guard report.issues.isEmpty, !report.capitols.isEmpty else { continue }
            var full = Array(repeating: 0, count: 9)
            for mismatch in report.mismatches { full[mismatch.cell.row*3+mismatch.cell.col] = mismatch.actual! }
            for parity in 0..<3 {
                let clues = full.enumerated().map { parity == 2 || $0.offset % 2 == parity ? $0.element : -1 }
                let context = SearchContext(config: config(rows: 3, cols: 3, clues: clues))
                let parts = context.groups(labels)
                #expect(parts.allSatisfy { context.permits($0) })
                let sizes = labels.indices.map { cell in parts.first { $0.contains(cell) }!.count }
                #expect(context.constraints.forcedSingletons.allSatisfy { sizes[$0] == 1 })
                #expect(context.constraints.pairBounds.allSatisfy { sizes[$0.first]+sizes[$0.second] >= $0.minimum })
                fixtures += 1
            }
        }
        #expect(fixtures >= 300)
    }

    @Test func growthVisitsUnknownCapitolsAndResumesPastInvalidPrefixes() {
        var clues = Array(repeating: -1, count: 25); clues[12] = 0
        let context = SearchContext(config: config(rows: 5, cols: 5, clues: clues))
        let patch = Array(0..<25)
        var shapes = Set<[Int]>()
        for _ in 0..<20 {
            shapes.formUnion(context.growCapitolShapes(patch: patch, until: .infinity, budget: 128))
        }
        #expect(context.visitedCapitolAnchors.contains { $0 != 12 })
        #expect(shapes.contains { $0.count > 1 && context.regions.geometry($0).capitol.map { $0 != 12 } == true })
        // Odd bars and the X pentomino are invalid capitol prefixes; a walk must
        // be allowed to continue until an unwanted extra symmetry disappears.
        #expect(shapes.contains { $0.count >= 5 && context.regions.geometry($0).capitol == 12 })
        #expect(shapes.allSatisfy { context.permits($0) && context.grid.connected($0) })
        let steps = context.growthSteps
        #expect(context.growCapitolShapes(patch: patch, until: 0, budget: 128).isEmpty)
        #expect(context.growthSteps == steps)
    }

    @Test func genericSamplingRetainsProgressAndCaplessStates() throws {
        var clues = Array(repeating: -1, count: 9); clues[4] = 0
        var c = config(rows: 3, cols: 3, clues: clues)
        c.catalogMasksPerTransform = 8
        let context = SearchContext(config: c), patch = Array(0..<9)
        var shapes = Set(context.sampleRegionShapes(patch: patch, until: .infinity, budget: 32))
        let cursor = try #require(context.regionSampling[patch])
        let before = cursor.totalSamples
        shapes.formUnion(context.sampleRegionShapes(patch: patch, until: .infinity, budget: 512))
        #expect(cursor.totalSamples == before + 512)
        #expect(shapes.contains([0,1,2,3,5,6,7,8])) // symmetric ring, no capitol
        #expect(shapes.allSatisfy { context.permits($0) })
        let after = cursor.totalSamples
        #expect(context.sampleRegionShapes(patch: patch, until: 0, budget: 100).isEmpty)
        #expect(cursor.totalSamples == after)
    }

    @Test func largeRepairCanRestoreAStateBeyondTheOrdinaryPatchLimit() throws {
        var c = RunConfig.fullPuzzle; c.pathEvaluation = .cpu
        let context = SearchContext(config: c), labels = FullPuzzleFixture.labels
        let giant = context.groups(labels).first { $0.count == 37 }!
        var split = labels
        for cell in giant { split[cell] = 1000+cell }
        let source = context.evaluate(labels: split)
        let restored = try #require(context.rebuildLargeShape(giant, source: source, until: .infinity))
        #expect(restored.validation.answer?.sumOfSquares == 408951)
        #expect(giant.count > c.maxPatchCells && context.largeShapeAttempts == 1)
        #expect(source.labels == context.normalized(split))
        #expect(context.rebuildLargeShape(giant, source: source, until: 0) == nil)
        c.largePatchCells = 36
        context.config = c
        #expect(context.rebuildLargeShape(giant, source: source, until: .infinity) == nil)
    }

    @Test func allForbiddenOrbitsTerminateWithoutADeadline() {
        var c = RunConfig.fullPuzzle; c.pathEvaluation = .cpu
        let context = SearchContext(config: c)
        let forced = 5*11+10
        #expect(context.constraints.forcedSingletons.contains(forced))
        #expect(context.sampleRegionShapes(patch: [forced], until: .infinity, budget: 100).isEmpty)
        // The standalone singleton is still emitted by the enclosing catalog.
        #expect(context.regionCatalog(patch: [forced], until: .infinity) == [[forced]])
    }
}
