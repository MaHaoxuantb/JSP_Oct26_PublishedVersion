import Foundation
import NIOCore
import NIOPosix
import NIOSSL
#if os(Linux)
import Glibc
#else
import Darwin
#endif

func numericAddress(_ text: String, port: Int) throws -> SocketAddress {
    let parts = text.split(separator: "%", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return try SocketAddress(ipAddress: text, port: port) }
    guard !parts[1].isEmpty else { throw DistributedError.message("IPv6 scope is empty.") }
    let scope = UInt32(parts[1]) ?? String(parts[1]).withCString { if_nametoindex($0) }
    var address = sockaddr_in6()
    guard scope > 0, String(parts[0]).withCString({ inet_pton(AF_INET6, $0, &address.sin6_addr) }) == 1 else {
        throw DistributedError.message("Invalid scoped IPv6 address or interface.")
    }
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = in_port_t(port).bigEndian
    address.sin6_scope_id = scope
    #if !os(Linux)
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    #endif
    return SocketAddress(address)
}


struct FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = WireMessage
    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length: UInt32 = buffer.getInteger(at: buffer.readerIndex) else { return .needMoreData }
        guard length > 0 && length <= WireMessage.maxFrame else { throw DistributedError.message("Frame exceeds protocol limit.") }
        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        let bytes = buffer.readBytes(length: Int(length))!
        context.fireChannelRead(wrapInboundOut(try JSONDecoder().decode(WireMessage.self, from: Data(bytes))))
        return .continue
    }
}

func encodedFrame(_ message: WireMessage, allocator: ByteBufferAllocator) throws -> ByteBuffer {
    let data = try JSONEncoder().encode(message)
    guard data.count <= WireMessage.maxFrame else { throw DistributedError.message("Outgoing frame exceeds protocol limit.") }
    var buffer = allocator.buffer(capacity: data.count + 4)
    buffer.writeInteger(UInt32(data.count)); buffer.writeBytes(data)
    return buffer
}

final class ConnectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let limit: Int
    init(limit: Int) { self.limit = limit }
    func acquire() -> Bool { lock.withLock { guard count < limit else { return false }; count += 1; return true } }
    func release() { lock.withLock { count -= 1 } }
}

final class ServerMessages: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WireMessage
    private let coordinator: Coordinator
    private var busy = false
    init(coordinator: Coordinator) { self.coordinator = coordinator }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !busy else { context.close(promise: nil); return }
        busy = true
        let message = unwrapInboundIn(data)
        let channel = context.channel
        Task {
            let response: WireMessage
            do { response = try await coordinator.handle(message) }
            catch { var failure = WireMessage(kind: "error"); failure.error = String(describing: error); response = failure }
            channel.eventLoop.execute {
                self.busy = false
                do {
                    let frame = try encodedFrame(response, allocator: channel.allocator)
                    channel.writeAndFlush(frame).whenComplete { result in
                        if response.kind == "error" { channel.close(promise: nil) }
                        if case .failure = result { channel.close(promise: nil) }
                    }
                } catch { channel.close(promise: nil) }
            }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// One outstanding RPC per connection. All mutable fields are event-loop confined.
final class ClientMessages: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WireMessage
    private var pending: EventLoopPromise<WireMessage>?
    func request(_ message: WireMessage, on channel: any Channel) async throws -> WireMessage {
        let frame = try encodedFrame(message, allocator: channel.allocator)
        let promise = channel.eventLoop.makePromise(of: WireMessage.self)
        channel.eventLoop.execute {
            guard self.pending == nil && channel.isActive else {
                promise.fail(DistributedError.message("Connection is unavailable or busy.")); return
            }
            self.pending = promise
            channel.writeAndFlush(frame).whenFailure { error in self.fail(error) }
        }
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(45)) {
            self.fail(DistributedError.message("Coordinator response timed out."))
            channel.close(promise: nil)
        }
        defer { timeout.cancel() }
        return try await promise.futureResult.get()
    }
    private func fail(_ error: Error) { let promise = pending; pending = nil; promise?.fail(error) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let promise = pending else { context.close(promise: nil); return }
        pending = nil
        promise.succeed(unwrapInboundIn(data))
    }
    func channelInactive(context: ChannelHandlerContext) { fail(DistributedError.message("Connection closed.")); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { fail(error); context.close(promise: nil) }
}

