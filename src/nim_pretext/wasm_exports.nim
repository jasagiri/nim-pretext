## WASM exports for nim-pretext.
## Zero-copy layout engine operating directly on WASM linear memory.
##
## Supports two build targets via compile-time flags:
##   clang (default): Nim→C→clang→wasm-ld, uses wasi-libc malloc
##   nilvm (-d:nilvm): Nim→LLVM IR→lld, --mm:none, no runtime
##
## This mirrors the algorithm in line_break.nim (the canonical tested
## implementation). Any algorithm change MUST be applied to both files.
##
## NOTE: No nested procs/closures — nilvm --mm:none cannot allocate
## closure environments. All helpers are inlined as flat loop bodies.

import std/math

# ---------------------------------------------------------------------------
# Runtime stubs: diverge between clang (wasi-libc) and nilvm (no runtime)
# ---------------------------------------------------------------------------

when not defined(nilvm):
  proc wasmAlloc*(size: cint): pointer {.exportc: "pt_alloc", raises: [].} =
    alloc(size)

  proc wasmFree*(p: pointer) {.exportc: "pt_free", raises: [].} =
    if p != nil: dealloc(p)

  proc NimMain() {.importc.}

  proc initialize*() {.exportc: "pt_init", raises: [].} =
    NimMain()

# ---------------------------------------------------------------------------
# Shared helpers (non-closure)
# ---------------------------------------------------------------------------

proc getTabAdvanceW(lineWidth, tabStopAdvance: float64): float64 {.inline.} =
  if tabStopAdvance <= 0.0: return 0.0
  let remainder = floorMod(lineWidth, tabStopAdvance)
  if abs(remainder) <= 1e-6: return tabStopAdvance
  return tabStopAdvance - remainder

proc getBreakableAdvanceW(
  breakableDataPtr: ptr UncheckedArray[float64],
  breakablePrefixDataPtr: ptr UncheckedArray[float64],
  offset: int32,
  graphemeIndex: int,
  preferPrefixWidths: bool,
): float64 {.inline.} =
  if not preferPrefixWidths or breakablePrefixDataPtr == nil:
    return breakableDataPtr[offset + graphemeIndex.int32]
  if graphemeIndex > 0:
    return breakablePrefixDataPtr[offset + graphemeIndex.int32] -
           breakablePrefixDataPtr[offset + (graphemeIndex - 1).int32]
  return breakablePrefixDataPtr[offset + graphemeIndex.int32]

proc canBreakAfterW(kind: uint8): bool {.inline.} =
  kind == 1 or kind == 2 or kind == 3 or kind == 5 or kind == 6

# ---------------------------------------------------------------------------
# Exported layout function — single entry point for both build targets.
# No nested procs. All logic inlined to avoid closure allocation.
# ---------------------------------------------------------------------------

