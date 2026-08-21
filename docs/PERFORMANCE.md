# Performance

Screenlogger has deterministic performance budgets for the work most visible to
users.

| Metric | Workload | Budget |
| --- | --- | ---: |
| Warm Library search | Indexed query over 50,000 frames | p95 under 120 ms |
| First thumbnail decode | 1,920 x 1,080 still downsampled to 480 px | under 100 ms |
| Timeline frame extraction | Still-backed 1,280 px preview | p95 under 100 ms |
| Process CPU | Rapid scrub paced at 50 Hz | average under 25 percent |
| Resident memory | Full measured workload | peak under 350 MiB |

Run the harness:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
Scripts/measure-performance.sh
```

The command produces machine-readable results under `build/performance`. Those
results are evidence, not source, and must not be committed.

Performance changes should report hardware, macOS version, build configuration,
sample count, and before/after values. Do not hide useful Library or Timeline
content behind a new full-screen loading state to improve a synthetic number.
