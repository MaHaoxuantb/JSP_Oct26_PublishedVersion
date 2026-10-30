# Pre-launch verification — 2026-10-29

- Swift release build in `/private/tmp/puzzle-bench-native`, separate from installed workers.
- 12 Swift tests passed, including exhaustive subset comparisons through 4×4,
  cached/uncached enumeration, exact-cover checkpoint round trips and pruning equivalence.
- Seven Python tests passed, including a real temporary campaign completing all eight
  conditions, certificate admission, independent validation, gate enforcement and retries.
- A separate process test passed: live process adoption after controller recovery, then
  explicit stop, with exactly one attempt retained and the job requeued as interrupted.
- Real 5×5 and 9×9 preparation checkpoints resumed in separate temporary directories;
  incomplete counts stayed unproven. These fixtures never enter the campaign.
- Four simultaneous 12-second resource preflights (N=5/9, discrete/continuous) measured
  approximately 11.94 CPU seconds each. These deliberately inconsistent test inputs
  exercise deadlines, logging and BP; they are not solver performance measurements.
- Cache orientation/placement reuse removed repeated work without changing enumerated
  candidate sets. The final N=9 resource check recorded 12.002 wall seconds and
  11.953 CPU seconds. This is a resource check, not a benchmark result.
- Browser checked the actual miniature campaign: 8/8 terminal measurements, eight
  real curves, timestamps and representation filtering (8 rows → 4 continuous rows).
  HTTP checks cover snapshots, individual samples/candidates, CSV, certificate and
  Markdown exports. Empty primary charts remain empty until real searches start.

No production source, release number, executable, credential or durable run state was
modified. Historical experiments were not rerun. Reproduction commands and practical
limitations are in README.md.