/// Only connection/RPC failures may enter the client's offline retry loop.
/// Local checkpoint, replica, configuration and worker errors must reach shutdown.
struct CoordinatorCommunicationError: Error, CustomStringConvertible {
    let description: String
    var retryable = true
}

struct ClientConnection: Sendable {
    let channel: any Channel
    let messages: ClientMessages
    let machineName: String
    var minimumPeerVersion = SoftwareVersion.current
    static func connect(settings: DistributedConfig, group: MultiThreadedEventLoopGroup) async throws -> Self {
        do { return try await open(settings: settings, group: group) }
        catch { throw CoordinatorCommunicationError(description: String(describing: error)) }
    }
    private static func open(settings: DistributedConfig, group: MultiThreadedEventLoopGroup) async throws -> Self {
        // SocketAddress parses numeric literals (including IPv6 scope identifiers),
        // without DNS resolution. Host and port are never concatenated as a URL.
        let address = try numericAddress(settings.address, port: settings.port)
        let pin = try PinnedIdentity(path: settings.certificatePath)
        let messages = ClientMessages()
        let channel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandlers(try pin.handler(), ByteToMessageHandler(FrameDecoder()), messages)
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                catch { return channel.eventLoop.makeFailedFuture(error) }
            }.connect(to: address).get()
        return Self(channel: channel, messages: messages, machineName: settings.resolvedMachineName, minimumPeerVersion: settings.minimumPeerVersion)
    }
    func request(_ message: WireMessage) async throws -> WireMessage {
        do {
            var message = message
            message.machineName = machineName
            let response = try await messages.request(message, on: channel)
            guard response.version == WireMessage.version else {
                throw CoordinatorCommunicationError(description: "Coordinator protocol mismatch.", retryable: false)
            }
            guard response.kind != "error" else {
                let detail = response.error ?? "unspecified error"
                // Capacity and coordinator storage failures can recover while
                // local computation continues. Rejected reports/authentication
                // require a correction, not endless replays of the same request.
                let retryable = detail.hasPrefix("Coordinator is at client capacity") || detail.hasPrefix("State database")
                throw CoordinatorCommunicationError(description: "Coordinator reported: \(detail)", retryable: retryable)
            }
            guard SoftwareVersion.accepts(response.softwareVersion, minimum: minimumPeerVersion) else {
                throw CoordinatorCommunicationError(description: "Coordinator software version rejected: \(response.softwareVersion.map(String.init) ?? "unversioned"); client v\(SoftwareVersion.current), accepted \(minimumPeerVersion)...\(SoftwareVersion.current).", retryable: false)
            }
            return response
        } catch let error as CoordinatorCommunicationError { throw error }
        catch { throw CoordinatorCommunicationError(description: String(describing: error)) }
    }
    func close() async { try? await channel.close().get() }
}

func startListener(settings: DistributedConfig, identity: ServerIdentity, coordinator: Coordinator,
                   group: MultiThreadedEventLoopGroup) async throws -> any Channel {
    let address = try numericAddress(settings.address, port: settings.port)
    let gate = ConnectionGate(limit: settings.maxClients)
    return try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 32)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
        .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator(minimum: 512, initial: 4096, maximum: 65_536))
        .childChannelInitializer { channel in
            guard gate.acquire() else { return channel.close() }
            channel.closeFuture.whenComplete { _ in gate.release() }
            do {
                let tls = NIOSSLServerHandler(context: identity.context)
                try channel.pipeline.syncOperations.addHandlers(tls,
                    IdleStateHandler(readTimeout: .seconds(Int64(max(60, settings.heartbeatSeconds * 4)))),
                    ByteToMessageHandler(FrameDecoder()), ServerMessages(coordinator: coordinator), CloseIdle())
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(to: address).get()
}

final class CloseIdle: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WireMessage
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
}
