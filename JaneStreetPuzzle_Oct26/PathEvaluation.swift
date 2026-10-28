import Foundation
#if canImport(Metal) && !PATHS_CPU_ONLY
import Metal
#endif
#if canImport(CUDAPaths) && !PATHS_CPU_ONLY
import CUDAPaths
#endif

enum PathEvaluationMode: String, Codable, Sendable {
    case automatic, cpu, gpu
}

struct PathInput {
    let sizes: [Int]
    let capitols: [Int]
}

struct PathResult: Equatable {
    let distances: [Int]
    let parents: [Int?]
}

protocol GPUPathBackend: Sendable {
    var name: String { get }
    func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]]
}

struct PathDeviceError: Error, CustomStringConvertible {
    let description: String
}

/// Contexts are recreated for calibration, network updates and worker jobs.
/// Keep policy worker-local, but print each identical notice once per process.
final class PathAnnouncements: @unchecked Sendable {
    static let shared = PathAnnouncements()
    private let lock = NSLock()
    private var reasons: Set<String> = []
    func claim(_ reason: String) -> Bool {
        lock.withLock { reasons.insert(reason).inserted }
    }
}

/// Worker-local policy. Device access is serialized by the shared backend.
/// Only distances run on the GPU; floating-point scoring stays on the CPU.
final class PathEvaluator {
    static let infinity = Int32.max / 4
    static let maximumCells = 121
    let grid: Grid
    let mode: PathEvaluationMode
    private let suppliedBackend: (any GPUPathBackend)?
    private let useSystemBackend: Bool
    private var disabled = false
    private var calibrated = false
    private(set) var gpuBatches = 0
    private(set) var gpuBoards = 0
    private(set) var fallbackReason: String?

    init(grid: Grid, mode: PathEvaluationMode, backend: (any GPUPathBackend)? = nil,
         useSystemBackend: Bool = true) {
        self.grid = grid; self.mode = mode
        suppliedBackend = backend; self.useSystemBackend = useSystemBackend
    }

    var reportedBackend: String {
        if !disabled && gpuBatches > 0 { return (suppliedBackend ?? (useSystemBackend ? SystemPathDevice.backend : nil))?.name ?? "CPU" }
        return "CPU"
    }
    var reportedReason: String? {
        fallbackReason ?? (mode == .cpu ? "CPU configured" : (gpuBatches == 0 ? "GPU batch threshold not reached" : nil))
    }

    var batchSize: Int {
        mode != .cpu && !disabled && grid.count <= Self.maximumCells
            && (mode == .gpu || grid.count >= 64) ? 32 : 1
    }

    func evaluate(_ inputs: [PathInput], cpu: (PathInput) -> PathResult) -> [PathResult] {
        guard !inputs.isEmpty else { return [] }
        guard mode != .cpu, !disabled, grid.count > 0, grid.count <= Self.maximumCells,
              mode == .gpu || (grid.count >= 64 && inputs.count >= 8),
              inputs.allSatisfy({ input in
                  input.sizes.count == grid.count && input.sizes.allSatisfy { (1...grid.count).contains($0) }
                      && input.capitols.allSatisfy { (0..<grid.count).contains($0) }
              }) else { return inputs.map(cpu) }
        guard let backend = suppliedBackend ?? (useSystemBackend ? SystemPathDevice.backend : nil) else {
            disable("GPU unavailable; using CPU paths")
            return inputs.map(cpu)
        }
        do {
            // Warm up outside the timing comparison: includes shader compilation.
            if mode == .automatic && !calibrated {
                _ = try backend.distances(grid: grid, inputs: inputs)
            }
            let start = ProcessInfo.processInfo.systemUptime
            let raw = try backend.distances(grid: grid, inputs: inputs)
            guard raw.count == inputs.count else { throw PathDeviceError(description: "GPU batch count mismatch") }
            let results = try zip(inputs, raw).map { input, distances in
                guard let result = Self.certify(grid: grid, input: input, raw: distances) else {
                    throw PathDeviceError(description: "GPU distance certificate failed")
                }
                return result
            }
            let gpuSeconds = ProcessInfo.processInfo.systemUptime - start
            gpuBatches += 1; gpuBoards += inputs.count
            if mode == .automatic && !calibrated {
                calibrated = true
                let cpuStart = ProcessInfo.processInfo.systemUptime
                let reference = inputs.map(cpu)
                let cpuSeconds = ProcessInfo.processInfo.systemUptime - cpuStart
                guard results == reference else { throw PathDeviceError(description: "GPU/CPU startup comparison failed") }
                if gpuSeconds >= cpuSeconds {
                    disable("\(backend.name) paths slower than CPU for this worker's batch; using CPU")
                } else {
                    announce("\(backend.name) integer paths selected after CPU comparison")
                }
                return reference
            }
            if gpuBatches == 1 { announce("\(backend.name) integer paths active") }
            return results
        } catch {
            disable("GPU paths failed (\(error)); using CPU")
            return inputs.map(cpu)
        }
    }

