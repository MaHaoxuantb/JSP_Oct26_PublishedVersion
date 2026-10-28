# Integrity and search-limit audit — 2026-10-28

**Historical findings, now corrected locally.** The audit found a reproducible
search regression, an odd-only large-state lane, and catalog progress limitations.
The three findings have since been corrected with regression tests; see
[corrections and validation](INTEGRITY_FIXES.md). The sections below preserve the
pre-fix observations. Re-running the diagnostic writes the latest results, not
the historical failing output. Deployment and worker restarts remain on hold.

This was an investigation. No production source, deployed binary, running worker,
coordinator database or live configuration was modified. Only diagnostic sources,
results and audit documentation were added or updated.

## Rechecking the question

A valid partition must cover every cell exactly once with orthogonally connected
states. Holes are allowed. Every state needs a nonidentity symmetry; a state may
have no capitol. A capitol exists only when **every** nonidentity symmetry fixes
exactly one square, and it is the same square in all those symmetries. An
intersection of fixed sets is not sufficient.

On a finite union of grid-aligned unit squares, the seven translated nonidentity
D4 transformations cover the possible rotations/reflections. A valid symmetry
must preserve the rectilinear boundary directions. Translations and glide
reflections cannot preserve a finite nonempty state.

For all orthogonal edges, `w(u,v)=min(s(u),s(v))`. This includes internal edges.
The distance is the cheapest path to **any** capitol; it may cross borders or
reenter states. Numbered values are distances, not areas. Blank cells can be
capitols. Large even-area states are legal, although a state with a capitol has
odd area. No number of states, preferred symmetry, or 37-cell state is stipulated
by the question.

The singleton and short-path bounds added recently are necessary conditions on
finished solutions. The distinction missed in the implementation is that a
locally improved board can still violate such a condition in an exterior region
that another move must repair later.

## 1. [P1] Cross-state hard pruning blocks improving local repairs

**Introduced by the recent changes.** Location:
`RegionRepairs.swift:283–292`, used unconditionally by `cover`.

The pair-area check requires fixed exterior states and newly assigned patch
states to satisfy necessary final-board bounds before evaluating the candidate.
An exterior state may already violate a clue and require a later repair. The
hard check can therefore reject every cover of a patch even when it contains a
substantial improvement over the current board.

Reproduction, one-based rows/columns, with `.` for an unspecified clue:

```text
clues            source labels     improving labels
. 1 3            A B B             A A B
. . 1            A C B             C D B
0 1 3            C C D             C C E
```

The patch is the first eight cells; r3c3 is fixed outside it. The reference search
uses exactly the same supplied shape catalog, completed-shape filters, and
one-clue requirements, with only cross-state pair-area pruning omitted. Both
searches have ample work limits, no wall-clock deadline, and route pruning off.

- Source: **5 wrong clues**, mean normalized error **0.7777777778**.
- Reference patch cover: **1 wrong clue**, error **0.1666666667**.
- Current production `cover`: **nil**, no move.
- The clue set has a fully valid solution; it was derived from one, which is
  recorded in `integrity-results.json`.

In the improved board, r2c2 and r3c3 are both singletons. The former is a correct
capitol; the latter is the remaining wrong clue. The derived bound requires their
areas to sum to at least 3, while the temporary board has 1+1. This correctly says
the board is unfinished; it does not justify losing the five-to-one improvement.

**Correction:** use hard cross-state feasibility bounds in a strict feasibility
search, and preserve a repair mode that can improve an imperfect board. For local
repairs, remove this unconditional rejection or turn it into a properly justified
objective lower bound. Retain the independent validator for success. Preserve
this reproduction as a regression test requiring the improved move to survive.

This is a search-integrity defect, not a false-solution acceptance defect. It can
reduce exploration and cause plateaus without excluding the known solution when
that entire solution is supplied at once.

## 2. [P2] The new large-state archive has a parity bias and competes for the old lane's time

**Introduced by the recent changes.** Locations:
`ShapeGrowth.swift:276–295` and `RegionRepairs.swift:428–434`.

The archive is populated only from `growCapitolShapes`. Each such walk starts
with one anchor and adds orbits of two or four squares. Consequently **every
archived state has odd area**. Some emitted states can still be capless because
they acquire additional symmetries, but an even-area state can never enter this
archive through the current population path.

The puzzle allows large even states. An independently validated counterexample
is a 1×37 board with a 36-cell bar and a singleton at its end: clues 1261 at the
opposite end and 0 at the singleton are correct (`35×36+1=1261`). The 36-cell bar
has no capitol and exceeds the normal 32-cell patch allowance.

Other move types can still construct even large states. This is **not** proof
that the entire solver can never reach them. It is a restriction in the new
dedicated lane. All archived states in the measured local probes were odd.

The new lane also receives the entire large-turn deadline. It can spend time on
growth and up to four rebuilds before the former generic large-patch route gets
its turn. There is no separately reserved budget for that fallback.

In the final bounded historical-checkpoint comparison, both the new route and a
control giving the former large-patch route the whole deadline returned one
proposal over 16 large turns at the default 0.15-second budget. Cover-node counts
were 341 and 272, respectively. Repeated wall-clock-bounded runs varied, so this
comparison establishes neither a net speedup nor a net slowdown. The code has
budget competition, but claiming that the fallback is always suppressed or that
this probe proves a performance regression would overstate the evidence.

