import Foundation
import Testing
@testable import PuzzleSolver

struct PartialRepairTests {
    private func configuration() -> RunConfig {
        var c = RunConfig.example
        c.rowNum = 3; c.colNum = 3
        c.Target = OriginalCondition(Status: [[3,1,0],[-1,1,-1],[1,0,0]])
        c.pathEvaluation = .cpu; c.consoleLogging = false
        c.useRouteBounds = false
        c.exactCoverNodeLimit = 100_000; c.exactCoverSolutionLimit = 100_000
        return c
    }

    private let sourceLabels = [0,1,2,3,4,3,3,3,3]
    private let improvedLabels = [0,0,1,2,3,2,2,2,2]

    @Test func localCoverCanLeaveAnExteriorOneClueForALaterRepair() throws {
        for objective in SearchObjective.allCases {
            var c = configuration(); c.searchObjective = objective
            let context = SearchContext(config: c)
            let source = context.evaluate(labels: sourceLabels)
            #expect(source.quality.wrong == 5)
            let patch = [0,1,2], catalog = [[0,1],[2]]
            let repaired = try #require(context.cover(patch: patch, base: source.labels,
                candidates: catalog, until: .infinity))
            #expect(repaired.labels == improvedLabels)
            #expect(repaired.quality.issues == 0 && repaired.quality.wrong == 3)
            #expect(abs(repaired.quality.error - 0.4) < 1e-12)
            #expect(!repaired.validation.valid)
            #expect(source.labels == sourceLabels)
            #expect(context.cover(patch: patch, base: source.labels, candidates: catalog,
                until: .infinity, strictFeasibility: true) == nil)
            let solution = [0,1,2,0,1,3,0,4,5]
            let solved = try #require(context.cover(patch: Array(0..<9), base: Array(0..<9),
                candidates: context.groups(solution), until: .infinity, strictFeasibility: true))
            #expect(solved.validation.valid)
        }
    }

    @Test func mergeRepairsDoNotReuseStrictScansOrRejectTheUnfinishedExterior() {
        let context = SearchContext(config: configuration())
        let source = context.evaluate(labels: sourceLabels)
        _ = context.mergeRepair(source, until: .infinity, strictFeasibility: true)
        #expect(context.evaluations[improvedLabels] == nil)
        _ = context.mergeRepair(source, until: .infinity)
        #expect(context.evaluations[improvedLabels]?.quality.wrong == 3)
        #expect(context.bestEvaluated!.quality < source.quality)
    }

    @Test func boundaryRepairsCanEvaluateIntermediatesWithUnmatchedCapitolClues() throws {
        var c = configuration()
        c.rowNum = 1; c.colNum = 3
        c.Target = OriginalCondition(Status: [[1,1,1]])
        let context = SearchContext(config: c)
        let source = context.evaluate(labels: [0,0,0])
        let repaired = try #require(context.boundaryRepair(source, until: .infinity))
        #expect(repaired.quality < source.quality)
        #expect(!repaired.validation.valid)
        #expect(context.groups(repaired.labels).allSatisfy { context.permits($0, policy: .repair) })
    }

    @Test func discoveryCachesKeepStrictAndRepairCandidatesAndCursorsSeparate() throws {
        let context = SearchContext(config: configuration()), patch = Array(0..<9)
        let strict = context.regionCatalog(patch: patch, until: .infinity)
        let strictSampling = try #require(context.regionSampling[patch])
        let strictGrowth = try #require(context.capitolGrowth[patch])
        let attempts = strictSampling.totalSamples, steps = strictGrowth.steps
        let relaxed = context.regionCatalog(patch: patch, until: .infinity, policy: .repair)
        #expect(relaxed.contains([0])) // a temporary capitol on a positive clue
        #expect(!strict.contains([0]))
        #expect(strict.allSatisfy { context.permits($0) })
        #expect(relaxed.allSatisfy { context.permits($0, policy: .repair) })
        #expect(context.repairRegionSampling[patch] !== strictSampling)
        #expect(context.repairCapitolGrowth[patch] !== strictGrowth)
        #expect(strictSampling.totalSamples == attempts && strictGrowth.steps == steps)
        #expect(context.regionCatalog(patch: patch, until: .infinity) == strict)
        #expect(!context.permits([0])) // relaxed discovery cannot poison strict permits
        #expect(context.permits([0], policy: .repair))
        #expect(!context.permits([0,8], policy: .repair)) // connectivity stays mandatory
        #expect(!context.permits([0,1,2,3], policy: .repair)) // symmetry stays mandatory
    }

    @Test func historicalLeaderCanRetainStatesThatFailFinalBoardDeductions() throws {
        // Exported seven-wrong incumbent, independent of audit file locations.
        let labels = [
            0,0,0,0,1,1,1,2,2,2,2,
            3,3,3,3,3,1,4,4,4,4,5,
            3,6,6,6,3,1,7,4,4,8,5,
            6,6,6,6,6,6,4,4,4,4,9,
            10,6,6,6,11,11,11,12,12,13,14,
            10,10,10,15,15,16,16,16,17,13,14,
            10,10,10,18,15,15,17,16,17,13,17,
            10,10,10,18,19,19,17,16,17,13,17,
            20,20,10,21,19,19,17,17,17,17,17,
            20,20,20,21,21,22,17,17,17,17,17,
            20,20,20,21,22,22,17,17,17,17,17
        ]
        var c = RunConfig.fullPuzzle; c.pathEvaluation = .cpu
        let context = SearchContext(config: c), source = context.evaluate(labels: labels)
        #expect(source.quality.issues == 0 && source.quality.wrong == 7)
        let rejected = context.groups(source.labels).filter { !context.permits($0) }
        #expect(rejected.count == 6)
        for part in rejected {
            #expect(context.permits(part, policy: .repair))
            let retained = try #require(context.cover(patch: part, base: source.labels,
                candidates: [part], until: .infinity, firstOnly: true))
            #expect(retained.labels == source.labels)
            #expect(retained.quality == source.quality)
            #expect(context.cover(patch: part, base: source.labels, candidates: [part],
                until: .infinity, firstOnly: true, strictFeasibility: true) == nil)
        }
    }

    @Test func scheduledProposalsUseBothDiscoveryPolicies() {
        for policy in [ShapePolicy.feasible, .repair] {
            var c = configuration(); c.repairTimeLimitSeconds = 2
            let context = SearchContext(config: c)
            let source = context.evaluate(labels: Array(repeating: 0, count: 9))
            context.proposalNumber = policy == .feasible ? 0 : 1
            _ = context.repairProposal(source)
            let patch = Array(0..<9)
            if policy == .feasible {
                #expect(context.catalogs[patch] != nil && context.repairCatalogs[patch] == nil)
            } else {
                #expect(context.repairCatalogs[patch] != nil && context.catalogs[patch] == nil)
            }
        }
    }
}
