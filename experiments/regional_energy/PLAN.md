# Energy-guided regional randomization experiment

Status: implementation and one-seed eight-condition pilot authorized. The user
subsequently selected a 300-second cutoff for each run.
The earlier runs remain stopped. Implementation and builds belong in this
experiment directory and isolated scratch folders; installed workers, production
source, release versions, live state and credentials are outside this experiment.

## Question and primary comparison

Does using the current candidate's spatial energy to choose both the location and
breadth of a random change improve time to an independently verified solution?

The primary comparison is regional ON versus OFF **within each representation**.
The full design has eight conditions:

| Board | Representation | Regional adaptation |
|---|---|---|
| 5x5 | discrete | off / on |
| 5x5 | continuous | off / on |
| 7x7 | discrete | off / on |
| 7x7 | continuous | off / on |

Use a shared experiment harness with explicit representation-specific mutation
adapters. Do not compare a modified historical annealer with an otherwise
unmodified production repair engine and attribute that difference to regional
adaptation. Candidate generation, acceptance, initialization, restarts, validation
and bookkeeping must be identical between ON/OFF within a representation.
Cross-representation results compare the whole methods, not arithmetic type alone.
The primary harness need not reproduce the full production repair/catalog solver;
keep the previous production results as a separate reference.

## Fixed puzzles and starting states

Reuse the final sparse fixtures from
`../discrete_vs_continuous/until_solved/fixtures.json`:

- 5x5: `example5_clues7`, exactly 7/25 clues = 28.00%.
- 7x7: `generated7_7101_clues13`, exactly 13/49 = 26.53%.
- Reference density: original 11x11 has 33/121 = 27.27%.

Freeze the fixture JSON, hashes and complete witness partitions before running.
Witnesses are available only to fixture validation, never to proposal generation,
initialization, field construction or acceptance. These are known satisfiable,
not proven unique; valid alternative partitions and answer sums count.

Start each matched pair from the same seeded connected partition. Discrete edges
are canonical binary relationships; continuous edges start at 0.1/0.9 for the
same topology. Across ON/OFF the actual initial representation is identical.
Decode continuous relationships using the existing 0.5 threshold. Connectivity
and final puzzle validity are always checked independently.

## Distribution and adaptation rule

Draw independent U_j uniformly from [-1,1] and use

    z_n = (U_1 + ... + U_n) / n.

E[z_n] = 0 and Var(z_n) = 1/(3n). Thus n=1 is uniform; larger n concentrates
changes near zero. The standard deviation at n=1 is four times that at n=16.
Do not multiply by sqrt(n), which would remove the intended variance change.

OFF:

- Choose the focus cell uniformly over the board.
- Use n=8 everywhere, independent of the energy field.

ON:

1. Construct the localization field below from the current candidate.
2. Smooth it with one fixed, normalized orthogonal-neighbor averaging pass.
3. Scale non-flat fields to hotness h_i in [0,1] using their board min/max.
   If the range is below 1e-12, use uniform focus and n=8, exactly as OFF.
4. Choose focus cell i with probability

       P(i) = 0.20/N + 0.80 * (0.05 + h_i) / sum_j(0.05 + h_j).

5. Set n_i = clamp(round(16 - 15*h_i), 1, 16).

Hot regions therefore receive more proposals and broader changes. Every cell
retains a positive exploration probability. The field is computed for both arms,
including OFF, so the ON/OFF timing difference does not merely reflect omitted
field work. Recompute it after every accepted state/topology change; never use a
field from the saved best board to mutate a different current board.

The ON/OFF contrast tests the combined location-and-breadth policy. It does not
by itself separate the contribution of focus bias from step width. A later
shuffled-hotness control can test whether any benefit is simply greater global
aggressiveness, without expanding the primary eight-condition pilot.

## A field with actual spatial information

The retained continuous API fills blank cells with the global mean clue error.
That is useful for its scalar score but can make a localization field flat.
Do not use that blank-cell fill as evidence of a local hot spot.

Build a separate guidance field, leaving the scalar objectives unchanged:

- A: each numbered cell's own normalized clue error. Spread those clue errors
  through a fixed Manhattan-radius-2 kernel exp(-distance/2), normalized over
  contributing clue cells; use zero if no clue contributes.
- S: the representation's per-cell symmetry/structural energy.
- Q: existing per-cell relationship uncertainty energy, zero for binary edges.
- Guidance field F = (2*A_local + S + 2*Q)/5, then the single smoothing pass above.

For continuous A, read the existing approximate AIM values only at actual clue
cells. For discrete A, use exact integer-distance clue residuals. No witness
information is used. Keep this guidance field separate from the raw/native score
and the common exact diagnostic energy in logs.

A bad travel clue can be caused away from its own cell. Radius-2 spreading is a
fixed initial localization heuristic, not a proof of causal attribution. Global
exploration and occasional shared restarts retain access to distant changes.

## Turning breadth into meaningful mutations

Sample z_n for spatial extent, then independent z_n values for individual numeric
changes. Let L be board side length and M the number of mutable relationships in
the selected connected patch.

    radius = min(L-1, 1 + floor((L-1)*abs(z_n)))
    Kmax = min(M, ceil(total_board_edges/4))
    requested edits = min(Kmax, 1 + floor(Kmax*abs(z_n)))

Use connected patches clipped to the board, with at least one legal mutation.
Large draws can span the board. Record requested and realized radius/edit counts;
clipping and connectivity repairs must not be mistaken for large actual changes.

Continuous adapter:

- Apply p' = reflect_into_[0,1](p + z_n) to selected relationships.
- Use independent signs/draws per selected relationship, avoiding an accidental
  coherent same-direction push across the entire patch.
