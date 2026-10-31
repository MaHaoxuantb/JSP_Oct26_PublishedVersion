# JSP-Oct26-Experiment-Naming

©2026 ThomasB

## Required identity

Use the exact copyright notice **©2026 ThomasB** on experiment reports,
dashboards, exported documents, and other published experiment artifacts.
Use **ThomasB** as the author in document metadata.

Every experiment name must begin with **JSP-Oct26** followed by its experiment
name. Use this consistent form:

`JSP-Oct26-<ExperimentName>`

The `+` in `"JSP-Oct26" + ExperimentName` means concatenation; it is not a
literal plus sign in the name. Use hyphens to separate words in filenames.

## Search escape portfolio

- Full identity: **JSP-Oct26-Search-Escape**.
- Report: `experiments/search_escape/results/20261030-screen/JSP-Oct26-Search-Escape-Report.md`.
- Execution record: `experiments/search_escape/JSP-Oct26-Search-Escape-Run.md`.
- This continues the original-puzzle solve attempt; earlier comparison and continuation datasets remain separate.
- Stall investigation identity: **JSP-Oct26-Search-Escape-Stall**; report
  `experiments/search_escape/results/20261031-stall/JSP-Oct26-Search-Escape-Stall-Report.md`.
- Large-region continuation: **JSP-Oct26-Structural-Search**; report
  `experiments/search_escape/results/20261031-structural/JSP-Oct26-Structural-Search-Report.md`,
  run record `experiments/search_escape/JSP-Oct26-Structural-Search-Run.md`.

## Current experiment

- Full identity: **JSP-Oct26-Structural-Search**.
- Run: `experiments/search_escape/JSP-Oct26-Structural-Search-Run.md`.
- Report: `experiments/search_escape/results/20261031-structural/JSP-Oct26-Structural-Search-Report.md`.

## Earlier CPU8 completion experiment

- Experiment name: **CPU8-Completion**.
- Incumbent continuation: **JSP-Oct26-CPU8-Continuation**; run record `experiments/cpu8_completion/JSP-Oct26-CPU8-Continuation-Run.md`. The live harness retains the established **JSP-Oct26-CPU8-Completion** export identity and distinguishes continuation in its manifest/configuration.
- Full identity: **JSP-Oct26-CPU8-Completion**.
- Reports: `JSP-Oct26-CPU8-Completion-Report.md` and live read-only dashboard.
- Trial/data exports: `JSP-Oct26-CPU8-Completion-Trials.csv` and
  `JSP-Oct26-CPU8-Completion-Results.json`.
- Execution record: `experiments/cpu8_completion/JSP-Oct26-CPU8-Completion-Run.md`.

## Previous repair completion experiment

- Experiment name: **Repair-Completion**.
- Full identity: **JSP-Oct26-Repair-Completion**.
- Reports: `JSP-Oct26-Repair-Completion-Report.md` and
  `JSP-Oct26-Repair-Completion-Report.html`.
- Trial/data exports: `JSP-Oct26-Repair-Completion-Trials.csv` and
  `JSP-Oct26-Repair-Completion-Results.json`.
- Evidence bundle: `JSP-Oct26-Repair-Completion-Evidence.zip`.

## Previous experiment

- Experiment name: **Regional-SA-BP**.
- Full identity: **JSP-Oct26-Regional-SA-BP**.
- Report: `JSP-Oct26-Regional-SA-BP-Final-Report.pdf`.
- Markdown: `JSP-Oct26-Regional-SA-BP-Final-Report.md`.
- Offline page: `JSP-Oct26-Regional-SA-BP-Final-Report.html`.
- Evidence bundle: `JSP-Oct26-Regional-SA-BP-Evidence.zip`.
- Other public exports: `JSP-Oct26-Regional-SA-BP-<ArtifactName>.<extension>`.

Apply this identity to report cover titles, PDF titles, dashboard branding,
browser titles, chart/figure exports, download labels, filenames and bundles.
Do not use unrelated substitute brands such as “Solver Lab”. Section headings
and descriptions may remain descriptive prose.

## Placement and preservation

- PDF: copyright on every page, full experiment identity in the title and footer,
  and author `ThomasB` in metadata.
- HTML/dashboard: full identity in the visible header and browser title;
  copyright in the page footer.
- Markdown: full identity in the main heading and copyright directly below it.
- Machine-readable exports: retain existing schemas; include identity and
  copyright in the accompanying manifest when embedding metadata would change
  the format (for example, CSV).
- Preserve durable run IDs, board IDs, job IDs, original frozen source, existing
  checkpoints, and immutable raw observations. Branding changes must not alter
  experimental results or break historical reproducibility. Update links when
  publishing renamed artifacts.

Use the same naming pattern for future experiments, replacing only
`<ExperimentName>`. These are project-wide publication requirements, not changes
to the solver's release or wire-protocol version.
