import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOHTTP1

struct DashboardClient: Codable, Sendable {
    let id: UUID
    let machineName: String?
    let connected: Bool
    let lastSeenSeconds: Double?
    let assignedJobs: Int
    let info: FleetClient?
    let directive: ClientDirective?
}

struct DashboardJob: Codable, Sendable {
    let id: UUID
    let clientID: UUID
    let slot: Int
    let generation: Int
    let objective: String
    let explorer: Bool
    let status: String
    let completed: Int
    let budget: Int
    let reportedSeconds: Double
}

struct DashboardSnapshot: Codable, Sendable {
    var softwareVersion = SoftwareVersion.current
    var minimumPeerVersion = SoftwareVersion.current
    let runID: UUID
    let coordinatorName: String?
    let solved: Bool
    let completedJobs: UInt64
    let reassignments: UInt64
    let backupAgeSeconds: Double?
    let clients: [DashboardClient]
    let jobs: [DashboardJob]
    let capturedAt: Double
    let rows: Int
    let cols: Int
    let clues: [[Int]]
    let candidates: [DashboardCandidate]
    let insights: SearchInsights
    let commands: [ManagementCommand]
}

/// Separate browser listener; the worker join token never authorizes management.
func dashboardAdminToken(directory: String) throws -> String {
    let path = URL(fileURLWithPath: directory).appendingPathComponent("web-admin-token")
    if !FileManager.default.fileExists(atPath: path.path) {
        let value = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        try writePrivate(Data(value.utf8), to: path)
    }
    let value = try String(contentsOf: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard value.utf8.count >= 32, value.utf8.count <= 1024 else { throw DistributedError.message("Invalid web-admin-token file.") }
    return value
}

func startDashboard(settings: DistributedConfig, coordinator: Coordinator,
                    group: MultiThreadedEventLoopGroup) async throws -> (any Channel)? {
    guard settings.webUIEnabled else { return nil }
    let address = try numericAddress(settings.webUIAddress, port: settings.webUIPort)
    let adminToken = try dashboardAdminToken(directory: settings.stateDirectory)
    let gate = ConnectionGate(limit: 32)
    return try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 32)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            guard gate.acquire() else { return channel.close() }
            channel.closeFuture.whenComplete { _ in gate.release() }
            do {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                try channel.pipeline.syncOperations.addHandlers(
                    IdleStateHandler(readTimeout: .seconds(10)), DashboardHTTP(coordinator: coordinator, adminToken: adminToken))
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(to: address).get()
}

final class DashboardHTTP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let coordinator: Coordinator
    private let adminToken: String
    private var head: HTTPRequestHead?
    private var body = Data()
    private var responding = false
    init(coordinator: Coordinator, adminToken: String) { self.coordinator = coordinator; self.adminToken = adminToken }

    /// Remote browsers may administer with the separate bearer token. Keep the
    /// browser's Origin tied to this authority; never enable wildcard CORS.
    static func sameOrigin(host: String?, origin: String?) -> Bool {
        guard let host, let origin, !host.isEmpty,
              !host.contains(where: { $0.isWhitespace || $0 == "\\" }),
              let url = URLComponents(string: "http://" + host),
              let hostname = url.host, !hostname.isEmpty,
              url.user == nil, url.password == nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return origin == "http://" + host || origin == "https://" + host
    }
    private func authorized(_ head: HTTPRequestHead, channel: any Channel) -> Bool {
        guard Self.sameOrigin(host: head.headers.first(name: "Host"), origin: head.headers.first(name: "Origin")),
              head.headers["Host"].count == 1, head.headers["Origin"].count == 1,
              head.headers["Authorization"].count == 1,
              head.headers.first(name: "Content-Type")?.lowercased() == "application/json",
              let supplied = head.headers.first(name: "Authorization") else { return false }
        let a = Array(supplied.utf8), b = Array(("Bearer " + adminToken).utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
        case .body(var bytes):
            guard head?.method == .POST, body.count + bytes.readableBytes <= 4096 else {
                responding = true
                respond(on: context.channel, status: .payloadTooLarge, type: "text/plain", body: Data("Request body rejected.".utf8)); return
            }
            body.append(contentsOf: bytes.readBytes(length: bytes.readableBytes) ?? [])
        case .end:
            responding = true
            guard let head else { context.close(promise: nil); return }
            let channel = context.channel
            if head.method == .POST && ["/api/commands", "/api/admin/check"].contains(head.uri) {
                guard authorized(head, channel: channel) else {
                    respond(on: channel, status: .forbidden, type: "text/plain", body: Data("Administration requires a matching Origin and the separate web admin token.".utf8)); return
                }
                if head.uri == "/api/admin/check" {
                    respond(on: channel, status: .ok, type: "application/json", body: Data("{\"authorized\":true}".utf8)); return
                }
                let request: ManagementRequest
                do { request = try JSONDecoder().decode(ManagementRequest.self, from: body) }
                catch { respond(on: channel, status: .badRequest, type: "text/plain", body: Data("Invalid command.".utf8)); return }
                Task {
                    do {
                        let command = try await coordinator.manage(request)
                        let encoded = try JSONEncoder().encode(command)
                        channel.eventLoop.execute { self.respond(on: channel, status: .accepted, type: "application/json", body: encoded) }
                    } catch {
                        let encoded = Data(String(describing: error).utf8)
                        channel.eventLoop.execute { self.respond(on: channel, status: .conflict, type: "text/plain", body: encoded) }
                    }
                }
                return
            }
            guard head.method == .GET else {
                respond(on: channel, status: .methodNotAllowed, type: "text/plain", body: Data("Use GET for monitoring.".utf8)); return
            }
            switch head.uri {
            case "/": respond(on: channel, status: .ok, type: "text/html; charset=utf-8", body: Data(dashboardHTML.utf8))
            case "/api/status":
                Task {
                    let snapshot = await coordinator.dashboard()
                    do {
                        let encoded = try JSONEncoder().encode(snapshot)
                        channel.eventLoop.execute { self.respond(on: channel, status: .ok, type: "application/json", body: encoded) }
                    } catch {
                        channel.eventLoop.execute { self.respond(on: channel, status: .internalServerError, type: "text/plain", body: Data("Status unavailable.".utf8)) }
                    }
                }
            default: respond(on: channel, status: .notFound, type: "text/plain", body: Data("Not found.".utf8))
            }
        }
    }
    private func respond(on channel: any Channel, status: HTTPResponseStatus, type: String, body: Data) {
        var headers = HTTPHeaders([
            ("Content-Type", type), ("Content-Length", String(body.count)), ("Connection", "close"),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
        ])
        if status == .methodNotAllowed { headers.add(name: "Allow", value: "GET") }
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        var buffer = channel.allocator.buffer(capacity: body.count); buffer.writeBytes(body)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) }
        else { context.fireUserInboundEventTriggered(event) }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