- A fixed 10% of relationship mutations propose an endpoint 0 or 1 instead.
  Keep this identical in ON/OFF; it gives exact endpoints nonzero proposal mass.
- Reflection avoids clipping silently creating extra endpoint mass.

Discrete adapter:

- Use the draw's magnitude to select how many boundary cells/relationships to
  alter, using patch relabel/split/merge operations and rebuilding components.
- Encode the resulting partition as canonical 0/1 relationships.
- Do not merely take sign(z_n) or round it to a bit: a symmetric draw's sign is
  50/50 for every n, which would erase the intended distribution experiment.
- Detect topology-identical proposals and log them as no-ops; do not silently
  present them as productive evaluated moves.

The mutation families are fixed before the pilot and are unchanged ON/OFF.
A change to patch relationships can affect distant states or shortest routes.
Recompute the **whole board** score and validation after a proposal; regional
proposal generation does not justify stale or patch-only shortest-path scoring.

## Stronger continuous discreteness term

Use continuous weights (AIM, symmetry, discreteness) = (2, 1, 2), fixed for both
regional ON and OFF. The previous tuple was (2, 1, 0.25): this is an eightfold
increase in the relative discreteness factor, raising its normalized share from
7.69% to 40%. Keep the existing uncertainty formula unchanged.

Discrete relationships have Q=0. Normalize its native scalar over its active
terms, (2*A + S)/3. Native cross-representation totals are not directly comparable.
Use the same initial temperature and schedule within each ON/OFF pair. Log the
actual normalized energy delta and acceptance probability to identify temperature
or strong-discreteness barriers rather than infer them from total energy alone.

Increased discreteness weight does not repair the previously observed preference
for an asymmetric state by itself. Retain the common exact diagnostics below and
never equate a low surrogate score with a solution. Do not quietly introduce a
new geometric penalty only in the regional arm.

## Randomness and fair comparison

Use separate deterministic channels for initialization, focus selection, extent,
per-edge updates, acceptance and restarts. Index draws by seed/proposal/channel.
Draw 16 uniforms for each averaged draw and use the first n, in both arms. Changing
n then does not shift later acceptance/focus random numbers solely by consuming
more RNG values. Trajectories can still diverge through real acceptance decisions.

One CPU worker per search, CPU paths, identical build flags, cache limits and
instrumentation. Balance/reverse ON/OFF execution order across seeds. Keep host
concurrency/load equal for compared pairs; avoid comparing an idle-host run with
one sharing the machine with several unrelated experiment jobs. Compilation is
excluded; candidate initialization, field updates, scoring and validation are
included in measured search wall time. Record CPU time as a secondary diagnostic.

## What to record and compare

Primary outcome: real elapsed seconds until any proposed candidate passes the
independent exact validator. Validity overrides heuristic rejection. No success
is declared from an energy threshold or rounded clue match.

Log once per second and on improvements/solutions:

- Native current and native retained-best component energies and weighted totals.
- The same exact partition energy for all arms: (2*exact_clue_error +
  invalid_cell_fraction)/3.25, using the previous independent rescorer.
- Current, native-best and best-exact snapshots/labels. Keep the best-exact archive
  observational only so it does not secretly alter acceptance in one arm.
- Wrong clues, structural violations, edge uncertainty, and closeness to endpoints.
- Focus cell, local energy/hotness, n, sampled extent, patch and changed edge/cell
  counts, no-op count, delta, acceptance and restart events.
- Field/scoring/proposal/validation time separately; full time is the primary axis.

Always plot energy against elapsed wall-clock seconds, not iterations. Plot native
and shared exact scores separately, retaining increases under exact rescoring
when a native 'best' gets worse. Also show current-energy oscillations, acceptance
rate and remaining exact violations to distinguish annealing from stagnation.

## Stages and stopping semantics

1. Validate the harness without launching a puzzle search: distribution moments,
   hot/cold/flat-field behavior, boundary reflection, binary encoding, no-op
   accounting, unchanged outside-patch relationships and independent witness checks.
2. Pilot one paired seed (20261029) for every condition: eight trials total.
3. If the implementation checks and logged policies are correct, expand to five
   search seeds per condition on the same fixtures, then additional frozen puzzle
   instances. Do not tune n/weights on an instance and present that same instance
   as an independent confirmation.

The user-authorized cutoff is now 300 seconds per trial. Runs stop on a verified
solution, this declared cutoff, or an explicit user stop; numerical/storage failures are errors,
not timeouts or solves. Save checkpoints and RNG/proposal-channel state so long
runs can continue without restarting their search trajectory. Unfinished trials
remain unfinished and are reported as observed elapsed time, never as solve time.
No median solve-time claim should hide unsolved trials. Keep the eight condition
statuses explicit when a sequential schedule has not yet reached some arms.

Success for this pilot is evidence that regional adaptation improves solve time
and/or exact-energy progress **within** a representation across matched runs.
The field-guidance hypothesis remains unproven if only one seed improves, or if
only native energy improves while exact validity stagnates.

Implementation choices frozen before the pilot: initial region count 3–9; boundary/split/merge mutation family probabilities 0.65/0.20/0.15; initial temperature 0.03, cooling factor 0.9995 per proposal, floor 0.0005; restart after 5,000 proposals without improving the current epoch best. Discrete cell changes require all incident neighbors inside the patch, preserving outside-patch relationships. Four one-worker conditions for each size run together; sizes run as sequential batches. Successful jobs may free CPU capacity for the remaining jobs; process CPU times and batch concurrency are recorded. This pilot is one seed only.
