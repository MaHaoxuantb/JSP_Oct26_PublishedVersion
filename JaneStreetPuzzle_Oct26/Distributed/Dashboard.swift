import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

struct DashboardClient: Codable, Sendable {
    let id: UUID
    let connected: Bool
    let lastSeenSeconds: Double?
    let assignedJobs: Int
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
    let runID: UUID
    let solved: Bool
    let completedJobs: UInt64
    let reassignments: UInt64
    let backupAgeSeconds: Double?
    let clients: [DashboardClient]
    let jobs: [DashboardJob]
}

/// Separate HTTP listener: browser traffic never enters the authenticated worker protocol.
func startDashboard(settings: DistributedConfig, coordinator: Coordinator,
                    group: MultiThreadedEventLoopGroup) async throws -> (any Channel)? {
    guard settings.webUIEnabled else { return nil }
    let address = try numericAddress(settings.webUIAddress, port: settings.webUIPort)
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
                    IdleStateHandler(readTimeout: .seconds(10)), DashboardHTTP(coordinator: coordinator))
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch { return channel.eventLoop.makeFailedFuture(error) }
        }.bind(to: address).get()
}

final class DashboardHTTP: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    private let coordinator: Coordinator
    private var head: HTTPRequestHead?
    private var responding = false
    init(coordinator: Coordinator) { self.coordinator = coordinator }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responding else { return }
        switch unwrapInboundIn(data) {
        case .head(let request): head = request
        case .body:
            // Monitoring is GET-only and never accepts request bodies.
            responding = true
            respond(on: context.channel, status: .badRequest, type: "text/plain", body: Data("Request body is not supported.".utf8))
        case .end:
            responding = true
            guard let head else { context.close(promise: nil); return }
            let channel = context.channel
            guard head.method == .GET else {
                respond(on: channel, status: .methodNotAllowed, type: "text/plain", body: Data("Use GET.".utf8)); return
            }
            switch head.uri {
            case "/":
                respond(on: channel, status: .ok, type: "text/html; charset=utf-8", body: Data(dashboardHTML.utf8))
            case "/api/status":
                Task {
                    let snapshot = await coordinator.dashboard()
                    do {
                        let data = try JSONEncoder().encode(snapshot)
                        channel.eventLoop.execute { self.respond(on: channel, status: .ok, type: "application/json", body: data) }
                    } catch {
                        channel.eventLoop.execute { self.respond(on: channel, status: .internalServerError, type: "text/plain", body: Data("Status unavailable.".utf8)) }
                    }
                }
            default:
                respond(on: channel, status: .notFound, type: "text/plain", body: Data("Not found.".utf8))
            }
        }
    }

    private func respond(on channel: any Channel, status: HTTPResponseStatus, type: String, body: Data) {
        var headers = HTTPHeaders([
            ("Content-Type", type), ("Content-Length", String(body.count)), ("Connection", "close"),
            ("Cache-Control", "no-store"), ("X-Content-Type-Options", "nosniff"),
            ("Content-Security-Policy", "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        ])
        if status == .methodNotAllowed { headers.add(name: "Allow", value: "GET") }
        channel.write(HTTPServerResponsePart.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)), promise: nil)
        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
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
<title>Puzzle coordinator · Processes</title>
<style>
:root{color-scheme:dark;--muted:#9daec2;--line:#2a3b50;--accent:#7be0b7}
*{box-sizing:border-box}body{margin:0;background:#101923;color:#e8eef5;font:15px/1.6 system-ui,sans-serif}
main{max-width:1320px;margin:auto;padding:40px 28px}header{display:flex;justify-content:space-between;gap:24px;align-items:center}
h1{font-size:30px;letter-spacing:-.7px;line-height:1.2;margin:6px 0 12px}h2{font-size:19px;margin:28px 0 10px}
p{margin:5px 0;color:var(--muted)}.eyebrow{text-transform:uppercase;letter-spacing:2px;font-size:11px;color:var(--accent)}
#connection{color:var(--accent)}#connection.stale{color:#ffb692}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:14px;margin:30px 0}
.card{padding:18px 22px;background:#182635;border:1px solid var(--line);border-radius:10px}.card span{color:var(--muted);font-size:13px}.card strong{display:block;font-size:30px;font-weight:600}
.table-wrap{overflow-x:auto;border:1px solid var(--line);border-radius:10px}table{border-collapse:collapse;width:100%;white-space:nowrap;text-align:left}
th,td{padding:13px 18px;border-bottom:1px solid var(--line)}th{color:var(--muted);font-size:12px;font-weight:500;background:#182635}tbody tr:last-child td{border:0}
code{font:12px ui-monospace,monospace;color:#bed0e4}.state{color:var(--accent)}progress{width:90px;accent-color:var(--accent);margin-right:8px;vertical-align:middle}
.empty{text-align:center;color:var(--muted);padding:32px}footer{color:var(--muted);font-size:12px;margin-top:24px}#run{overflow-wrap:anywhere}
@media(max-width:680px){main{padding:24px 16px}header{display:block}.cards{grid-template-columns:repeat(2,1fr)}h1{font-size:26px}}
</style></head><body><main>
<header><div><div class="eyebrow">Jane Street · October 2026</div><h1>Coordinator processes</h1><p id="run">Connecting to coordinator…</p></div>
<div><div id="connection" role="status" aria-live="polite">Connecting…</div><p id="updated">Refreshes every 3 seconds</p></div></header>
<section class="cards" aria-label="Run statistics">
<div class="card"><span>Connected clients</span><strong id="clients">—</strong></div>
<div class="card"><span>Assigned jobs</span><strong id="jobs">—</strong></div>
<div class="card"><span>Completed jobs</span><strong id="completed">—</strong></div>
<div class="card"><span>Reassignments</span><strong id="reassignments">—</strong></div></section>
<h2>Compute clients</h2><div class="table-wrap"><table><thead><tr><th>Client ID</th><th>Connection</th><th>Last heartbeat</th><th>Jobs</th></tr></thead><tbody id="clientRows"><tr><td colspan="4" class="empty">Waiting for status…</td></tr></tbody></table></div>
<h2>Worker assignments</h2><p>Latest reports received by the coordinator. Worker slots are numbered from zero.</p>
<div class="table-wrap"><table><thead><tr><th>Client / slot</th><th>Job</th><th>State</th><th>Objective</th><th>Progress</th><th>Reported time</th></tr></thead><tbody id="jobRows"><tr><td colspan="6" class="empty">Waiting for status…</td></tr></tbody></table></div>
<footer id="backup">Backup status pending.</footer><noscript><p>Enable JavaScript to view live process status.</p></noscript>
</main><script>
const $=id=>document.getElementById(id), number=n=>n.toLocaleString(), short=id=>id.slice(0,8);
const age=n=>n==null?'Not seen since restart':Math.floor(n)+'s ago';
function cell(row,text,tag='td'){const el=document.createElement(tag);el.textContent=text;row.append(el);return el;}
function empty(body,columns,text){const row=document.createElement('tr'),el=cell(row,text);el.colSpan=columns;el.className='empty';body.append(row);}
function render(s){
 $('run').textContent='Run '+s.runID;
 $('clients').textContent=number(s.clients.filter(c=>c.connected).length);
 $('jobs').textContent=number(s.jobs.filter(j=>j.status==='assigned'||j.status==='reconnecting').length);
 $('completed').textContent=number(s.completedJobs);$('reassignments').textContent=number(s.reassignments);
 $('connection').className='';$('connection').textContent=s.solved?'Solution validated':'Live · '+(s.clients.some(c=>c.connected)?'searching':'waiting for clients');
 $('updated').textContent='Updated '+new Date().toLocaleTimeString();
 const clients=$('clientRows');clients.replaceChildren();
 for(const c of s.clients){const row=document.createElement('tr');cell(row,c.id,'td');cell(row,c.connected?'Connected':'Offline');cell(row,age(c.lastSeenSeconds));cell(row,number(c.assignedJobs));clients.append(row);}
 if(!s.clients.length)empty(clients,4,'No clients connected. Start a compute client to begin work.');
 const jobs=$('jobRows');jobs.replaceChildren();
 for(const j of s.jobs){const row=document.createElement('tr');cell(row,short(j.clientID)+' / '+j.slot);const id=cell(row,short(j.id)+' · g'+j.generation);id.title=j.id;
 cell(row,j.status).className='state';cell(row,j.objective+(j.explorer?' · explorer':''));const p=cell(row,'');const bar=document.createElement('progress');bar.max=j.budget;bar.value=j.completed;bar.setAttribute('aria-label','Job progress');p.append(bar,document.createTextNode(number(j.completed)+' / '+number(j.budget)));cell(row,j.reportedSeconds.toFixed(1)+'s');jobs.append(row);}
 if(!s.jobs.length)empty(jobs,6,s.solved?'The coordinator has validated a solution.':'No worker assignments yet.');
 $('backup').textContent=s.backupAgeSeconds==null?'No completed backup in this server session.':'Last completed backup '+age(s.backupAgeSeconds)+'.';
}
async function refresh(){try{const r=await fetch('/api/status',{cache:'no-store',signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('HTTP '+r.status);render(await r.json());}catch(e){$('connection').className='stale';$('connection').textContent='Connection lost · retrying';$('updated').textContent='Displayed data may be out of date';}finally{setTimeout(refresh,3000);}}
refresh();
</script></body></html>
"""#
