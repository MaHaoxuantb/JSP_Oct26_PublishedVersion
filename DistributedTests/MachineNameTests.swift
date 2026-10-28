import Testing
import Foundation
@testable import PuzzleSolver

struct MachineNameTests {
    @Test func systemDefaultAndConfiguredOverride() throws {
        let defaults = try JSONDecoder().decode(DistributedConfig.self, from: Data("{}".utf8))
        #expect(defaults.machineName == nil)
        #expect(!defaults.resolvedMachineName.isEmpty)
        #expect(defaults.resolvedMachineName == DistributedConfig.systemMachineName)
        var named = defaults
        named.machineName = "  Workshop Mac  "
        try named.validate()
        #expect(named.resolvedMachineName == "Workshop Mac")
        let decoded = try JSONDecoder().decode(DistributedConfig.self, from: JSONEncoder().encode(named))
        #expect(decoded.resolvedMachineName == "Workshop Mac")
        named.machineName = "   "
        #expect(named.resolvedMachineName == defaults.resolvedMachineName)
        for invalid in [String(repeating: "a", count: 129), "bad\nname", "bad\0name"] {
            named.machineName = invalid
            #expect(throws: (any Error).self) { try named.validate() }
        }
    }

    @Test func namesAppearInStatusAndSurviveRestart() async throws {
        let helper = DistributedTests()
        var config = try helper.configuration()
        defer { try? FileManager.default.removeItem(atPath: config.distributed.stateDirectory) }
        config.distributed.machineName = "Coordinator Mini"
        let token = String(repeating: "t", count: 32)
        let coordinator = try Coordinator(config: config, token: token, newRun: true, now: 0)
        var request = helper.request()
        request.machineName = "MacBook Pro"
        let response = try await coordinator.handle(request, now: 0)
        #expect(response.machineName == "Coordinator Mini")
        let initial = await coordinator.dashboard(now: 0)
        #expect(initial.coordinatorName == "Coordinator Mini")
        #expect(initial.clients.first?.machineName == "MacBook Pro")
        request.kind = "sync"; request.runID = response.runID
        request.machineName = "Lab Mac"
        _ = try await coordinator.handle(request, now: 1)
        let recovered = try Coordinator(config: config, token: token, newRun: false, now: 2)
        let restored = await recovered.dashboard(now: 2)
        #expect(restored.clients.first?.machineName == "Lab Mac")
        request.machineName = String(repeating: "a", count: 129)
        do { _ = try await recovered.handle(request, now: 3); Issue.record("Invalid machine name accepted") } catch {}
        let unchanged = await recovered.dashboard(now: 3)
        #expect(unchanged.clients.first?.machineName == "Lab Mac")
        request.machineName = nil // An older client need not advertise a name.
        _ = try await recovered.handle(request, now: 3)
        let legacy = await recovered.dashboard(now: 3)
        #expect(legacy.clients.first?.machineName == "Lab Mac")
    }

    @Test func legacyStateAndMessagesDecodeWithoutNames() throws {
        var state = CoordinatorState(config: .example)
        state.clientNames = [UUID().uuidString: "Old client"]
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "clientNames")
        let legacyState = try JSONDecoder().decode(CoordinatorState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacyState.clientNames == nil)
        var message = WireMessage(kind: "hello"); message.machineName = "New client"
        object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        object.removeValue(forKey: "machineName")
        let legacyMessage = try JSONDecoder().decode(WireMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacyMessage.machineName == nil)
    }
}
