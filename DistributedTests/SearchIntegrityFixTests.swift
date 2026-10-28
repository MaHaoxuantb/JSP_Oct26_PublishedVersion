import Foundation
import Testing
@testable import PuzzleSolver

struct SearchIntegrityFixTests {
    private func smallConfig() -> RunConfig {
        var c = RunConfig.example
        c.rowNum = 3; c.colNum = 3
        c.Target = OriginalCondition(Status: [[-1,1,3],[-1,-1,1],[0,1,3]])
        c.pathEvaluation = .cpu; c.consoleLogging = false
        c.exactCoverNodeLimit = 100_000; c.exactCoverSolutionLimit = 100_000
        c.useRouteBounds = false
        return c
    }

    private func lineConfig() -> RunConfig {
        var c = RunConfig.example
        c.rowNum = 1; c.colNum = 37
        var clues = Array(repeating: -1, count: 37); clues[0] = 1261; clues[36] = 0
        c.Target = OriginalCondition(Status: [clues])
        c.pathEvaluation = .cpu; c.consoleLogging = false
        return c
    }

    @Test func partialRepairPreservesTheFiveToOneImprovement() throws {
        let sourceLabels = [0,1,1,0,2,1,2,2,3]
        let candidates = [[0],[0,1],[0,1,2],[0,1,3],[0,3],[1,2],[2,5],[3],[3,6,7],[4],[6]]
        for objective in SearchObjective.allCases {
            var c = smallConfig(); c.searchObjective = objective
            let context = SearchContext(config: c), patch = Array(0..<8)
            let source = context.evaluate(labels: sourceLabels)
            #expect(source.quality.wrong == 5)
            let repair = try #require(context.cover(patch: patch, base: source.labels,
                                                    candidates: candidates, until: .infinity))
            #expect(repair.quality.wrong == 1)
            #expect(abs(repair.quality.error - 1.0/6) < 1e-12)
            #expect(!repair.validation.valid) // exterior clue still requires a later move
            #expect(source.labels == sourceLabels)
            #expect(context.cover(patch: patch, base: source.labels, candidates: candidates,
                                  until: .infinity, strictFeasibility: true) == nil)
            let solution = [0,0,1,2,3,1,4,5,5]
            let full = try #require(context.cover(patch: Array(0..<9), base: Array(0..<9),
                candidates: context.groups(solution), until: .infinity, strictFeasibility: true))
            #expect(full.validation.valid)
        }
    }

    @Test func evenLargeStateIsGeneratedArchivedAndRebuilt() throws {
        let context = SearchContext(config: lineConfig())
        let source = context.evaluate(labels: Array(0..<37)), bar = Array(0..<36)
        #expect(context.permits(bar))
        #expect(context.regions.geometry(bar).capitol == nil)
        // Only the puzzle clues are supplied to the generator, not the target
        // bar. Its expected shape is used below to verify the generated result.
        for _ in 0..<16 { _ = context.largeShapeProposal(source, until: .infinity) }
        #expect(context.largeShapes.contains(bar))
        #expect(context.largeShapes.contains { $0.count % 2 == 0 })
        let rebuilt = try #require(context.rebuildLargeShape(bar, source: source, until: .infinity))
        #expect(rebuilt.validation.valid)
        #expect(rebuilt.validation.capitols == [GridCell(row: 0, col: 36)])
    }

    @Test func generalLargeTurnsDoNotSpendTheirBudgetOnTheArchive() {
        var c = lineConfig(); c.largeRepairInterval = 1; c.repairTimeLimitSeconds = 1
        let context = SearchContext(config: c), patch = Array(0..<37)
        let source = context.evaluate(labels: patch)
        context.retainLargeShapes([Array(0..<36)])
        context.largeRepairTurn = 1
        let ticket = context.repairTicket
        _ = context.repairProposal(source)
        #expect(context.largeRepairTurn == 2)
        #expect(context.largeShapeAttempts == 0)
        #expect(context.repairTicket != ticket)
        #expect(context.regionSampling[patch] == nil && context.capitolGrowth[patch] == nil)
    }

    @Test func saturatedCatalogStillSamplesAndCanReplaceOldShapes() throws {
        var c = smallConfig()
        c.Target = OriginalCondition(Status: [[-1,-1,-1],[-1,0,-1],[-1,-1,-1]])
        c.catalogCandidateLimit = 2
        let context = SearchContext(config: c), patch = Array(0..<9)
        let old = [[0],[1]]
        let replacement = context.refreshedCatalog(previous: old, incoming: [[0,1],[2,5],[4]])
        #expect(replacement.count <= 2)
        #expect(Set(replacement.flatMap { $0 }).isSuperset(of: Set(old.flatMap { $0 })))
        #expect(replacement.contains([0,1]))
        let first = context.regionCatalog(patch: patch, until: .infinity)
        let cursor = try #require(context.regionSampling[patch])
        let samples = cursor.totalSamples
        var covered = Set(first.flatMap { $0 })
        for _ in 0..<16 {
            let catalog = context.regionCatalog(patch: patch, until: .infinity)
            #expect(catalog.count <= 2 && catalog.allSatisfy { context.permits($0) })
            let next = Set(catalog.flatMap { $0 })
            #expect(next.isSuperset(of: covered))
            covered = next
        }
        #expect(cursor.totalSamples > samples)
    }

    @Test func replacementProtectsRequiredSingletonCoverage() {
        var c = smallConfig(); c.catalogCandidateLimit = 4
        let context = SearchContext(config: c)
        #expect(context.constraints.forcedSingletons.contains(4))
        var catalog = [[4],[0,1],[2,5],[3,6,7]]
        let represented = Set(catalog.flatMap { $0 })
        let incoming = context.initialCatalog(until: .infinity)
        for _ in 0..<8 {
            catalog = context.refreshedCatalog(previous: catalog, incoming: incoming)
            #expect(catalog.contains([4]) && catalog.count <= 4)
            #expect(Set(catalog.flatMap { $0 }).isSuperset(of: represented))
        }
    }

    @Test func activeCatalogsRetainTheirSamplingCursorAcrossNinePatches() throws {
        var c = smallConfig()
        c.Target = OriginalCondition(Status: [[-1,-1,-1],[-1,0,-1],[-1,-1,-1]])
        let context = SearchContext(config: c), patch = Array(1..<9)
        _ = context.sampleRegionShapes(patch: patch, until: .infinity, budget: 1)
        let cursor = try #require(context.regionSampling[patch])
        for removed in 1..<9 {
            _ = context.sampleRegionShapes(patch: (0..<9).filter { $0 != removed }, until: .infinity, budget: 1)
        }
        _ = context.sampleRegionShapes(patch: patch, until: .infinity, budget: 1)
        #expect(context.regionSampling[patch] === cursor)
        #expect(cursor.totalSamples == 2)
    }
}
