# Versioned workers, stable credentials, and administration

Reviewed and deployed release: **software version 1**. The deployment outcome is recorded below.

## Interrupted deployment safety

The preceding repair rollout was paused before installing the Linux or Mac mini
staged binaries or restarting the coordinator. Read-only checks confirmed that
perfect-sheepdog and gentle-spaniel retained their workers in the original tmux
panes; accepted-robin was already offline. All three staging compilers exited with
`missing required module 'SwiftShims'`; none replaced a live binary. The Mini's
staged build completed separately from its running coordinator/worker. There is
no pending certificate rotation or live database replacement to finish.

At the interruption, the local installed repair executable had SHA-256
`d51d1758a6edfc93ef15cb6acfbcce1243302688a6c123bd6e5efa04fbd5bef0`.
It was replaced with version 1 during the later authorized rollout.
Feature builds and temporary test processes used isolated scratch directories and
disposable state. The later version 1 rollout is recorded below.

## Behavior

- `SoftwareVersion.current` is the single monotonic release number. It appears in
  CLI `--version`, worker/coordinator startup output, standalone JSONL/console logs,
  coordinator worker-connect messages, and dashboard worker/coordinator displays.
  `AGENTS.md` requires advancing it for changes to core code.
- Software version and wire protocol version are separate. Optional version fields
  preserve old saved-state decoding and identify legacy peers as unversioned.
  Default `minimumPeerVersion` is the current release. The coordinator checks it
  before applying reports or assignments; workers stop on incompatible coordinators.
  Explicitly setting 0 permits legacy peers with the same wire protocol for a
  controlled transition. Future software versions remain rejected.
- Default `credentialMode` is `reuse`: load configured certificate, private key,
  and join token. Missing/expired/mismatched identities fail without regeneration.
  `--init-credentials` only provisions missing credentials; an incomplete TLS pair
  is rejected. `--rotate-credentials` explicitly replaces the identity and join
  token. Ordinary restarts preserve the fingerprint and token.
- The private key is persisted with mode 0600. All credential material is validated
  before changing files or opening the run database. Ordinary write failures roll
  back completed file writes; abrupt power loss between rotation writes can leave
  a mismatched identity, which fails closed on restart. Reserved state paths and
  the separate admin token cannot be used as credential destinations.
- Remote browsers can manage workers with the separate web-admin-token when the
  dashboard is bound to a reachable address. Matching Origin/Host, JSON request
  bodies, bounded request sizes, constant-time bearer comparison, and separate
  worker/admin tokens remain required. Wildcard CORS is disabled. HTTP requires a
  trusted network, SSH tunnel, or HTTPS proxy to protect tokens in transit.
- Charts now include independently best total and residual energy, accepted work,
  reporting worker slots, incorrect clues, and fleet throughput. Energy history
  can improve without replacing the lexicographic quality leader. Histories are
  persisted and bounded; charts describe reported measurements, not every move or
  a completion estimate. Old snapshots cannot reconstruct missing historical data.
- Machine context menus offer the same authenticated management actions as buttons,
  worker-count changes, and ID/status copying. Job menus copy details; board menus
  export JSON. Keyboard activation, arrows, Escape, outside-click dismissal, focus
  preservation across refreshes, viewport clamping, and existing quit confirmations
  are retained. Locked menus cannot issue commands.

## Migration from older coordinators

Older coordinators discarded the private key, so their public certificate cannot
be reused without that key. The mini's version 1 rollout generated and persisted
a new matching certificate and key while preserving the existing join token.
Its three Linux workers and local worker received the new public certificate;
the user will update the two Pi workers later. The prepared mini needs neither
`--init-credentials` nor `--rotate-credentials` on normal startup. Those explicit
options remain available for new setups and intentional future rotations.

## Validation

All 83 package tests in 13 suites passed. Package tests cover version rejection without state mutation, explicit legacy
admission, saved-state compatibility, independent residual history, identity reuse,
custom paths, incomplete/mismatched/expired identities, explicit rotation, rollback,
reserved-path protection, remote same-origin administration, and real process
restart/reconnection using an unchanged pin and run ID. Recovery tests prefer the
current test build and accept `PUZZLE_TEST_EXECUTABLE` for isolated builds.

All six standalone core suites passed, including scoring, validator, repair,
checkpoint, deterministic proposal, cancellation, and logging checks. All 11 Python
migration/progress/management tests passed against the isolated executable, including
pause/restart/resize/offline quit/relaunch/drain. Browser checks use a disposable local
coordinator and a simulated worker: locked/unlocked right-click controls, checkpoint
command queuing, chart rendering, and keyboard focus/dismissal.

The temporary browser preview processes were stopped after verification. The
preview screenshot is saved outside the repository in this chat's visualization
folder. `git diff --check` passed. At that point no production credentials had
been rotated; the later authorized rollout is described below.

## Deployment completed on 2026-10-28

The preserved coordinator run is `76FBAED1-E3E5-4303-BDBF-26D96720F107`. The
mini's coordinator and worker both have native macOS version 1 executables.
The mini's public certificate and private key were regenerated as a matched,
persistent pair because the former key was never saved; the existing join token
was preserved. Both processes were left stopped for the user to start, and were
subsequently observed running. `START_V1.txt` is present in both installations.

The exact tested Linux binary was installed on perfect-sheepdog (84.32.34.69),
gentle-spaniel (84.32.53.114), and accepted-robin (84.32.53.113). The first two
were checkpointed and restarted in their existing tmux panes `1:0.0` and `0:0.0`;
the third had no existing session and uses `jsp-worker:0.0`. Their installed
binary, public certificate, and join token were checked against the coordinator.
The local Mac worker binary and public certificate were prepared and its token
was unchanged. The live coordinator showed all five current workers connected
at version 1. Raspberry Pi and Orange Pi are awaiting the user's update; the
former helpful-mackerel machine has been retired.

The Linux release passed all 83 package tests in 13 suites. A clean isolated
build avoided the stale-artifact SwiftShims failure from the interrupted rollout.
The Mac release had previously passed 83 package tests, six standalone core
suites, and 11 Python tests. Temporary credential-transfer bundles were removed
from the three Linux machines and this workspace's temporary directory. Previous
binaries and credentials were kept in root-only rollback directories on the
Linux machines and a private rollback directory on the mini.