    private func disable(_ reason: String) {
        disabled = true; fallbackReason = reason
        announce(reason)
    }

    private func announce(_ reason: String) {
        guard PathAnnouncements.shared.claim(reason) else { return }
        // Also visible with console logging off.
        try? FileHandle.standardError.write(contentsOf: Data("[paths] \(reason)\n".utf8))
    }

    /// O(V+E) shortest-path certificate: zero sources, positive tight predecessor
    /// chains, and every edge's triangle inequality. Together these prove exact
    /// distances, including unreachable cells, without rerunning Dijkstra.
    /// Parents reproduce Dijkstra's (distance, cell-index) tie order.
    static func certify(grid: Grid, input: PathInput, raw: [Int32]) -> PathResult? {
        guard grid.count > 0, grid.count <= maximumCells,
              raw.count == grid.count, input.sizes.count == grid.count,
              input.sizes.allSatisfy({ (1...grid.count).contains($0) }),
              input.capitols.allSatisfy({ (0..<grid.count).contains($0) }) else { return nil }
        let sources = Set(input.capitols)
        let bound = (grid.count - 1) * grid.count
        let distances = raw.map { $0 == infinity ? Int.max : Int($0) }
        var parents = Array<Int?>(repeating: nil, count: grid.count)
        for cell in 0..<grid.count {
            let distance = distances[cell]
            if sources.contains(cell) {
                guard distance == 0 else { return nil }
            } else if distance != Int.max {
                guard distance > 0 && distance <= bound else { return nil }
            }
            for neighbor in grid.neighbors(cell) {
                let previous = distances[neighbor]
                guard previous != Int.max else { continue }
                guard previous >= 0 && previous <= bound else { return nil }
                let through = previous + min(input.sizes[cell], input.sizes[neighbor])
                guard distance <= through else { return nil }
                if distance == through && !sources.contains(cell) {
                    if let parent = parents[cell] {
                        if previous < distances[parent] || (previous == distances[parent] && neighbor < parent) {
                            parents[cell] = neighbor
                        }
                    } else { parents[cell] = neighbor }
                }
            }
            if distance != Int.max && !sources.contains(cell) && parents[cell] == nil { return nil }
        }
        return PathResult(distances: distances, parents: parents)
    }
}

private enum SystemPathDevice {
    static let backend: (any GPUPathBackend)? = {
        #if canImport(Metal) && !PATHS_CPU_ONLY
        return try? MetalPathBackend()
        #elseif canImport(CUDAPaths) && !PATHS_CPU_ONLY
        return try? CUDAPathBackend()
        #else
        return nil
        #endif
    }()
}

