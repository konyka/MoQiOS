# Fixed VMA Table Profiling Baseline

`Task.mmap_regions` is a fixed 64-entry table. Before replacing it with a
dynamic VMA tree, MoQiOS records a stable fixed-table model-event baseline so a
larger, riskier data-structure change is justified by evidence rather than by
the capacity number alone.

## Metric Contract

`kernel/mm/vma_stats.zig` is an import-free host-test model of the fixed table:
every full scan costs 64 slots, while the active-entry count is bounded to 64.
`kernel/mm/vma_runtime_stats.zig` is separate so runtime atomics cannot leak
into host policy tests.

The mmap metadata paths record an instrumented scan event at the entry to
replacement-capacity, region tracking, untracking, and overlap checks. This is
an explicit sampling contract, not a claim that every internal loop traversal
is counted: `canTrackMmapRegion`, `rangeAvailable`, `mprotect`, and `mremap`
remain outside this first baseline. Each event carries the fixed 64-slot model
cost and the current clamped active-region sample. A single packed relaxed
atomic keeps reads coherent on SMP. No clock is read, no lock is acquired, and
the statistics do not participate in allocation, placement, or correctness.

`/proc/vma_stats` exposes a single line:

```
events=<n> modeled_slots=<n> avg_modeled_slots=<n>
```

The values are global boot-session diagnostics. They include all processes and
all prior activity, so acceptance asserts invariants rather than fragile exact
counter deltas. `avg_slots` must remain `64` for the current representation.

## Runtime Baseline

`hello67` creates 40 disjoint anonymous 4 KiB mappings, removes every other
mapping, then maps 10 more pages. It validates address disjointness, bounded
live-region count, parses `/proc/vma_stats`, and reports the observed counters
on serial. The smoke gate requires its PASS and completion markers.

Observed single-core QEMU baseline (hello67, 2026-08-17):

```
hello67: vma fragments=20 events=2654 modeled_slots=169856 avg_modeled_slots=64
```

The workload exercised 2,654 instrumented fixed-table scan events, modeled at
64 slots each. This is the
starting point for expanding coverage or evaluating a future tree; it is not a
claim that every internal loop iteration was counted.

This is a structural baseline, not a throughput claim: it demonstrates the
fixed scan cost under fragmentation without using unstable QEMU wall-clock
numbers. For wall-clock comparisons, use `tools/observe_test_duration.py` with
the same QEMU scenario before and after a proposed implementation change.

## Decision Rule

Do not replace the table solely because it has 64 entries. A dynamic VMA tree
is justified only when repeatable fragmented workloads show both:

1. sustained high scan pressure in `/proc/vma_stats` (the fixed 64-slot cost
   dominates the relevant mmap/mprotect/mremap workload); and
2. a measured before/after QEMU scenario improvement that exceeds instrumentation
   noise while preserving the host and SMP smoke gates.

Until then, the fixed table has predictable memory use, cache locality, and a
small, bounded worst-case scan. Any future tree design must retain the current
metadata split/merge, RLIMIT, huge-page, file-backing, no-free, and TLB
invariants before changing lookup complexity.