**Correction:** keep an independently scheduled general large-patch lane with a
reserved budget. Populate a separate large-shape pool from both anchored growth
and generic capless/even-state generation. Compare compatible completed proposals
and clue improvements, not only individually permitted shape counts.

## 3. [P2] A full catalog permanently stops admitting new candidates

**Pre-existing behavior retained by the recent changes.** Location:
`RegionRepairs.swift:216–235`.

`result` starts with the cached catalog. `add` refuses candidates at the capacity
limit, and generic sampling is skipped while the catalog is full. No candidate
replacement occurs. Every eighth request can nominally augment the catalog, but
a full catalog is frozen. Anchored growth may still consume work while all its
outputs are refused.

A valid low-budget configuration (`catalogCandidateLimit=2`) reproducibly retains
only `[[0],[1]]` on an otherwise unconstrained 3×3 patch with a central zero. After
16 more requests it is unchanged, does not cover all cells, and no generic cursor
has been created. The same admission condition applies when the default 12,000
limit is eventually reached; the diagnostic does not establish how frequently
that happens on deployed workers.

**Correction:** on augmentation, reserve space or replace a bounded fraction of
nonessential candidates while protecting required cell coverage and useful
existing shapes. A fixed memory limit need not imply permanent discovery freeze.

## Other limitations the changes do not remove

| Restriction | Effect |
|---|---|
| Ordinary patches: 32 cells | Cannot rebuild a whole 37-cell state. |
| Generic large patches: up to eight current states, within 128 cells | A collection of many tiny states may not expose a large enough repair window. The new anchored lane can span more current states, but has the bias above. |
| Merges: at most four regions | Some useful unions require a larger simultaneous move or another proposal type. |
| Generic cursor cache: eight patches; catalog cache: 64 patches | Progress can be evicted while its catalog remains cached. Nine distinct patch requests reproduce a cursor reset on returning to the first patch. |
| Full catalog capacity | New candidates can remain excluded indefinitely. |
| Sample, node, cover and time limits | A failed attempt is not an impossibility or uniqueness proof. |
| Hard necessary-condition filters on proposed states | Correct for final states, but can remove intermediate steps from a local-search trajectory. No connectivity/ergodicity proof exists for the move graph. |
| Large archive: 512 shapes | FIFO replacement can discard useful shapes before a compatible surrounding partition appears. |
| Wall-clock deadlines and shared archive arrivals | Seeds alone do not reproduce entire concurrent runs. |

These restrictions do not demonstrate that the 408951 solution is unreachable.
They do mean broader candidate generation by itself does not guarantee an easier
search. The earlier discovery benchmark counts permitted individual states, many
of which cannot coexist in a valid full partition.

## Integrity checks and scope

The source review covered the first-party core model, geometry, scoring,
candidate generation, cover/merge/boundary repairs, search lifecycle and archives,
configuration, snapshots/log recovery, CPU and GPU distance paths, distributed
ownership/reporting, persistence, TLS, backups, and dashboard management paths.
Third-party dependency internals and deployed binaries were not audited.

Checks on the current production source:

- **63 Swift package tests in 10 suites passed** again.
- **All six standalone core suites passed** again.
- Exhaustively enumerated **974** partitions of the 3×3 grid into connected
  symmetric states. The **943** with capitols supplied **3,772** full/sparse clue
  fixtures. No new per-state deduction or pair-bound false exclusion was found.
- Compared the cached geometry against `ExactValidator` on **all 65,535 nonempty
  4×4 masks**, including disconnected/asymmetric masks. No disagreement was found
  about validity or the selected state's capitol.
- Tested **2,258** additional 4×4 full/sparse deduction fixtures, using a symmetric
  state plus singleton exterior states. No false rejection was found.
- The known full-puzzle acceptance fixture remains valid with all 33 clues,
  eight capitols and answer 408951.
- Reproduced the partial-repair regression, catalog saturation, odd-only archive,
  and cursor eviction separately from these passing tests.

The distance implementation consistently uses `min` on border edges and
multi-source shortest paths. The independent final validator remains the gate
for declaring a solution. GPU output has a positive-distance predecessor and
triangle-inequality certificate, with CPU fallback; the package suite exercises
Metal on this host. CUDA hardware and the deployed fleet were not available to
this local audit. Passing these checks is not a proof of every runtime behavior,
nor a fresh 11×11 search or uniqueness proof.

The distributed code retains serial ownership commits, generation/budget checks,
durable checkpoint writes, pinned TLS identity, and separate dashboard admin
authorization. No additional reproduced defect was found in those reviewed
paths. That is narrower than a security certification or a live-deployment audit.

## Reproduce and recommended order

```sh
python3 investigation/run_integrity_audit.py
swift test -c release --skip-update
python3 Scripts/run_core_tests.py
```

The first command compiles a temporary CPU-only diagnostic and writes
`integrity-results.json`. It reads one historical checkpoint for the bounded
portfolio comparison; that section is skipped if the checkpoint is unavailable.
The mathematical and pruning reproductions do not depend on that checkpoint.

Before deployment: fix the local-repair pruning regression; preserve an
independent general large-state lane; allow bounded catalog replacement; then
measure fresh-search progress across multiple seeds. Keep correctness fixtures,
candidate discovery, compatible repair proposals, and end-to-end solve results
as distinct measurements. Deployment remains on hold.