proc layoutCountLines*(
  segmentCount: int32,
  widthsPtr: ptr UncheckedArray[float64],
  lineEndFitAdvancesPtr: ptr UncheckedArray[float64],
  lineEndPaintAdvancesPtr: ptr UncheckedArray[float64],
  kindsPtr: ptr UncheckedArray[uint8],
  simplefast: int32,
  discretionaryHyphenWidth: float64,
  tabStopAdvance: float64,
  breakableOffsetsPtr: ptr UncheckedArray[int32],
  breakableDataPtr: ptr UncheckedArray[float64],
  breakableLengthsPtr: ptr UncheckedArray[int32],
  breakablePrefixDataPtr: ptr UncheckedArray[float64],
  chunkCount: int32,
  chunksPtr: ptr UncheckedArray[int32],  # flat stride-3: [start, end, consumed, ...]
  maxWidth: float64,
  lineFitEpsilon: float64,
  preferPrefixWidths: int32,
  preferEarlySoftHyphen: int32,
): int32 {.exportc: "pt_layout_count_lines".} =
  let n = segmentCount.int
  if n == 0: return 0
  let effectiveMaxWidth = maxWidth + lineFitEpsilon
  let prefWidths = preferPrefixWidths != 0

  if simplefast != 0:
    # -----------------------------------------------------------------------
    # Simple fast path: no chunks, no tabs, no soft-hyphens
    # -----------------------------------------------------------------------
    var lineCount: int32 = 0
    var lineW = 0.0
    var hasContent = false

    for i in 0 ..< n:
      let w = widthsPtr[i]
      let kind = kindsPtr[i]

      if not hasContent:
        # --- placeOnFreshLine (inlined) ---
        let offset = breakableOffsetsPtr[i]
        if w > maxWidth and offset >= 0:
          let gLen = breakableLengthsPtr[i].int
          lineW = 0.0
          for g in 0 ..< gLen:
            let gw = getBreakableAdvanceW(
              breakableDataPtr, breakablePrefixDataPtr, offset, g, prefWidths)
            if lineW > 0.0 and lineW + gw > effectiveMaxWidth:
              lineCount.inc
              lineW = gw
            else:
              if lineW == 0.0: lineCount.inc
              lineW += gw
        else:
          lineW = w
          lineCount.inc
        hasContent = true
        continue

      let newW = lineW + w
      if newW > effectiveMaxWidth:
        if kind == 1: continue  # CSS: collapsible space hangs past edge
        lineW = 0.0
        hasContent = false
        # --- placeOnFreshLine (inlined) ---
        let offset = breakableOffsetsPtr[i]
        if w > maxWidth and offset >= 0:
          let gLen = breakableLengthsPtr[i].int
          lineW = 0.0
          for g in 0 ..< gLen:
            let gw = getBreakableAdvanceW(
              breakableDataPtr, breakablePrefixDataPtr, offset, g, prefWidths)
            if lineW > 0.0 and lineW + gw > effectiveMaxWidth:
              lineCount.inc
              lineW = gw
            else:
              if lineW == 0.0: lineCount.inc
              lineW += gw
        else:
          lineW = w
          lineCount.inc
        hasContent = true
        continue

      lineW = newW

    if not hasContent: return lineCount + 1
    return lineCount

  else:
    # -----------------------------------------------------------------------
    # Complex path: chunks (hard-breaks), tabs, soft-hyphens
    # -----------------------------------------------------------------------
    var lineCount: int32 = 0
    let cn = chunkCount.int
    let earlyShy = preferEarlySoftHyphen != 0

    for ci in 0 ..< cn:
      let chunkStart = chunksPtr[ci * 3]
      let chunkEnd = chunksPtr[ci * 3 + 1]

      if chunkStart == chunkEnd:
        lineCount.inc
        continue

      var lineW = 0.0
      var hasContent = false
      var pendingBreakSeg: int32 = -1
      var pendingBreakFitW = 0.0
      var pendingBreakIsSoftHyphen = false

      var i = chunkStart
      while i < chunkEnd:
        let kind = kindsPtr[i]
        let w =
          if kind == 3: getTabAdvanceW(lineW, tabStopAdvance)
          else: widthsPtr[i]

        if kind == 6:  # soft-hyphen
          if hasContent:
            pendingBreakSeg = i + 1
            pendingBreakFitW = lineW + discretionaryHyphenWidth
            pendingBreakIsSoftHyphen = true
          i.inc
          continue

        if not hasContent:
          let offset = breakableOffsetsPtr[i]
          if w > maxWidth and offset >= 0:
            # --- appendBreakableFrom (inlined) ---
            let gLen = breakableLengthsPtr[i].int
            for g in 0 ..< gLen:
              let gw = getBreakableAdvanceW(
                breakableDataPtr, breakablePrefixDataPtr, offset, g, prefWidths)
              if not hasContent:
                hasContent = true
                lineW = gw
              elif lineW + gw > effectiveMaxWidth:
                lineCount.inc; lineW = gw
              else:
                lineW += gw
          else:
            hasContent = true
            lineW = w
          if canBreakAfterW(kind):
            let fitAdv = if kind == 3: 0.0 else: lineEndFitAdvancesPtr[i]
            pendingBreakSeg = i + 1
            pendingBreakFitW = lineW - w + fitAdv
            pendingBreakIsSoftHyphen = false
          i.inc
          continue

        let newW = lineW + w
        if newW > effectiveMaxWidth:
          let curFitW = lineW + (if kind == 3: 0.0 else: lineEndFitAdvancesPtr[i])

          if pendingBreakIsSoftHyphen and earlyShy and
             pendingBreakFitW <= effectiveMaxWidth:
            # --- emitLine (inlined) ---
            lineCount.inc; lineW = 0.0; hasContent = false
            pendingBreakSeg = -1; pendingBreakFitW = 0.0; pendingBreakIsSoftHyphen = false
            continue

          if canBreakAfterW(kind) and curFitW <= effectiveMaxWidth:
            lineCount.inc; lineW = 0.0; hasContent = false
            pendingBreakSeg = -1; pendingBreakFitW = 0.0; pendingBreakIsSoftHyphen = false
            i.inc
            continue

          if pendingBreakSeg >= 0 and pendingBreakFitW <= effectiveMaxWidth:
            lineCount.inc; lineW = 0.0; hasContent = false
            pendingBreakSeg = -1; pendingBreakFitW = 0.0; pendingBreakIsSoftHyphen = false
            continue

          let offset = breakableOffsetsPtr[i]
          if w > maxWidth and offset >= 0:
            lineCount.inc; lineW = 0.0; hasContent = false
            pendingBreakSeg = -1; pendingBreakFitW = 0.0; pendingBreakIsSoftHyphen = false
            # --- appendBreakableFrom (inlined) ---
            let gLen = breakableLengthsPtr[i].int
            for g in 0 ..< gLen:
              let gw = getBreakableAdvanceW(
                breakableDataPtr, breakablePrefixDataPtr, offset, g, prefWidths)
              if not hasContent:
                hasContent = true
                lineW = gw
              elif lineW + gw > effectiveMaxWidth:
                lineCount.inc; lineW = gw
              else:
                lineW += gw
            i.inc
            continue

          lineCount.inc; lineW = 0.0; hasContent = false
          pendingBreakSeg = -1; pendingBreakFitW = 0.0; pendingBreakIsSoftHyphen = false
          continue

        lineW = newW
        if canBreakAfterW(kind):
          let fitAdv = if kind == 3: 0.0 else: lineEndFitAdvancesPtr[i]
          pendingBreakSeg = i + 1
          pendingBreakFitW = lineW - w + fitAdv
          pendingBreakIsSoftHyphen = false
        i.inc

      if hasContent:
        lineCount.inc

    return lineCount
