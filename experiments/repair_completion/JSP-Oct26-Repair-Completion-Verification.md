# JSP-Oct26-Repair-Completion — pre-launch verification

©2026 ThomasB

Prepared 2026-10-30. Smoke measurements below are excluded from the real campaign.

- Isolated optimized Swift builds: shared-engine completion worker and CPU-only
  current-production adapter. No installed executable was overwritten.
- Twelve shared Swift tests passed, including integer rules, the example answer,
  shape-domain checks and bound/certification tests. Two repair-policy tests passed:
  complete connected region scopes and persistence beyond two unsuccessful slices.
- A real temporary queue completed 20 two-second trials spanning all five methods,
  four concurrent processes, with all 20 correctly recorded as timeouts. Every
  result passed the independent Python integer-rule checker and deadline checks.
- Initial exact quality matched across A–D for each smoke fixture and seed.
  Observed worker CPU/wall ratios ranged from 0.985 to 0.997 in the smoke queue.
- The production adapter's preflight confirmed authority software version 2,
  default minimum peer version 2, strict acceptance of version 2 and rejection of
  older version 1, explicit transitional acceptance of unversioned peers at
  minimum 0, and rejection of future version 3. Wire schemas are unchanged.
- Python modules compiled, browser JavaScript parsed, and the live smoke dashboard
  rendered its actual counts, tables and measured energy curves in the in-app
  browser. The generated offline HTML/Markdown/CSV/JSON and final ZIP were checked;
  ZIP integrity passed and the smoke report used its actual two-second cap.
- Multiple read-only Mini connection attempts failed: the numeric address
  192.168.4.173 returned “No route to host”; ThomasBs-Mini.lan closed the SSH
  connection. The approved local fallback is 20 full trials on four processes.

Reproduction uses the source/binary hashes and host metadata frozen by prepare.py.
The real run gets a new host-local queue; preflight files remain in a separate
scratch directory. Its real trial limit is 1,200 seconds, with a fixed campaign
window and separate statuses for interruptions, failures and skipped work.

## Mini verification and admission

At 2026-10-30 20:08:21 JST, native Swift 6.1.2 release builds were admitted after standalone
policy assertions and 20 two-second real-process trials passed. The Mini's
Command Line Tools installation lacks XCTest; this is recorded rather than
claiming the XCTest suite ran there. Frozen Swift search-source hashes match the
local campaign, and the frozen shape-store SHA-256 matches. Fifteen timed jobs
were launched on four processes, within the original campaign deadline. The
combined UI was checked and showed 35 trials, both hosts and eight running
processes with no exceptions at admission.
