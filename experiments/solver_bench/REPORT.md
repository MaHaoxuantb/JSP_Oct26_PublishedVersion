# Certified shared-framework campaign

The detached campaign started on 2026-10-29.

- [Live dashboard](http://127.0.0.1:62911)
- [Current generated report](</Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/20261029-214421/report/REPORT.md>)
- [Reusable framework and method](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/README.md>)
- [Pre-launch verification](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/VERIFICATION.md>)

The dashboard and generated report read the durable queue. The user waived uniqueness certification after preparation began. All 15 current
fixtures have checked solutions; three retain proven uniqueness and the remaining
solution counts are explicitly unknown. The 360 timed trials use those fixtures. Trial limits are
1,200 seconds; the six-hour preparation gate is a separate budget. No historical
measurements are pooled with this campaign.

Campaign files live outside iCloud at `/Users/thomasb/Library/Application Support/JaneStreetPuzzleBench/campaigns/20261029-214421`. Its frozen `source/bench.py`
provides `status`, `stop`, `start` (resume), and `report`; pass `--directory` with
the campaign path. The UI stays accessible after the controller finishes.
