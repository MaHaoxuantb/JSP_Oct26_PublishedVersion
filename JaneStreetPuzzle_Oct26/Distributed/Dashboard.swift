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
<section class="panel" aria-labelledby="clientHeading"><div class="panel-heading"><div><h2 id="clientHeading">Compute clients</h2><p>Machines connected to your coordinator.</p></div><span class="count" id="clientCount">— clients</span></div>
<div class="table-wrap"><table><thead><tr><th scope="col">Client ID</th><th scope="col">Connection</th><th scope="col">Last heartbeat</th><th scope="col">Jobs</th></tr></thead><tbody id="clientRows"><tr><td colspan="4" class="empty">Waiting for status…</td></tr></tbody></table></div></section>
<section class="panel" aria-labelledby="jobHeading"><div class="panel-heading"><div><h2 id="jobHeading">Worker assignments</h2><p>Latest reported progress. Worker slots start at zero.</p></div><span class="count" id="jobCount">— jobs</span></div>
<div class="table-wrap"><table><thead><tr><th scope="col">Client / slot</th><th scope="col">Job</th><th scope="col">State</th><th scope="col">Objective</th><th scope="col">Progress</th><th scope="col">Reported time</th></tr></thead><tbody id="jobRows"><tr><td colspan="6" class="empty">Waiting for status…</td></tr></tbody></table></div></section>
<footer><span>© 2026 ThomasB, LinecoFlow LLC</span><p><svg aria-hidden="true" viewBox="0 0 24 24"><path d="m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6Z"/><path d="m8 12 3 3 5-6"/></svg><span id="backup">Backup status pending.</span></p><div class="run-meta"><span>Run</span><span id="run">Connecting…</span></div></footer><noscript><p>Enable JavaScript to view live process status.</p></noscript>
</main><script>
const $=id=>document.getElementById(id), number=n=>n.toLocaleString(), short=id=>id.slice(0,8);
document.querySelectorAll('[data-theme-option]').forEach(button=>button.addEventListener('click',()=>{
 themePreference=button.dataset.themeOption;
 try{localStorage.setItem('puzzle-theme',themePreference);}catch{}
 applyTheme();
}));
applyTheme();
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
 $('run').textContent=short(s.runID);$('run').title=s.runID;
 $('clientCount').textContent=number(s.clients.length)+' '+(s.clients.length===1?'client':'clients');
 $('jobCount').textContent=number(s.jobs.length)+' '+(s.jobs.length===1?'job':'jobs');
 $('clients').textContent=number(s.clients.filter(c=>c.connected).length);
 $('jobs').textContent=number(s.jobs.filter(j=>j.status==='assigned'||j.status==='reconnecting').length);
 $('completed').textContent=number(s.completedJobs);$('reassignments').textContent=number(s.reassignments);
 $('connection').className='status';$('connection').textContent=s.solved?'Solution validated':(s.clients.some(c=>c.connected)?'Search in progress':'Waiting for clients');
 $('updated').textContent='Updated '+new Date().toLocaleTimeString();
 const clients=$('clientRows');clients.replaceChildren();
 for(const c of s.clients){const row=document.createElement('tr');const id=cell(row,short(c.id));id.title=c.id;id.className='identifier';badge(row,c.connected?'Connected':'Offline',c.connected?'active':'');cell(row,age(c.lastSeenSeconds));cell(row,number(c.assignedJobs));clients.append(row);}
 if(!s.clients.length)empty(clients,4,'Ready when you are','Connect a compute client to start processing.');
 const jobs=$('jobRows');jobs.replaceChildren();
 for(const j of s.jobs){const row=document.createElement('tr');const client=cell(row,short(j.clientID)+' / '+j.slot);client.className='identifier';client.title=j.clientID;const id=cell(row,short(j.id)+' · g'+j.generation);id.title=j.id;id.className='identifier';
 badge(row,j.status,j.status==='assigned'?'active':j.status==='stopped'?'':'waiting');cell(row,j.objective+(j.explorer?' · explorer':''));const p=cell(row,'');const bar=document.createElement('progress');bar.max=j.budget;bar.value=j.completed;bar.setAttribute('aria-label','Job '+short(j.id)+' progress');p.append(bar,document.createTextNode(number(j.completed)+' / '+number(j.budget)));cell(row,j.reportedSeconds.toFixed(1)+'s');jobs.append(row);}
 if(!s.jobs.length)empty(jobs,6,s.solved?'Solution found':'No work assigned yet',s.solved?'The coordinator has independently validated the solution.':'Worker assignments will appear here as clients join.');
 $('backup').textContent=s.backupAgeSeconds==null?'No completed backup in this server session.':'Last completed backup '+age(s.backupAgeSeconds)+'.';
}
async function refresh(){try{const r=await fetch('/api/status',{cache:'no-store',signal:AbortSignal.timeout(8000)});if(!r.ok)throw Error('HTTP '+r.status);render(await r.json());}catch(e){$('connection').className='status stale';$('connection').textContent='Connection lost · retrying';$('updated').textContent='Displayed data may be out of date';}finally{setTimeout(refresh,3000);}}
refresh();
</script></body></html>
"""#
