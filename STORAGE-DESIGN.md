# Enforced workspace storage — feasibility findings

2026-10-05, Apple container 1.5.0. Architecture choice pending user response.

## Verified

- `container volume create -s SIZE NAME` creates an ext4 image with a recorded size.
- A requested 64 MiB volume mounted with about 126 MiB filesystem capacity. Small requested sizes do not directly establish an equivalent boundary; avoid offering such sizes and verify actual capacity before launch.
- A requested 256 MiB volume mounted with 264,216,576 bytes total filesystem capacity and rejected additional writes with ENOSPC after about 247 MiB of successful writes. Filesystem metadata reduces usable capacity.
- The guest used a read-only root filesystem and only a disposable named workspace volume for the test.
- An earlier file remained present when the volume filled.
- `container copy` requires a running container. Copy from a stopped test container failed with invalidState.
- Every disposable test guest and volume was removed. No existing workspaces were modified.

## Recommended implementation, if approved

Keep active files in a named, size-limited volume, with its identity persisted before creation. Mount the guest root read-only and budget every writable filesystem: project/caches in the bounded disk volume, temporary RAM filesystems bounded by memory. Show the actual capacity and occupancy reported by the guest filesystem. Avoid pretending a sum of visible file sizes is the enforced quota.

After the agent container stops, use an offline helper with the volume mounted read-only to recover results into a staged host directory. Validate recovered entries and swap the host working copy only after extraction succeeds. Keep the volume and ownership metadata on any failure. Only delete the volume after confirmed synchronization or explicit workspace deletion. Relaunch recovery must handle both agent and helper identities.

Finder shows the last synchronized host copy during a run. The app must say this plainly and prevent export/restore against a stale active copy. Existing snapshots and exports live outside the agent-write quota; shared runtime images also have separate accounting.

Alternative: a bounded macOS disk image mounted into the guest preserves live Finder access, at the cost of host mount lifecycle, disk image recovery, and detach handling. The current user question asks which behavior to choose.

## Not yet changed

Harbor still uses a host-folder mount and a warning threshold. Do not describe storage as capped until the selected design is implemented and verified through restart, quota exhaustion and recovery tests.
