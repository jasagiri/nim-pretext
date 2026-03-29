# nim-pretext Benchmark Results

Nim port of [pretext](https://github.com/chenglou/pretext) `layout()` compiled to WebAssembly, benchmarked against the original JavaScript implementation.

## Summary

| Scenario | JS (us/call) | clang WASM | nilvm WASM |
|---|---|---|---|
| Standard (500 mixed texts) | 0.450 | **4.5x faster** | **6.0x faster** |
| CJK editorial (5000-char Japanese) | 47.500 | **6.3x faster** | **9.5x faster** |
| Arabic long-form (bidi-heavy) | 7.500 | **3.0x faster** | **3.0x faster** |
| Mixed multilingual (CJK+Latin+emoji) | 12.500 | **4.0x faster** | **8.0x faster** |
| Long words overflow-wrap | 16.250 | 1.4x faster | 1.4x faster |
| Dense data/URLs | 6.250 | 1.3x faster | 1.3x faster |
| Resize sweep (1 CJK text, 20 widths) | 45.000 | **4.5x faster** | **9.0x faster** |

Correctness: **100%** across all scenarios. Binary size: clang 26.2 KB, nilvm 3.7 KB.

## Key Findings

**WASM advantage scales with segment count per text.** CJK text (1 segment per character) produces the most segments and shows the largest speedup (up to 9.5x). Latin text with few segments shows modest gains.

| Segments per text | Best WASM speedup | Why |
|---|---|---|
| ~4,700 (CJK 5000-char) | **9.5x** | Per-character breaking = deep inner loop, WASM dominates |
| ~1,860 (mixed multilingual) | **8.0x** | High segment diversity, many break decisions |
| ~1,150 (Arabic 3000-char) | **3.0x** | Moderate segments, some bidi overhead |
| ~38 (standard short texts) | **6.0x** | Many texts but few segments each — WASM call overhead amortized |
| ~187 (long words) | **1.4x** | Grapheme-level breaking is compute-bound in both JS and WASM |

**Overflow-wrap is the equalizer.** When text triggers grapheme-level word breaking (very narrow widths + long words), both JS and WASM spend most time in the same tight loop. The closure overhead that normally penalizes JS becomes negligible relative to the per-grapheme work.

## Scenarios

### Standard (500 mixed texts, 8 widths)

The baseline scenario from the original pretext benchmark. 500 short/medium texts (Latin, CJK, emoji, mixed) laid out at 8 widths from 100px to 1000px.

```
Texts: 500, Segments: 19,100, Calls/iter: 4,000
JS:     1.800ms  (0.450 us/call)
clang:  0.400ms  (0.100 us/call)  4.5x
nilvm:  0.300ms  (0.075 us/call)  6.0x
```

### CJK editorial (8 x 5000-char Japanese, narrow widths)

Simulates a Japanese article view. CJK text has per-character breaking (every character is a potential break point), producing ~4,700 segments per text. Narrow widths (120-360px) force many line breaks.

```
Texts: 8, Segments: 37,456, Calls/iter: 40
JS:     1.900ms  (47.500 us/call)
clang:  0.300ms  (7.500 us/call)   6.3x
nilvm:  0.200ms  (5.000 us/call)   9.5x
```

### Arabic long-form (8 texts, bidi-heavy)

Arabic text with right-to-left layout. Tests the complex chunk path with bidi-relevant segment structures.

```
Texts: 8, Segments: 9,176, Calls/iter: 40
JS:     0.300ms  (7.500 us/call)
clang:  0.100ms  (2.500 us/call)  3.0x
nilvm:  0.100ms  (2.500 us/call)  3.0x
```

### Mixed multilingual (16 texts, CJK+Latin+emoji)

Tech blog content mixing Japanese, English, and emoji. High segment diversity with CJK per-character breaks interleaved with Latin word boundaries.

```
Texts: 16, Segments: 29,776, Calls/iter: 64
JS:     0.800ms  (12.500 us/call)
clang:  0.200ms  (3.125 us/call)  4.0x
nilvm:  0.100ms  (1.563 us/call)  8.0x
```

### Long words overflow-wrap (16 texts, very narrow)

Stress test for `overflow-wrap: break-word`. Long technical terms (30+ characters) at very narrow widths (80-300px) force grapheme-level breaking. This is where JS and WASM converge — both spend most time in the per-grapheme inner loop.

```
Texts: 16, Segments: 2,992, Calls/iter: 80
JS:     1.300ms  (16.250 us/call)
clang:  0.900ms  (11.250 us/call)  1.4x
nilvm:  0.900ms  (11.250 us/call)  1.4x
```

### Dense data/URLs (16 texts, numeric merging)

Content heavy with URLs, IP addresses, phone numbers, hashes, and numeric sequences. Tests the interaction between numeric run merging in analysis and line breaking.

```
Texts: 16, Segments: 7,552, Calls/iter: 64
JS:     0.400ms  (6.250 us/call)
clang:  0.300ms  (4.688 us/call)  1.3x
nilvm:  0.300ms  (4.688 us/call)  1.3x
```

### Resize sweep (1 large CJK text, 20 widths)

Single 5000-character Japanese text laid out at 20 different widths (100-1050px). Simulates a responsive resize handler — the primary use case for the `layout()` hot path.

```
Texts: 1, Segments: 4,682, Calls/iter: 20
JS:     0.900ms  (45.000 us/call)
clang:  0.200ms  (10.000 us/call)  4.5x
nilvm:  0.100ms  (5.000 us/call)   9.0x
```

## Methodology

### What is benchmarked

Only the `layout()` hot path — pure arithmetic line breaking on pre-measured segment widths. The `prepare()` phase (text segmentation + canvas measurement) runs in JavaScript for all three implementations and is excluded from timing.

This reflects real-world usage: `prepare()` runs once when text appears, `layout()` runs on every resize.

### Protocol

1. `prepare()` all texts with `@chenglou/pretext` (shared, not timed)
2. Transfer prepared data into each WASM module's memory (not timed)
3. Validate correctness: assert `JS lineCount === clang WASM === nilvm WASM` for every text × width
4. Warmup: 50-100 iterations per scenario
5. Measured: 500-2000 iterations per scenario
6. Report: median per-iteration time and per-call time

### Correctness validation

Before benchmarking each scenario, every text × width combination is validated. Any mismatch halts the scenario. All scenarios passed with 100% match.

## Why two WASM build pipelines

| | Nim → C → clang → WASM | Nim → nilvm (LLVM) → WASM |
|---|---|---|
| **Path** | Nim compiles to C, clang compiles to WASM, wasm-ld links with wasi-libc | nilvm emits LLVM IR directly, lld links standalone |
| **Runtime** | wasi-libc (malloc, stdio stubs) | None (`--mm:none`) |
| **WASI imports** | 45 functions | 1 (`fmod`) |
| **Binary size** | 26.2 KB | 3.7 KB |
| **Best speedup** | 6.3x (CJK editorial) | 9.5x (CJK editorial) |

Both are compiled from the same Nim source file (`wasm_exports.nim`), selected by `-d:nilvm` at compile time.

## Why WASM is faster than V8

The original JavaScript `layout()` function uses closures with captured mutable variables. V8 must:

1. Allocate closure environments on the heap for each call
2. Perform dynamic dispatch through closure pointers
3. Track garbage collection roots for closure environments
4. JIT-compile with speculative optimizations that can deoptimize

The Nim WASM implementation:

1. Operates directly on linear memory (zero-copy from JS typed arrays)
2. Uses flat control flow with no heap allocation (closures eliminated)
3. Precomputes `effectiveMaxWidth = maxWidth + lineFitEpsilon` outside the hot loop
4. Benefits from ahead-of-time compilation (deterministic performance, no JIT variance)

The advantage is largest when the inner loop dominates (many segments per text), and smallest when per-grapheme overflow-wrap work dominates (both implementations hit the same tight arithmetic loop).

## Environment

| Component | Version |
|---|---|
| Hardware | Apple M2, 24 GB RAM |
| OS | macOS 15.6 (Sequoia) |
| Browser | Chromium (headless, via Playwright) |
| Nim | 2.2.8 |
| nilvm | 0.0.2 (LLVM 21.1.8) |
| clang | Apple clang 17.0.0 |
| wasm-ld | LLD 22.1.2 |
| pretext | @chenglou/pretext 0.0.3 |

## Reproducing

```bash
# Build WASM modules (both clang and nilvm)
bash wasm/build.sh

# Install benchmark dependencies
cd bench && bun install

# Start dev server
bun run serve.ts &

# Run headless benchmark (all scenarios)
bun run run_bench.ts

# Or open http://localhost:3456 in a browser
```