#if canImport(Metal) && !PATHS_CPU_ONLY
/// One SIMD group per board. Double-buffered Bellman-Ford relaxations use exact
/// Int32 arithmetic, with at most V-1 rounds and a uniform convergence check.
final class MetalPathBackend: GPUPathBackend, @unchecked Sendable {
    let name = "Metal"
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let lock = NSLock()

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw PathDeviceError(description: "Metal device unavailable")
        }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "integerPaths") else {
            throw PathDeviceError(description: "Metal kernel missing")
        }
        self.device = device; self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]] {
        lock.lock(); defer { lock.unlock() }
        guard grid.count <= PathEvaluator.maximumCells, !inputs.isEmpty,
              inputs.count <= 32 else { throw PathDeviceError(description: "Invalid Metal batch") }
        let sizes = inputs.flatMap { $0.sizes.map(Int32.init) }
        let seeds = inputs.flatMap { input -> [Int32] in
            var seeds = Array(repeating: PathEvaluator.infinity, count: grid.count)
            for cell in input.capitols { seeds[cell] = 0 }
            return seeds
        }
        let bytes = sizes.count * MemoryLayout<Int32>.stride
        guard let sizeBuffer = device.makeBuffer(bytes: sizes, length: bytes, options: .storageModeShared),
              let seedBuffer = device.makeBuffer(bytes: seeds, length: bytes, options: .storageModeShared),
              let output = device.makeBuffer(length: bytes, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw PathDeviceError(description: "Metal allocation failed")
        }
        var parameters = SIMD4<UInt32>(UInt32(grid.rows), UInt32(grid.cols), UInt32(inputs.count), UInt32(pipeline.threadExecutionWidth))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(sizeBuffer, offset: 0, index: 0)
        encoder.setBuffer(seedBuffer, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: inputs.count, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else {
            throw PathDeviceError(description: command.error?.localizedDescription ?? "Metal command failed")
        }
        let result = output.contents().bindMemory(to: Int32.self, capacity: sizes.count)
        return inputs.indices.map { Array(UnsafeBufferPointer(start: result + $0 * grid.count, count: grid.count)) }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void integerPaths(device const int *sizes [[buffer(0)]],
                             device const int *seeds [[buffer(1)]],
                             device int *output [[buffer(2)]],
                             constant uint4 &info [[buffer(3)]],
                             uint board [[threadgroup_position_in_grid]],
                             uint lane [[thread_index_in_threadgroup]]) {
        if (board >= info.z) return;
        const int n = int(info.x * info.y), cols = int(info.y), offset = int(board) * n;
        threadgroup int a[121], b[121];
        threadgroup int *previous = a, *next = b;
        for (int cell = int(lane); cell < n; cell += int(info.w)) previous[cell] = seeds[offset+cell];
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (int step = 1; step < n; ++step) {
            bool changed = false;
            for (int cell = int(lane); cell < n; cell += int(info.w)) {
                int best = previous[cell];
                int neighbors[4] = {cell-cols, cell+1, cell+cols, cell-1};
                bool allowed[4] = {cell >= cols, cell%cols+1 < cols, cell+cols < n, cell%cols > 0};
                for (int k = 0; k < 4; ++k) if (allowed[k]) {
                    int from = neighbors[k];
                    best = min(best, previous[from] + min(sizes[offset+cell], sizes[offset+from]));
                }
                next[cell] = best;
                changed = changed || best != previous[cell];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            threadgroup int *swap = previous; previous = next; next = swap;
            if (!simd_any(changed)) break;
        }
        for (int cell = int(lane); cell < n; cell += int(info.w)) output[offset+cell] = previous[cell];
    }
    """
}
#endif

#if canImport(CUDAPaths) && !PATHS_CPU_ONLY
final class CUDAPathBackend: GPUPathBackend, @unchecked Sendable {
    let name = "CUDA"
    private let handle: OpaquePointer
    private let lock = NSLock()
    init() throws {
        var error = [CChar](repeating: 0, count: 1024)
        guard let handle = jsp_cuda_create(&error, error.count) else {
            throw PathDeviceError(description: Self.message(error))
        }
        self.handle = handle
    }
    deinit { jsp_cuda_destroy(handle) }
    func distances(grid: Grid, inputs: [PathInput]) throws -> [[Int32]] {
        lock.lock(); defer { lock.unlock() }
        let sizes = inputs.flatMap { $0.sizes.map(Int32.init) }
        let seeds = inputs.flatMap { input -> [Int32] in
            var result = Array(repeating: PathEvaluator.infinity, count: grid.count)
            for cell in input.capitols { result[cell] = 0 }; return result
        }
        var result = Array(repeating: Int32(0), count: sizes.count)
        var error = [CChar](repeating: 0, count: 1024)
        guard jsp_cuda_paths(handle, Int32(grid.rows), Int32(grid.cols), Int32(inputs.count),
                             sizes, seeds, &result, &error, error.count) == 0 else {
            throw PathDeviceError(description: Self.message(error))
        }
        return inputs.indices.map { Array(result[($0 * grid.count)..<(($0 + 1) * grid.count)]) }
    }
    private static func message(_ bytes: [CChar]) -> String {
        String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
#endif
