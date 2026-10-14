# Performance

Screenlogger defines repeatable performance limits for work that users see.

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

The command writes machine-readable results under `build/performance`.
Do not commit these results.

For performance changes, report the hardware, macOS version, build configuration,
sample count, and values before and after the change.
Do not hide useful Library or Timeline content to improve a test measurement.

## Local semantic search

Related Search uses an isolated native encoder process. Model downloads require
explicit approval. The model files are separate from the Library size limit.

| Sources | Model download | Raw vector storage |
| --- | ---: | --- |
| Text | 320.3 MB | 3,072 bytes per text chunk |
| Images | 513.4 MB | 3,072 bytes per distinct prepared image |
| Images and text | 513.4 MB | Both source types |

These values exclude SQLite metadata and indexes. Long documents produce multiple
chunks. The index shares identical content rather than storing a vector for every
occurrence. Model file size is not a runtime memory limit.

### Measured encoder cost

Measured on an M5 Max MacBook Pro with 128 GiB RAM, macOS 27.2, using the signed
Release build. The input set contained three synthetic 1,920 x 1,080 screenshots.
Warm query samples repeated one query; image samples cycled through those screens.

| Operation | Samples | Median | p95 |
| --- | ---: | ---: | ---: |
| Warm text query | 30 | 7.59 ms | 8.38 ms |
| Warm screenshot encoding | 12 | 141.57 ms | 153.49 ms |

The first query took 4.39 seconds. The first image took 1.79 seconds after the text
model was loaded. Peak worker resident memory was 818.4 MB. Resident memory is not
a complete accounting of GPU allocations.

These measurements include the worker protocol and image preparation. They do not
include video extraction, SQLite retrieval, concurrent capture, or a representative
retrieval-quality evaluation. They are not end-to-end search latency guarantees.

At the measured image median, 42,581 distinct images would need about 100 minutes
of encoder work. Video extraction and scheduling add time; duplicate images can
reduce work. Their raw vectors would occupy about 130.8 MB before database overhead.

Automatic indexing waits for external power and at least one minute without input.
**Index Now** bypasses those waits until the pending work is complete. Memory
pressure, high temperature, and Low Power Mode still defer work. Searches take
priority over background indexing. Pausing or disabling the feature cancels manual
indexing and restores the automatic policy.

### Model correctness

All 1,290 stored tensors were checked against Google's pinned original model.
Quantized matrices matched independent affine-q8, group-64 conversion; the other
tensors were unchanged. The native image preparation matched the primary image
processor exactly on the synthetic fixtures. Embedding cosine agreement with the
primary implementation was at least 0.99949 in BF16 and 0.999997 in FP32.

These checks establish implementation agreement on the tested inputs, not search
accuracy across arbitrary screen history. Model provenance and upstream revisions
are recorded in `THIRD_PARTY_NOTICES.md`.

### Release-candidate retrieval review

A local seven-query image-search review used 1,225 indexed screenshots. The
backlog present at the start of manual indexing had drained; newly captured
screens continued to queue afterward. This is a small manual review, not an
accuracy benchmark or a claim about all user histories.

- YouTube and terminal descriptions retrieved visually relevant screens.
- A settings-window query returned actual settings windows, but also a menu
  about settings. A more specific coding-settings query ranked a web explanation
  above the actual settings window.
- A light LinkedIn feed query retrieved the expected site, including a loading
  screen before a fully rendered feed.
- An orange navigation-dropdown query placed the intended page fifth, behind
  visually incorrect candidates.
- An unrelated polar-bear query still returned unrelated screens.

Search currently ranks nearest candidates without a calibrated rejection
threshold. Cosine similarity is not confidence or evidence that a requested
screen exists. Inspect results and use exact search or app/site filters when
precision matters. Do not label scores as percentages or calibrated match tiers.