let dashboardHTML = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>JSP_Oct26</title>
<meta name="color-scheme" content="light dark">
<script>
const themeQuery=window.matchMedia('(prefers-color-scheme: dark)');
let themePreference='system';
try{const saved=localStorage.getItem('puzzle-theme');if(['light','dark','system'].includes(saved))themePreference=saved;}catch{}
function applyTheme(){
 document.documentElement.dataset.theme=themePreference==='system'?(themeQuery.matches?'dark':'light'):themePreference;
 document.querySelectorAll('[data-theme-option]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.themeOption===themePreference)));
}
applyTheme();
themeQuery.addEventListener('change',applyTheme);
</script>
<style>
:root{color-scheme:light;--bg:#fafafa;--surface:#fff;--soft:#f5f5f7;--text:#202024;--muted:#6e6e78;--line:#e9e9ed;--accent:#7057d9;--green:#207453;--green-bg:#edf7f1;--amber:#916314;--amber-bg:#fbf4e7;--shadow:0 1px 3px #18181b06}
:root[data-theme=dark]{color-scheme:dark;--bg:#151517;--surface:#1c1c1f;--soft:#242427;--text:#eeeef0;--muted:#a0a0aa;--line:#303035;--accent:#b29bff;--green:#8bd6ad;--green-bg:#23372c;--amber:#e2bd7d;--amber-bg:#3a3022;--shadow:0 1px 3px #00000012}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;-webkit-font-smoothing:antialiased}
button{font:inherit}svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round;flex-shrink:0}
.topbar{background:var(--surface);border-bottom:1px solid var(--line)}.topbar-inner{max-width:1240px;min-height:76px;margin:auto;padding:16px 32px;display:flex;align-items:center;justify-content:space-between;gap:20px}
.brand{display:flex;align-items:center;gap:12px;font-weight:600;letter-spacing:-.3px}.brand-mark{width:30px;height:30px;background:var(--text);color:var(--surface);border-radius:9px;display:grid;place-items:center}.brand-mark svg{width:19px;height:19px}
.brand-divider{height:17px;border-left:1px solid var(--line);margin:0 3px}.brand-context{color:var(--muted);font-size:13px;font-weight:400;letter-spacing:0}
.theme-picker{display:flex;gap:2px;padding:3px;border:1px solid var(--line);border-radius:9px;background:var(--soft)}
.theme-picker button{display:flex;align-items:center;gap:6px;border:0;border-radius:6px;padding:6px 10px;cursor:pointer;background:transparent;color:var(--muted);font-size:12px}
.theme-picker button[aria-pressed=true]{background:var(--surface);color:var(--text);box-shadow:0 1px 3px #00000014}.theme-picker svg{width:14px;height:14px}
button:hover{color:var(--text)}button:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
main{max-width:1240px;margin:auto;padding:48px 32px 28px}.page-heading{display:flex;justify-content:space-between;align-items:center;gap:24px;margin-bottom:30px}
h1{font-size:30px;font-weight:600;line-height:1.25;letter-spacing:-1px;margin:0 0 10px}h2{font-size:15px;letter-spacing:-.2px;font-weight:600;margin:0}
p{margin:0;color:var(--muted)}.subtitle{font-size:14px}.live-block{text-align:right;flex-shrink:0}.status{display:inline-flex;align-items:center;gap:7px;color:var(--green);background:var(--green-bg);padding:5px 10px;border-radius:20px;font-size:12px;font-weight:500}
.status::before{content:"";width:6px;height:6px;border-radius:50%;background:currentColor}.status.stale{color:var(--amber);background:var(--amber-bg)}#updated{font-size:11px;margin-top:8px}
.cards{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));border:1px solid var(--line);background:var(--surface);border-radius:14px;box-shadow:var(--shadow);margin-bottom:28px;overflow:hidden}
.card{padding:23px 25px;position:relative}.card+.card{border-left:1px solid var(--line)}.metric-label{display:flex;align-items:center;justify-content:space-between;gap:10px;color:var(--muted);font-size:12px}.metric-label svg{width:16px;height:16px;opacity:.7}
.card strong{display:block;font-size:34px;line-height:1.25;letter-spacing:-1px;font-weight:550;margin:14px 0 6px;font-variant-numeric:tabular-nums}.metric-note{font-size:11px;color:var(--muted)}
.panel{margin-bottom:22px;border:1px solid var(--line);border-radius:14px;background:var(--surface);box-shadow:var(--shadow);overflow:hidden}.panel-heading{padding:21px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px}.panel-heading p{font-size:12px;margin-top:4px}
.count{padding:3px 8px;background:var(--soft);color:var(--muted);border:1px solid var(--line);border-radius:6px;font-size:11px;white-space:nowrap}
.table-wrap{overflow-x:auto}table{border-collapse:collapse;width:100%;white-space:nowrap;text-align:left}th,td{padding:15px 24px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-size:11px;font-weight:500;background:var(--soft);border-top:1px solid var(--line)}td{font-size:12px;font-variant-numeric:tabular-nums}tbody tr:last-child td{border-bottom:0}tbody tr:hover{background:var(--soft)}
.identifier{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;color:var(--muted);font-size:11px}.badge{display:inline-flex;align-items:center;padding:3px 8px;border-radius:6px;background:var(--soft);color:var(--muted);font-size:11px}.badge.active{color:var(--green);background:var(--green-bg)}.badge.waiting{color:var(--amber);background:var(--amber-bg)}
progress{appearance:none;-webkit-appearance:none;width:78px;height:5px;border:0;border-radius:5px;overflow:hidden;vertical-align:middle;margin-right:10px;background:var(--line);accent-color:var(--accent)}progress::-webkit-progress-bar{background:var(--line);border-radius:5px}progress::-webkit-progress-value{background:var(--accent);border-radius:5px}progress::-moz-progress-bar{background:var(--accent);border-radius:5px}
td.empty{text-align:center;white-space:normal;padding:36px 24px 40px}tbody tr:has(.empty):hover{background:transparent}.empty-icon{width:38px;height:38px;display:grid;place-items:center;border:1px solid var(--line);border-radius:11px;color:var(--muted);margin:0 auto 13px;background:var(--soft)}.empty-title{font-size:13px;font-weight:500;color:var(--text);margin-bottom:5px}.empty-detail{font-size:12px;color:var(--muted)}
footer{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:center;gap:12px;font-size:11px;color:var(--muted);padding:4px 2px}footer p{display:flex;align-items:center;gap:7px}footer svg{width:13px;height:13px}.run-meta{display:flex;align-items:center;gap:6px;min-width:0}#run{font-family:ui-monospace,SFMono-Regular,Consolas,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;max-width:180px}
@media(max-width:760px){.topbar-inner{padding:14px 20px}.brand-context,.brand-divider{display:none}main{padding:30px 20px 22px}.page-heading{align-items:flex-start;flex-direction:column;gap:18px}.live-block{text-align:left}.cards{grid-template-columns:repeat(2,minmax(0,1fr))}.card{padding:20px}.card:nth-child(3){border-left:0;border-top:1px solid var(--line)}.card:nth-child(4){border-top:1px solid var(--line)}.panel-heading,th,td{padding-left:20px;padding-right:20px}h1{font-size:27px}footer{align-items:flex-start;flex-direction:column}}
@media(max-width:400px){.theme-picker button{padding:6px 8px}.theme-picker button span{display:none}.metric-label{font-size:11px}.metric-label svg{display:none}.card strong{font-size:30px}}

input,select{font:inherit;background:var(--surface);color:var(--text);border:1px solid var(--line);border-radius:6px;padding:7px;max-width:100%}
.action{background:var(--soft);border:1px solid var(--line);color:var(--text);border-radius:6px;padding:6px 9px;cursor:pointer;margin:2px}.action:disabled{opacity:.4;cursor:default}
.detail-grid{display:grid;grid-template-columns:1fr 1fr;gap:20px}.detail{padding:24px}.detail h2{margin-bottom:12px}.detail p{margin:8px 0}.quality{display:flex;flex-wrap:wrap;gap:12px;margin:15px 0}.quality strong{font-size:23px;display:block}.quality span{color:var(--muted);font-size:12px}
.board{display:grid;width:min(100%,440px);aspect-ratio:1;margin:18px 0;border:2px solid var(--text)}.board-cell{color:#202024;display:grid;place-items:center;position:relative;border:1px solid #0002;font-weight:600;min-width:0;font-size:clamp(10px,2vw,16px)}.board-cell.wrong{outline:3px solid #c33;outline-offset:-4px}.capital{position:absolute;right:3px;top:0;font-size:10px}.region-id{position:absolute;left:2px;bottom:0;font-size:8px;font-weight:400}
.chart{width:100%;height:130px;color:var(--accent);display:block}.chart text{fill:var(--muted);font-size:11px}.details-list{max-height:190px;overflow:auto;padding-left:20px}.admin-bar{display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin:14px 0}.admin-bar input{width:260px}.admin-message{color:var(--muted);font-size:12px}.controls{min-width:285px}.controls input{width:55px}.notice{color:var(--amber)}.events{max-height:280px;overflow:auto}.events p{margin:0;padding:8px 0;border-bottom:1px solid var(--line);font-size:12px}.mini{font-size:12px;color:var(--muted)}.quality-charts{display:grid;gap:12px}.history-table{max-height:220px;overflow:auto}.history-table td,.history-table th{padding:8px;font-size:12px}
@media(max-width:850px){.detail-grid{grid-template-columns:1fr}.detail{padding:20px}}
.context-menu{position:fixed;z-index:1000;min-width:200px;max-width:calc(100vw - 16px);max-height:calc(100vh - 16px);overflow:auto;padding:6px;background:var(--surface);border:1px solid var(--line);border-radius:10px;box-shadow:0 8px 30px #0003}.context-menu[hidden]{display:none}.context-menu button{display:block;width:100%;border:0;background:transparent;text-align:left;color:var(--text);padding:8px 12px;border-radius:5px;cursor:pointer}.context-menu button:hover,.context-menu button:focus-visible{background:var(--soft)}.context-menu button:disabled{color:var(--muted);cursor:default}.context-menu .menu-heading{font-size:12px;color:var(--muted);padding:4px 12px}tr[tabindex]:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
</style></head><body>
<nav class="topbar" aria-label="Dashboard toolbar"><div class="topbar-inner">
<div class="brand"><span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><path d="M14 17.5h7m-3.5-3.5v7"/></svg></span><span>JSP_Oct26</span><span class="brand-divider"></span><span class="brand-context">October 2026 / Coordinator</span></div>
<div class="theme-picker" role="group" aria-label="Appearance">
<button type="button" data-theme-option="system" aria-label="System theme" aria-pressed="true" title="Follow system appearance"><svg aria-hidden="true" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 21h8m-4-5v5"/></svg><span>System</span></button>
<button type="button" data-theme-option="light" aria-label="Light theme" aria-pressed="false" title="Light appearance"><svg aria-hidden="true" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/></svg><span>Light</span></button>
<button type="button" data-theme-option="dark" aria-label="Dark theme" aria-pressed="false" title="Dark appearance"><svg aria-hidden="true" viewBox="0 0 24 24"><path d="M20.5 14A9 9 0 0 1 10 3.5 9 9 0 1 0 20.5 14Z"/></svg><span>Dark</span></button>
</div></div></nav>
<main><header class="page-heading"><div><h1>JSP_Oct26</h1><p class="subtitle">A live view of your clients and the work in progress.</p></div>
<div class="live-block"><div id="connection" class="status" role="status" aria-live="polite">Connecting</div><p id="updated">Refreshes every 3 seconds</p></div></header>
<section class="cards" aria-label="Run statistics">
<div class="card"><span class="metric-label">Connected clients<svg aria-hidden="true" viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="12" rx="2"/><path d="M8 21h8m-4-5v5"/></svg></span><strong id="clients">—</strong><span class="metric-note">Reporting to this run</span></div>
<div class="card"><span class="metric-label">Assigned jobs<svg aria-hidden="true" viewBox="0 0 24 24"><rect x="4" y="4" width="6" height="6" rx="1"/><rect x="14" y="4" width="6" height="6" rx="1"/><rect x="4" y="14" width="6" height="6" rx="1"/><rect x="14" y="14" width="6" height="6" rx="1"/></svg></span><strong id="jobs">—</strong><span class="metric-note">Across worker slots</span></div>
<div class="card"><span class="metric-label">Completed jobs<svg aria-hidden="true" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"/><path d="m8 12 3 3 5-6"/></svg></span><strong id="completed">—</strong><span class="metric-note">In the current run</span></div>
<div class="card"><span class="metric-label">Reassignments<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M4 8h15l-4-4m5 12H5l4 4"/></svg></span><strong id="reassignments">—</strong><span class="metric-note">Jobs handed to another worker</span></div></section>
<section class="panel detail" aria-label="Search overview"><h2>Search overview</h2><div class="quality"><div><strong id="acceptedWork">0</strong><span>Accepted iterations since metrics began</span></div><div><strong id="fleetRate">0</strong><span>Estimated iterations / second</span></div><div><strong id="lastImproved">—</strong><span>Since last best improvement</span></div></div><p class="mini" id="metricsSince"></p><p class="mini">Candidate quality is not a completion percentage. This search has no reliable solution ETA.</p></section>
<div class="detail-grid"><section class="panel detail" aria-label="Candidate explorer"><h2>Best candidates</h2><select id="candidateSelect" aria-label="Choose candidate"></select><div class="quality"><div><strong id="issues">—</strong><span>Structural issues</span></div><div><strong id="wrong">—</strong><span>Incorrect clues</span></div><div><strong id="error">—</strong><span>Normalized clue error</span></div></div><p id="candidateMeta">Waiting for a reported board.</p><div id="board" class="board" role="img" aria-label="Candidate board"></div><p class="mini">★ Capital · red outline: incorrect clue · small number: region ID. Hover a cell for details.</p><p id="answer"></p><ul id="violations" class="details-list"></ul><button class="action" id="downloadCandidate" disabled>Download candidate JSON</button></section>
<section class="panel detail" aria-label="Search charts"><h2>Search history</h2><p>Best candidate: incorrect clues (structural issues take priority)</p><svg id="qualityChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Incorrect clue history"></svg><p>Lowest total optimization energy (0–1)</p><svg id="energyChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Lowest total energy history"></svg><p>Lowest clue residual energy (0–1)</p><svg id="residualChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Lowest clue residual energy history"></svg><p class="mini">Independent minima across reported candidates; the two energy curves can represent different boards. Points show reports, not every local search move. Hover points for values.</p><p>Accepted iterations</p><svg id="workChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Accepted work history"></svg><p>Reporting worker slots</p><svg id="workersChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Active worker history"></svg><p>Fleet throughput: estimated iterations / second</p><svg id="rateChart" class="chart" viewBox="0 0 500 130" role="img" aria-label="Throughput history"></svg><div class="history-table"><table><thead><tr><th>Improved at</th><th>Issues</th><th>Wrong clues</th><th>Error</th></tr></thead><tbody id="improvementRows"></tbody></table></div></section></div>
<section class="panel detail" aria-label="Administration"><h2>Client management</h2><p>Administration is available from other devices. Enter the coordinator's separate web-admin-token; it stays in this page's memory.</p><div class="admin-bar"><input id="adminToken" type="password" autocomplete="off" aria-label="Web admin token" placeholder="Web admin token"><button class="action" id="unlock">Unlock controls</button><button class="action" id="lock">Lock</button><span id="adminStatus" role="status" class="admin-message">Monitoring only</span></div><p class="mini">Checkpoint &amp; quit saves and stops. Drain &amp; quit finishes assigned jobs. Pause releases assignments and keeps the client available for Resume. Worker count cannot exceed the client's configured capacity. Right-click a machine for its actions (keyboard: Shift+F10). Delivery follows heartbeats; offline commands remain pending. These controls affect the puzzle process.</p></section>
<section class="panel" aria-labelledby="clientHeading"><div class="panel-heading"><div><h2 id="clientHeading">Compute clients</h2><p>Machines connected to your coordinator.</p></div><span class="count" id="clientCount">— clients</span></div>
<div class="table-wrap"><table><thead><tr><th scope="col">Machine</th><th scope="col">Connection</th><th scope="col">Last heartbeat</th><th scope="col">Jobs / telemetry</th><th scope="col">Controls</th></tr></thead><tbody id="clientRows"><tr><td colspan="4" class="empty">Waiting for status…</td></tr></tbody></table></div></section>
<section class="panel" aria-labelledby="jobHeading"><div class="panel-heading"><div><h2 id="jobHeading">Worker assignments</h2><p>Latest reported progress. Worker slots start at zero.</p></div><span class="count" id="jobCount">— jobs</span></div>
<div class="table-wrap"><table><thead><tr><th scope="col">Client / slot</th><th scope="col">Job</th><th scope="col">State</th><th scope="col">Objective</th><th scope="col">Progress</th><th scope="col">Reported time</th></tr></thead><tbody id="jobRows"><tr><td colspan="6" class="empty">Waiting for status…</td></tr></tbody></table></div></section>
<div class="detail-grid"><section class="panel detail"><h2>Command history</h2><div id="commandHistory" class="events"></div></section><section class="panel detail"><h2>Recent events</h2><div id="eventHistory" class="events"></div></section></div>
<footer><span>© 2026 ThomasB, LinecoFlow Research</span><p><svg aria-hidden="true" viewBox="0 0 24 24"><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/></svg><span id="backup">Backup status pending.</span></p><div class="run-meta"><span id="coordinator">Coordinator</span><span>Run</span><span id="run">Connecting…</span></div></footer><noscript><p>Enable JavaScript to view live process status.</p></noscript>
</main><div id="contextMenu" class="context-menu" role="menu" aria-label="Context actions" hidden></div><script>
const $=id=>document.getElementById(id), number=n=>n.toLocaleString(), short=id=>id.slice(0,8);
document.querySelectorAll('[data-theme-option]').forEach(button=>button.addEventListener('click',()=>{
 themePreference=button.dataset.themeOption;
 try{localStorage.setItem('puzzle-theme',themePreference);}catch{}
 applyTheme();
}));
applyTheme();
let latest=null, adminToken='', selectedCandidate='', lastCommandID='';
const age=n=>n==null?'Not seen since restart':Math.floor(n)+'s ago';
function cell(row,text,tag='td'){const el=document.createElement(tag);el.textContent=text;row.append(el);return el;}
function empty(body,columns,title,detail){
 const row=document.createElement('tr'),el=cell(row,'');el.colSpan=columns;el.className='empty';
 const icon=document.createElement('div');icon.className='empty-icon';icon.setAttribute('aria-hidden','true');
 icon.innerHTML='<svg viewBox="0 0 24 24"><rect x="4" y="4" width="16" height="6" rx="2"/><rect x="4" y="14" width="16" height="6" rx="2"/><path d="M8 7h.01M8 17h.01m4-10h4m-4 10h4"/></svg>';
 const heading=document.createElement('div');heading.className='empty-title';heading.textContent=title;
 const description=document.createElement('div');description.className='empty-detail';description.textContent=detail;
 el.append(icon,heading,description);body.append(row);
}
function badge(row,text,state=''){const el=cell(row,'');const label=document.createElement('span');label.className='badge '+state;label.textContent=text;el.append(label);}
function render(s){
 if(latest?.runID!==s.runID)closeMenu();latest=s; renderSearch(s);
 $('run').textContent=short(s.runID);$('run').title=s.runID;
 $('coordinator').textContent=(s.coordinatorName||'Coordinator')+' · v'+s.softwareVersion; $('coordinator').title='Accepted software versions: '+s.minimumPeerVersion+'–'+s.softwareVersion+' (0 = unversioned)';
 $('clientCount').textContent=number(s.clients.length)+' '+(s.clients.length===1?'client':'clients');
 $('jobCount').textContent=number(s.jobs.length)+' '+(s.jobs.length===1?'job':'jobs');
 $('clients').textContent=number(s.clients.filter(c=>c.connected).length);
 $('jobs').textContent=number(s.jobs.filter(j=>j.status==='assigned'||j.status==='reconnecting').length);
 $('completed').textContent=number(s.completedJobs);$('reassignments').textContent=number(s.reassignments);
 $('connection').className='status';$('connection').textContent=s.solved?'Solution validated':(s.clients.some(c=>c.connected)?'Search in progress':'Waiting for clients');
 $('updated').textContent='Updated '+new Date().toLocaleTimeString();
 const clients=$('clientRows'),active=document.activeElement,focusedClient=clients.contains(active)?active.closest('tr')?.dataset.clientId:null,focusedButton=active.tagName==='BUTTON'?active.textContent:null;const editing=(clients.contains(active)&&active.tagName==='INPUT')||(!menu.hidden&&menuSource&&clients.contains(menuSource));if(!editing)clients.replaceChildren();
 const machineNames=new Map(s.clients.map(c=>[c.id,c.machineName||short(c.id)]));
 if(!editing)for(const c of s.clients){const row=document.createElement('tr');row.dataset.clientId=c.id;const id=cell(row,machineNames.get(c.id));id.title=c.id;const version=document.createElement('div');version.className='mini';version.textContent=c.info?.softwareVersion==null?'Version unknown':'v'+c.info.softwareVersion;id.append(version);attachMenu(row,()=>clientMenu(c));const mode=c.info?.telemetry?.mode||'unknown';badge(row,(c.connected?'Reporting':'Offline')+' · '+mode,c.connected?'active':'');const freshness=cell(row,age(c.lastSeenSeconds));const checkpoint=c.info?.telemetry?.checkpointAt;if(checkpoint){const line=document.createElement('div');line.className='mini';line.textContent='Checkpoint '+age(Math.max(0,s.capturedAt-checkpoint));freshness.append(line);}const info=cell(row,number(c.assignedJobs)+' jobs · '+(c.connected?(c.info?.rate||0).toFixed(1):'0')+' iter/s');for(const w of c.info?.telemetry?.workers||[]){const line=document.createElement('div');line.className='mini';line.textContent='Slot '+w.slot+': '+w.state+' · '+w.backend;line.title=(w.reason||'')+(w.progressAt?' · Sample '+age(Math.max(0,s.capturedAt-w.progressAt)):'');info.append(line);}if(c.info?.telemetry?.lastError){const line=document.createElement('div');line.className='mini notice';line.textContent='Last error: '+c.info.telemetry.lastError;info.append(line);}const controls=cell(row,'');controls.className='controls';renderControls(controls,c);clients.append(row);}
 if(!editing&&!s.clients.length)empty(clients,5,'Ready when you are','Connect a compute client to start processing.');
 if(!editing&&focusedClient){const row=[...clients.children].find(r=>r.dataset.clientId===focusedClient),target=focusedButton?[...row?.querySelectorAll('button')||[]].find(b=>b.textContent===focusedButton):row;target?.focus({preventScroll:true});}
 const jobs=$('jobRows');jobs.replaceChildren();
 for(const j of s.jobs){const row=document.createElement('tr');const client=cell(row,(machineNames.get(j.clientID)||short(j.clientID))+' / '+j.slot);client.title=j.clientID;const id=cell(row,short(j.id)+' · g'+j.generation);id.title=j.id;id.className='identifier';attachMenu(row,()=>[{label:'Copy job ID',run:()=>copyText(j.id)},{label:'Copy job details',run:()=>copyText(JSON.stringify(j,null,2))}]);
 badge(row,j.status,j.status==='assigned'?'active':j.status==='stopped'?'':'waiting');cell(row,j.objective+(j.explorer?' · explorer':''));const p=cell(row,'');const bar=document.createElement('progress');bar.max=j.budget;bar.value=j.completed;bar.setAttribute('aria-label','Job '+short(j.id)+' progress');p.append(bar,document.createTextNode(number(j.completed)+' / '+number(j.budget)));cell(row,j.reportedSeconds.toFixed(1)+'s');jobs.append(row);}
 if(!s.jobs.length)empty(jobs,6,s.solved?'Solution found':'No work assigned yet',s.solved?'The coordinator has independently validated the solution.':'Worker assignments will appear here as clients join.');
 $('backup').textContent=s.backupAgeSeconds==null?'No completed backup in this server session.':'Last completed backup '+age(s.backupAgeSeconds)+'.';
}

const when=t=>t?new Date(t*1000).toLocaleString():'Unknown';
const nameFor=id=>latest?.clients.find(c=>c.id===id)?.machineName||id?.slice(0,8)||'Recovered archive';
function renderControls(el,c){
 if(c.info?.telemetry?.controlVersion!==1){el.textContent='Management unsupported';return;}
 for(const [action,label] of [['pause','Pause'],['resume','Resume'],['checkpoint','Checkpoint'],['quit','Checkpoint & quit'],['drain','Drain & quit']]){
 const button=document.createElement('button');button.type='button';button.className='action';button.textContent=label;button.disabled=!adminToken;button.onclick=()=>sendCommand(c,action);el.append(button);}
 const input=document.createElement('input');input.type='number';input.min=1;input.max=c.info.telemetry.capacity;input.value=c.directive?.workerLimit||c.info.telemetry.capacity;input.setAttribute('aria-label','Worker count for '+nameFor(c.id));input.disabled=!adminToken;
 const button=document.createElement('button');button.type='button';button.className='action';button.textContent='Set workers';button.disabled=!adminToken;button.onclick=()=>sendCommand(c,'workers',Number(input.value));el.append(input,button);
}
const menu=$('contextMenu');let menuSource=null;
function closeMenu(restore=false){menu.hidden=true;menu.replaceChildren();if(restore&&menuSource?.isConnected)menuSource.focus();menuSource=null;}
function attachMenu(el,items){
 el.tabIndex=0;
 const open=(x,y)=>{closeMenu();menuSource=el;for(const item of items()){const b=document.createElement('button');b.type='button';b.role='menuitem';b.textContent=item.label;b.disabled=!!item.disabled;b.onclick=async()=>{closeMenu(true);try{await item.run();}catch(e){$('adminStatus').textContent=e.message;}};menu.append(b);}menu.hidden=false;menu.style.left='0px';menu.style.top='0px';menu.style.left=Math.max(8,Math.min(x,innerWidth-menu.offsetWidth-8))+'px';menu.style.top=Math.max(8,Math.min(y,innerHeight-menu.offsetHeight-8))+'px';menu.querySelector('button:not(:disabled)')?.focus();};
 el.oncontextmenu=e=>{if(e.target.closest('input'))return;e.preventDefault();open(e.clientX,e.clientY);};
 el.onkeydown=e=>{if(e.key==='ContextMenu'||(e.shiftKey&&e.key==='F10')){e.preventDefault();const r=el.getBoundingClientRect();open(r.left+16,r.top+16);}};
}
menu.addEventListener('keydown',e=>{const buttons=[...menu.querySelectorAll('button:not(:disabled)')],i=buttons.indexOf(document.activeElement);if(e.key==='Escape'){e.preventDefault();closeMenu(true);}if(['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();buttons[e.key==='Home'?0:e.key==='End'?buttons.length-1:(i+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length]?.focus();}if(e.key==='Tab')closeMenu();});
document.addEventListener('pointerdown',e=>{if(!menu.hidden&&!menu.contains(e.target))closeMenu();});window.addEventListener('resize',()=>closeMenu());window.addEventListener('scroll',()=>closeMenu(),true);
async function copyText(value){if(navigator.clipboard?.writeText){await navigator.clipboard.writeText(value);$('adminStatus').textContent='Copied';}else{prompt('Copy this value',value);}}
function clientMenu(c){
 c=latest?.clients.find(client=>client.id===c.id)||c;
 const items=[{label:'Copy machine ID',run:()=>copyText(c.id)},{label:'Copy version and status',run:()=>copyText(JSON.stringify(c,null,2))}];
 if(c.info?.telemetry?.controlVersion===1){for(const [action,label] of [['pause','Pause'],['resume','Resume'],['checkpoint','Save checkpoint'],['quit','Checkpoint & quit'],['drain','Drain & quit']])items.push({label,disabled:!adminToken,run:()=>sendCommand(c,action)});items.push({label:'Set worker count…',disabled:!adminToken,run:()=>{const value=prompt('Worker count (1–'+c.info.telemetry.capacity+')',c.directive?.workerLimit||c.info.telemetry.capacity);if(value!==null)return sendCommand(c,'workers',Number(value));}});}
 return items;
}
attachMenu($('board'),()=>[{label:'Download candidate JSON',disabled:!candidate(),run:()=>$('downloadCandidate').click()}]);
async function adminPost(path,body){
 const response=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer '+adminToken},body:JSON.stringify(body),signal:AbortSignal.timeout(10000)});
 if(!response.ok){if(response.status===403){adminToken='';if(latest)render(latest);}throw Error(await response.text());}return response.json();
}
$('unlock').onclick=async()=>{adminToken=$('adminToken').value;$('adminToken').value='';try{await adminPost('/api/admin/check',{});$('adminStatus').textContent='Controls unlocked';if(latest)render(latest);}catch(e){adminToken='';$('adminStatus').textContent=e.message;}};
$('lock').onclick=()=>{closeMenu();adminToken='';$('adminToken').value='';$('adminStatus').textContent='Monitoring only';if(latest)render(latest);};
let sending=false;
async function sendCommand(c,action,workers){
 if(sending||!adminToken)return;
 c=latest?.clients.find(client=>client.id===c.id);if(!c)return;
 if(['quit','drain'].includes(action)&&!confirm((action==='quit'?'Save checkpoints and quit ':'Finish assigned jobs and quit ')+nameFor(c.id)+'? The client must be launched again to reconnect.'))return;
 if(action==='workers'&&(!Number.isInteger(workers)||workers<1||workers>c.info.telemetry.capacity)){$('adminStatus').textContent='Worker count exceeds configured capacity';return;}
 sending=true;
 // Keep the same command ID on a network retry, avoiding a second operation.
 const command={id:(crypto.randomUUID?crypto.randomUUID():'10000000-1000-4000-8000-100000000000'.replace(/[018]/g,c=>(c^crypto.getRandomValues(new Uint8Array(1))[0]&15>>c/4).toString(16))),runID:latest.runID,clientID:c.id,action,workers};
 try{let result;try{result=await adminPost('/api/commands',command);}catch(e){if(!adminToken)throw e;result=await adminPost('/api/commands',command);}lastCommandID=result.request.id;$('adminStatus').textContent=nameFor(c.id)+': '+action+' '+result.status+(c.connected?'':' — pending, machine offline');}
 catch(e){$('adminStatus').textContent=e.message;}finally{sending=false;}
}
function chart(id,points,value){
 const svg=$(id),ns='http://www.w3.org/2000/svg';svg.replaceChildren();
 const text=(x,y,t)=>{const e=document.createElementNS(ns,'text');e.setAttribute('x',x);e.setAttribute('y',y);e.textContent=t;svg.append(e);};
 points=points.filter(p=>Number.isFinite(p.at)&&Number.isFinite(value(p)));if(!points.length){text(12,65,'Waiting for measurements');return;}
 const format=v=>Number.isInteger(v)?number(v):v.toPrecision(5);
 const max=Math.max(1,...points.map(value)),start=points[0].at,end=Math.max(start+1,points.at(-1).at,latest?.capturedAt||0),coords=points.map(p=>[45+440*(p.at-start)/(end-start),100-85*value(p)/max]);
 const axis=document.createElementNS(ns,'path');axis.setAttribute('d','M45 15V100H485');axis.setAttribute('stroke','var(--line)');axis.setAttribute('fill','none');svg.append(axis);
 const line=document.createElementNS(ns,'polyline');line.setAttribute('points',[...coords,[485,coords.at(-1)[1]]].map(p=>p.join(',')).join(' '));line.setAttribute('fill','none');line.setAttribute('stroke','currentColor');line.setAttribute('stroke-width','2');svg.append(line);
 for(const [i,[x,y]] of coords.entries()){const dot=document.createElementNS(ns,'circle');dot.setAttribute('cx',x);dot.setAttribute('cy',y);dot.setAttribute('r','3');dot.setAttribute('fill','currentColor');const title=document.createElementNS(ns,'title');title.textContent=when(points[i].at)+' · '+format(value(points[i]));dot.append(title);svg.append(dot);}
 text(0,18,format(max));text(25,104,'0');text(45,124,new Date(start*1000).toLocaleTimeString());text(370,124,new Date(end*1000).toLocaleTimeString());
}
function candidate(){return latest?.candidates.find(c=>c.id===selectedCandidate)||latest?.candidates[0];}
$('candidateSelect').onchange=()=>{const value=$('candidateSelect').value;selectedCandidate=value===latest?.candidates[0]?.id?'':value;renderCandidate();};
function renderCandidate(){
 const c=candidate(),board=$('board');board.replaceChildren();$('violations').replaceChildren();$('downloadCandidate').disabled=!c;
 if(!c){$('issues').textContent=$('wrong').textContent=$('error').textContent='—';$('candidateMeta').textContent='Waiting for a reported board.';$('answer').textContent='';return;}
 $('issues').textContent=c.issues;const total=latest.clues.flat().filter(v=>v>=0).length;$('wrong').textContent=c.wrong+' / '+total;$('error').textContent=c.error.toFixed(6);
 const d=c.discovery;$('candidateMeta').textContent=d?nameFor(d.clientID)+(d.slot==null?'':' · slot '+d.slot)+(d.objective?' · '+d.objective:'')+' · '+when(d.at):'Recovered candidate';
 board.style.gridTemplateColumns='repeat('+latest.cols+',1fr)';board.style.aspectRatio=latest.cols+'/'+latest.rows;
 board.setAttribute('aria-label','Candidate board with '+c.issues+' structural issues and '+c.wrong+' incorrect clues');
 const wrong=new Map(c.validation.mismatches.map(m=>[m.cell.row*latest.cols+m.cell.col,m]));const capitals=new Set(c.validation.capitols.map(p=>p.row*latest.cols+p.col));
 c.labels.forEach((label,i)=>{const el=document.createElement('div'),row=Math.floor(i/latest.cols),col=i%latest.cols,clue=latest.clues[row][col];el.className='board-cell'+(wrong.has(i)?' wrong':'');el.style.background='hsl('+((label*137.508)%360)+' 55% 84%)';el.textContent=clue>=0?clue:'';el.title='Row '+(row+1)+', column '+(col+1)+', region '+label+(wrong.has(i)?'; expected '+clue+', actual '+(wrong.get(i).actual??'unreachable'):'');if(row===0||c.labels[i-latest.cols]!==label)el.style.borderTop='2px solid #333';if(col===0||c.labels[i-1]!==label)el.style.borderLeft='2px solid #333';if(capitals.has(i)){const star=document.createElement('span');star.className='capital';star.textContent='★';el.append(star);}const region=document.createElement('span');region.className='region-id';region.textContent=label;el.append(region);board.append(el);});
 for(const issue of c.validation.issues){const li=document.createElement('li');li.textContent=issue;$('violations').append(li);}for(const m of c.validation.mismatches){const li=document.createElement('li');li.textContent='Clue ('+(m.cell.row+1)+', '+(m.cell.col+1)+'): expected '+m.expected+', actual '+(m.actual??'unreachable');$('violations').append(li);}
 $('answer').textContent=c.validation.valid?'Independently verified solution · answer: '+c.validation.answer.sumOfSquares:'Candidate only — independent validation has not passed.';
}
$('downloadCandidate').onclick=()=>{const c=candidate();if(!c)return;const blob=new Blob([JSON.stringify({runID:latest.runID,rows:latest.rows,cols:latest.cols,clues:latest.clues,candidate:c},null,2)],{type:'application/json'});const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download='candidate-'+c.id.slice(0,8)+'.json';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
function renderSearch(s){
 const lastCommand=s.commands.find(c=>c.request.id===lastCommandID);if(lastCommand){const online=s.clients.find(c=>c.id===lastCommand.request.clientID)?.connected;$('adminStatus').textContent=nameFor(lastCommand.request.clientID)+': '+lastCommand.request.action+' '+lastCommand.status+(lastCommand.status==='queued'&&!online?' — pending, machine offline':'');}
 $('acceptedWork').textContent=number(s.insights.acceptedIterations);$('fleetRate').textContent=s.clients.filter(c=>c.connected).reduce((a,c)=>a+(c.info?.rate||0),0).toFixed(1);const last=s.insights.improvements.at(-1);$('lastImproved').textContent=last?Math.max(0,Math.floor(s.capturedAt-last.at))+'s':'—';$('metricsSince').textContent='Metrics recorded since '+when(s.insights.since)+'. Rates use reported iterations and work time; measurements arrive with heartbeats/checkpoints.';
 const select=$('candidateSelect');select.replaceChildren();s.candidates.forEach((c,i)=>{const o=document.createElement('option');o.value=c.id;o.textContent=(i===0?'Best overall':'Alternative '+i)+' · '+c.issues+' issues · '+c.wrong+' wrong';select.append(o);});if(selectedCandidate&&!s.candidates.some(c=>c.id===selectedCandidate))selectedCandidate='';select.value=selectedCandidate||s.candidates[0]?.id||'';renderCandidate();
 chart('qualityChart',s.insights.improvements,p=>p.wrong);chart('rateChart',s.insights.throughput,p=>p.rate);chart('energyChart',s.insights.energy||[],p=>p.total);chart('residualChart',s.insights.energy||[],p=>p.residual);chart('workChart',s.insights.throughput.filter(p=>p.iterations!=null),p=>p.iterations);chart('workersChart',s.insights.throughput.filter(p=>p.activeWorkers!=null),p=>p.activeWorkers);
 const rows=$('improvementRows');rows.replaceChildren();for(const p of s.insights.improvements.slice(-30).reverse()){const row=document.createElement('tr');cell(row,when(p.at));cell(row,p.issues);cell(row,p.wrong);cell(row,p.error.toFixed(6));rows.append(row);}
 const commands=$('commandHistory');commands.replaceChildren();for(const command of s.commands.slice(-40).reverse()){const p=document.createElement('p');const c=s.clients.find(c=>c.id===command.request.clientID);p.textContent=when(command.createdAt)+' · '+nameFor(command.request.clientID)+' · '+command.request.action+(command.request.workers?' '+command.request.workers:'')+' · '+command.status+(command.status==='queued'&&!c?.connected?' (pending — offline)':'');commands.append(p);}if(!s.commands.length)commands.textContent='No commands issued.';
 const events=$('eventHistory');events.replaceChildren();for(const e of s.insights.events.slice(-60).reverse()){const p=document.createElement('p');p.textContent=when(e.at)+' · '+(e.clientID?nameFor(e.clientID)+' · ':'')+e.message;events.append(p);}if(!s.insights.events.length)events.textContent='No events recorded.';
}

async function refresh(){try{const r=await fetch('/api/status',{cache:'no-store',signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('HTTP '+r.status);render(await r.json());}catch(e){$('connection').className='status stale';$('connection').textContent='Connection lost · retrying';$('updated').textContent='Displayed data may be out of date';}finally{setTimeout(refresh,3000);}}
refresh();
</script></body></html>
"""#
