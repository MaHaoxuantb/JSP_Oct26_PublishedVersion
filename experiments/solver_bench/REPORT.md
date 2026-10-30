# JSP-Oct26-Regional-SA-BP

©2026 ThomasB

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

## Interim decision assessment

[2026-10-30, 11:31 JST — results and recommended next step](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/analysis/20261030-113122/ASSESSMENT.md>). This timestamped analysis does not stop or modify the live campaign.

## Final investigation - experiment stopped

Stopped at the user's request on 2026-10-30 at 12:07 JST. Final observed outcomes:
184 completed trials (39 solved, 145 timed out), eight interrupted attempts kept
separate, and 176 uncompleted jobs. The dataset is frozen for this assessment.

- [Shareable PDF report](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/output/pdf/JSP-Oct26-Regional-SA-BP-Final-Report.pdf>)
- [Offline HTML report](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/analysis/final-20261030-120757/JSP-Oct26-Regional-SA-BP-Final-Report.html>)
- [Full Markdown investigation](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/analysis/final-20261030-120757/JSP-Oct26-Regional-SA-BP-Final-Report.md>)
- [Evidence and reproducibility package](</Users/thomasb/Library/Mobile Documents/com~apple~CloudDocs/Documents/develop/JaneStreetPuzzle_Oct26/experiments/solver_bench/analysis/final-20261030-120757/JSP-Oct26-Regional-SA-BP-Evidence.zip>)

The report covers matched comparisons, board-level difficulty, real elapsed-time
trajectories, board-cluster uncertainty, resource use, independent validation,
known non-uniqueness, and the capital-rule audit for the clue 19. It supersedes
the interim assessment above; no additional trial was started for the report.
