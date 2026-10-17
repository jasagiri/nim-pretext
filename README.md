# nim-pretext

A Nim port of the line-breaking half of [pretext](https://github.com/chenglou/pretext), compiled to WASM.

Layout runs in two phases without DOM reflow:

1. **prepare** (JavaScript, in the browser): split the text into segments and measure each one, for example with canvas `measureText`.
2. **layout** (this package, Nim or WASM): break lines using only the cached widths. This phase is plain arithmetic.

## API

`import nim_pretext` re-exports `types` and `line_break`.

| Proc | Returns |
|---|---|
| `countPreparedLines(prepared, maxWidth, profile = defaultEngineProfile)` | number of lines (`int32`) |
| `walkPreparedLines(prepared, maxWidth, profile = defaultEngineProfile, onLine)` | number of lines; calls `onLine` once per line with an `InternalLayoutLine` |
| `layout(prepared, maxWidth, lineHeight, profile = defaultEngineProfile)` | `LayoutResult` (`lineCount`, `height`) |

These choose a path from `prepared.simpleLineWalkFastPath`. The paths themselves are also exported: `countPreparedLinesSimple` and `walkPreparedLinesSimple` (no chunks, tabs or soft hyphens), and `walkPreparedLinesComplex`. Unlike the procs above, they take `profile` without a default.

Types (`src/nim_pretext/types.nim`):

- `PreparedLineBreakData`: the prepared text as parallel sequences, one entry per segment. It holds `widths`, `lineEndFitAdvances` and `lineEndPaintAdvances` (the width a segment counts for when it ends a line, for fitting and for painting), and `kinds`. It also has the per-grapheme `breakableWidths` and `breakablePrefixWidths` (an empty sequence means the segment cannot break inside), `discretionaryHyphenWidth`, `tabStopAdvance` and `chunks`.
- `SegmentBreakKind`: `text`, `space`, `preservedSpace`, `tab`, `glue`, `zeroWidthBreak`, `softHyphen` and `hardBreak`.
- `PreparedLineChunk`, `EngineProfile` (with `defaultEngineProfile`), `InternalLayoutLine`, `LineBreakCursor` and `LayoutResult`.

## Example

```nim
import nim_pretext

# Widths measured on the JS side for "Hello world": "Hello", " ", "world".
let widths = @[50.0, 4.0, 60.0]
let prepared = PreparedLineBreakData(
  widths: widths,
  lineEndFitAdvances: @[50.0, 0.0, 60.0],   # a trailing space does not count toward fit
  lineEndPaintAdvances: @[50.0, 0.0, 60.0],
  kinds: @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
  simpleLineWalkFastPath: true,
  breakableWidths: newSeq[seq[float64]](widths.len),
  breakablePrefixWidths: newSeq[seq[float64]](widths.len),
  chunks: @[PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3,
                              consumedEndSegmentIndex: 3)],
)

echo countPreparedLines(prepared, maxWidth = 80.0)          # 2
echo layout(prepared, maxWidth = 200.0, lineHeight = 20.0)  # (lineCount: 1, height: 20.0)
```

`InternalLayoutLine` gives segment indices with an exclusive end. For the example above, `walkPreparedLines(prepared, 80.0, onLine = ...)` reports `0..2` (width 50) and `2..3` (width 60).

## WASM

`nimble buildWasm` (`wasm/build.sh`) compiles `src/nim_pretext/wasm_exports.nim` to `wasm/dist/`. It needs `nim`, `clang`, `wasm-ld` and a wasi-sysroot. The module exports `pt_init`, `pt_alloc` and `pt_free` for memory, and `pt_layout_count_lines` (`layoutCountLines` in Nim) for layout. `pt_layout_count_lines` takes the same data as raw pointers. `bench/bridge.ts` shows how to call it from JavaScript, and `BENCHMARK.md` has measurements against the TypeScript original.

## Dependencies

Nim >= 2.0.0 only.

## Tests

```bash
nimble test  # tests/test_line_break.nim
```
