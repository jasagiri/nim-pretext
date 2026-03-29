## Line breaking algorithm for pretext.
## Port of pretext's line-break.ts.
##
## This is the canonical, tested implementation using Nim seq[].
## wasm_exports.nim mirrors this logic with zero-copy pointer access.
## Any algorithm change MUST be applied to both files.
##
## Two code paths:
## - Simple fast path: normal text without hard-breaks, tabs, or pre-wrap
## - Complex path: chunk-based iteration for pre-wrap with hard breaks and tabs

import std/math
import types

proc getTabAdvance(lineWidth, tabStopAdvance: float64): float64 {.inline, raises: [].} =
  if tabStopAdvance <= 0: return 0.0
  let remainder = floorMod(lineWidth, tabStopAdvance)
  if abs(remainder) <= 1e-6: return tabStopAdvance
  return tabStopAdvance - remainder

proc getBreakableAdvance(
  graphemeWidths: openArray[float64],
  graphemePrefixWidths: openArray[float64],
  graphemeIndex: int,
  preferPrefixWidths: bool,
): float64 {.inline, raises: [].} =
  if not preferPrefixWidths or graphemePrefixWidths.len == 0:
    return graphemeWidths[graphemeIndex]
  if graphemeIndex > 0:
    return graphemePrefixWidths[graphemeIndex] - graphemePrefixWidths[graphemeIndex - 1]
  return graphemePrefixWidths[graphemeIndex]

type
  SoftHyphenBreakResult = object
    fitCount: int
    fittedWidth: float64

proc fitSoftHyphenBreak(
  graphemeWidths: openArray[float64],
  initialWidth, effectiveMaxWidth, discretionaryHyphenWidth: float64,
  cumulativeWidths: bool,
): SoftHyphenBreakResult {.raises: [].} =
  var fitCount = 0
  var fittedWidth = initialWidth
  while fitCount < graphemeWidths.len:
    let nextWidth =
      if cumulativeWidths: initialWidth + graphemeWidths[fitCount]
      else: fittedWidth + graphemeWidths[fitCount]
    let nextLineWidth =
      if fitCount + 1 < graphemeWidths.len: nextWidth + discretionaryHyphenWidth
      else: nextWidth
    if nextLineWidth > effectiveMaxWidth: break
    fittedWidth = nextWidth
    fitCount.inc
  SoftHyphenBreakResult(fitCount: fitCount, fittedWidth: fittedWidth)

# ---------------------------------------------------------------------------
# Simple fast path: countPreparedLinesSimple
# ---------------------------------------------------------------------------

proc countPreparedLinesSimple*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile,
): int32 {.raises: [].} =
  ## Specialized hot-path counter that mirrors walkPreparedLinesSimple break
  ## semantics without tracking cursors/widths. Must stay aligned.
  let widths = prepared.widths
  let kinds = prepared.kinds
  if widths.len == 0: return 0

  # Precompute effective max width to avoid repeated addition in hot loop.
  # From chenglou/pretext#6 V8 optimization analysis.
  let effectiveMaxWidth = maxWidth + profile.lineFitEpsilon
  var lineCount: int32 = 0
  var lineW = 0.0
  var hasContent = false

  proc placeOnFreshLine(segmentIndex: int) =
    let w = widths[segmentIndex]
    if w > maxWidth and prepared.breakableWidths[segmentIndex].len > 0:
      let gWidths = prepared.breakableWidths[segmentIndex]
      let gPrefixWidths = prepared.breakablePrefixWidths[segmentIndex]
      lineW = 0.0
      for g in 0 ..< gWidths.len:
        let gw = getBreakableAdvance(
          gWidths, gPrefixWidths, g,
          profile.preferPrefixWidthsForBreakableRuns,
        )
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

  for i in 0 ..< widths.len:
    let w = widths[i]
    let kind = kinds[i]

    if not hasContent:
      placeOnFreshLine(i)
      continue

    let newW = lineW + w
    if newW > effectiveMaxWidth:
      if isSimpleCollapsibleSpace(kind): continue
      lineW = 0.0
      hasContent = false
      placeOnFreshLine(i)
      continue

    lineW = newW

  if not hasContent: return lineCount + 1
  return lineCount

# ---------------------------------------------------------------------------
# Simple fast path with line emission: walkPreparedLinesSimple
# ---------------------------------------------------------------------------

proc walkPreparedLinesSimple*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile,
  onLine: proc(line: InternalLayoutLine) {.raises: [].},
): int32 {.raises: [].} =
  let widths = prepared.widths
  let kinds = prepared.kinds
  if widths.len == 0: return 0

  let effectiveMaxWidth = maxWidth + profile.lineFitEpsilon
  var lineCount: int32 = 0
  var lineW = 0.0
  var hasContent = false
  var lineStartSeg: int32 = 0
  var lineStartGr: int32 = 0
  var lineEndSeg: int32 = 0
  var lineEndGr: int32 = 0
  var pendingBreakSeg: int32 = -1
  var pendingBreakPaintW = 0.0

  proc clearPendingBreak() =
    pendingBreakSeg = -1
    pendingBreakPaintW = 0.0

  proc emitCurrentLine(
    endSeg: int32 = lineEndSeg,
    endGr: int32 = lineEndGr,
    width: float64 = lineW,
  ) =
    lineCount.inc
    onLine(InternalLayoutLine(
      startSegmentIndex: lineStartSeg,
      startGraphemeIndex: lineStartGr,
      endSegmentIndex: endSeg,
      endGraphemeIndex: endGr,
      width: width,
    ))
    lineW = 0.0
    hasContent = false
    clearPendingBreak()

  proc startLineAtSegment(segIdx: int32, width: float64) =
    hasContent = true
    lineStartSeg = segIdx
    lineStartGr = 0
    lineEndSeg = segIdx + 1
    lineEndGr = 0
    lineW = width

  proc startLineAtGrapheme(segIdx, grIdx: int32, width: float64) =
    hasContent = true
    lineStartSeg = segIdx
    lineStartGr = grIdx
    lineEndSeg = segIdx
    lineEndGr = grIdx + 1
    lineW = width

  proc appendWholeSegment(segIdx: int32, width: float64) =
    if not hasContent:
      startLineAtSegment(segIdx, width)
      return
    lineW += width
    lineEndSeg = segIdx + 1
    lineEndGr = 0

  proc updatePendingBreak(segIdx: int32, segWidth: float64) =
    if not canBreakAfter(kinds[segIdx]): return
    pendingBreakSeg = segIdx + 1
    pendingBreakPaintW = lineW - segWidth

  proc appendBreakableSegmentFrom(segIdx: int32, startGr: int) =
    let gWidths = prepared.breakableWidths[segIdx]
    let gPrefixWidths = prepared.breakablePrefixWidths[segIdx]
    for g in startGr ..< gWidths.len:
      let gw = getBreakableAdvance(
        gWidths, gPrefixWidths, g,
        profile.preferPrefixWidthsForBreakableRuns,
      )
      if not hasContent:
        startLineAtGrapheme(segIdx.int32, g.int32, gw)
        continue
      if lineW + gw > effectiveMaxWidth:
        emitCurrentLine()
        startLineAtGrapheme(segIdx.int32, g.int32, gw)
      else:
        lineW += gw
        lineEndSeg = segIdx.int32
        lineEndGr = (g + 1).int32
    if hasContent and lineEndSeg == segIdx.int32 and lineEndGr == gWidths.len.int32:
      lineEndSeg = segIdx.int32 + 1
      lineEndGr = 0

  var i = 0
  while i < widths.len:
    let w = widths[i]
    let kind = kinds[i]
    let si = i.int32

    if not hasContent:
      if w > maxWidth and prepared.breakableWidths[i].len > 0:
        appendBreakableSegmentFrom(si, 0)
      else:
        startLineAtSegment(si, w)
      updatePendingBreak(si, w)
      i.inc
      continue

    let newW = lineW + w
    if newW > effectiveMaxWidth:
      # CSS: trailing collapsible whitespace hangs past the line edge
      # without triggering a break. Must match countPreparedLinesSimple.
      if isSimpleCollapsibleSpace(kind):
        i.inc
        continue
      if canBreakAfter(kind):
        appendWholeSegment(si, w)
        emitCurrentLine(si + 1, 0, lineW - w)
        i.inc
        continue
      if pendingBreakSeg >= 0:
        emitCurrentLine(pendingBreakSeg, 0, pendingBreakPaintW)
        continue
      if w > maxWidth and prepared.breakableWidths[i].len > 0:
        emitCurrentLine()
        appendBreakableSegmentFrom(si, 0)
        i.inc
        continue
      emitCurrentLine()
      continue

    appendWholeSegment(si, w)
    updatePendingBreak(si, w)
    i.inc

  if hasContent: emitCurrentLine()
  return lineCount

# ---------------------------------------------------------------------------
# Complex path: walkPreparedLinesComplex (chunks, tabs, soft-hyphens)
# ---------------------------------------------------------------------------

proc walkPreparedLinesComplex*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile,
  onLine: proc(line: InternalLayoutLine) {.raises: [].} = nil,
): int32 {.raises: [].} =
  let widths = prepared.widths
  let kinds = prepared.kinds
  let chunks = prepared.chunks
  if widths.len == 0 or chunks.len == 0: return 0

  let effectiveMaxWidth = maxWidth + profile.lineFitEpsilon
  var lineCount: int32 = 0
  var lineW = 0.0
  var hasContent = false
  var lineStartSeg: int32 = 0
  var lineStartGr: int32 = 0
  var lineEndSeg: int32 = 0
  var lineEndGr: int32 = 0
  var pendingBreakSeg: int32 = -1
  var pendingBreakFitW = 0.0
  var pendingBreakPaintW = 0.0
  var pendingBreakKind: SegmentBreakKind = SegmentBreakKind.text

  proc clearPendingBreak() =
    pendingBreakSeg = -1
    pendingBreakFitW = 0.0
    pendingBreakPaintW = 0.0
    pendingBreakKind = SegmentBreakKind.text

  proc emitCurrentLine(
    endSeg: int32 = lineEndSeg,
    endGr: int32 = lineEndGr,
    width: float64 = lineW,
  ) =
    lineCount.inc
    if onLine != nil:
      onLine(InternalLayoutLine(
        startSegmentIndex: lineStartSeg,
        startGraphemeIndex: lineStartGr,
        endSegmentIndex: endSeg,
        endGraphemeIndex: endGr,
        width: width,
      ))
    lineW = 0.0
    hasContent = false
    clearPendingBreak()

  proc startLineAtSegment(segIdx: int32, width: float64) =
    hasContent = true
    lineStartSeg = segIdx
    lineStartGr = 0
    lineEndSeg = segIdx + 1
    lineEndGr = 0
    lineW = width

  proc startLineAtGrapheme(segIdx, grIdx: int32, width: float64) =
    hasContent = true
    lineStartSeg = segIdx
    lineStartGr = grIdx
    lineEndSeg = segIdx
    lineEndGr = grIdx + 1
    lineW = width

  proc appendWholeSegment(segIdx: int32, width: float64) =
    if not hasContent:
      startLineAtSegment(segIdx, width)
      return
    lineW += width
    lineEndSeg = segIdx + 1
    lineEndGr = 0

  proc updatePendingBreakForWholeSegment(segIdx: int32, segWidth: float64) =
    if not canBreakAfter(kinds[segIdx]): return
    let fitAdvance =
      if kinds[segIdx] == SegmentBreakKind.tab: 0.0
      else: prepared.lineEndFitAdvances[segIdx]
    let paintAdvance =
      if kinds[segIdx] == SegmentBreakKind.tab: segWidth
      else: prepared.lineEndPaintAdvances[segIdx]
    pendingBreakSeg = segIdx + 1
    pendingBreakFitW = lineW - segWidth + fitAdvance
    pendingBreakPaintW = lineW - segWidth + paintAdvance
    pendingBreakKind = kinds[segIdx]

  proc appendBreakableSegmentFrom(segIdx: int32, startGr: int) =
    let gWidths = prepared.breakableWidths[segIdx]
    let gPrefixWidths = prepared.breakablePrefixWidths[segIdx]
    for g in startGr ..< gWidths.len:
      let gw = getBreakableAdvance(
        gWidths, gPrefixWidths, g,
        profile.preferPrefixWidthsForBreakableRuns,
      )
      if not hasContent:
        startLineAtGrapheme(segIdx, g.int32, gw)
        continue
      if lineW + gw > effectiveMaxWidth:
        emitCurrentLine()
        startLineAtGrapheme(segIdx, g.int32, gw)
      else:
        lineW += gw
        lineEndSeg = segIdx
        lineEndGr = (g + 1).int32
    if hasContent and lineEndSeg == segIdx and lineEndGr == gWidths.len.int32:
      lineEndSeg = segIdx + 1
      lineEndGr = 0

  proc continueSoftHyphenBreakableSegment(segIdx: int32): bool =
    if pendingBreakKind != SegmentBreakKind.softHyphen: return false
    let gWidths = prepared.breakableWidths[segIdx]
    if gWidths.len == 0: return false
    let fitWidths =
      if profile.preferPrefixWidthsForBreakableRuns and
         prepared.breakablePrefixWidths[segIdx].len > 0:
        prepared.breakablePrefixWidths[segIdx]
      else:
        gWidths
    let usesPrefixWidths = fitWidths.len > 0 and
      (addr(fitWidths[0]) != addr(gWidths[0]))
    let res = fitSoftHyphenBreak(
      fitWidths, lineW, effectiveMaxWidth,
      prepared.discretionaryHyphenWidth, usesPrefixWidths,
    )
    if res.fitCount == 0: return false
    lineW = res.fittedWidth
    lineEndSeg = segIdx
    lineEndGr = res.fitCount.int32
    clearPendingBreak()
    if res.fitCount == gWidths.len:
      lineEndSeg = segIdx + 1
      lineEndGr = 0
      return true
    emitCurrentLine(segIdx, res.fitCount.int32,
                    res.fittedWidth + prepared.discretionaryHyphenWidth)
    appendBreakableSegmentFrom(segIdx, res.fitCount)
    return true

  for chunkIdx in 0 ..< chunks.len:
    let chunk = chunks[chunkIdx]
    if chunk.startSegmentIndex == chunk.endSegmentIndex:
      # Empty chunk (e.g. trailing hard-break)
      lineCount.inc
      if onLine != nil:
        onLine(InternalLayoutLine(
          startSegmentIndex: chunk.startSegmentIndex,
          startGraphemeIndex: 0,
          endSegmentIndex: chunk.consumedEndSegmentIndex,
          endGraphemeIndex: 0,
          width: 0.0,
        ))
      clearPendingBreak()
      continue

    hasContent = false
    lineW = 0.0
    lineStartSeg = chunk.startSegmentIndex
    lineStartGr = 0
    lineEndSeg = chunk.startSegmentIndex
    lineEndGr = 0
    clearPendingBreak()

    var i = chunk.startSegmentIndex
    while i < chunk.endSegmentIndex:
      let kind = kinds[i]
      let w =
        if kind == SegmentBreakKind.tab: getTabAdvance(lineW, prepared.tabStopAdvance)
        else: widths[i]

      if kind == SegmentBreakKind.softHyphen:
        if hasContent:
          lineEndSeg = i + 1
          lineEndGr = 0
          pendingBreakSeg = i + 1
          pendingBreakFitW = lineW + prepared.discretionaryHyphenWidth
          pendingBreakPaintW = lineW + prepared.discretionaryHyphenWidth
          pendingBreakKind = kind
        i.inc
        continue

      if not hasContent:
        if w > maxWidth and prepared.breakableWidths[i].len > 0:
          appendBreakableSegmentFrom(i, 0)
        else:
          startLineAtSegment(i, w)
        updatePendingBreakForWholeSegment(i, w)
        i.inc
        continue

      let newW = lineW + w
      if newW > effectiveMaxWidth:
        let currentBreakFitW = lineW +
          (if kind == SegmentBreakKind.tab: 0.0 else: prepared.lineEndFitAdvances[i])
        let currentBreakPaintW = lineW +
          (if kind == SegmentBreakKind.tab: w else: prepared.lineEndPaintAdvances[i])

        if pendingBreakKind == SegmentBreakKind.softHyphen and
           profile.preferEarlySoftHyphenBreak and
           pendingBreakFitW <= effectiveMaxWidth:
          emitCurrentLine(pendingBreakSeg, 0, pendingBreakPaintW)
          continue

        if pendingBreakKind == SegmentBreakKind.softHyphen and
           continueSoftHyphenBreakableSegment(i):
          i.inc
          continue

        if canBreakAfter(kind) and currentBreakFitW <= effectiveMaxWidth:
          appendWholeSegment(i, w)
          emitCurrentLine(i + 1, 0, currentBreakPaintW)
          i.inc
          continue

        if pendingBreakSeg >= 0 and pendingBreakFitW <= effectiveMaxWidth:
          emitCurrentLine(pendingBreakSeg, 0, pendingBreakPaintW)
          continue

        if w > maxWidth and prepared.breakableWidths[i].len > 0:
          emitCurrentLine()
          appendBreakableSegmentFrom(i, 0)
          i.inc
          continue

        emitCurrentLine()
        continue

      appendWholeSegment(i, w)
      updatePendingBreakForWholeSegment(i, w)
      i.inc

    if hasContent:
      let finalPaintW =
        if pendingBreakSeg == chunk.consumedEndSegmentIndex: pendingBreakPaintW
        else: lineW
      emitCurrentLine(chunk.consumedEndSegmentIndex, 0, finalPaintW)

  return lineCount

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc countPreparedLines*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile = defaultEngineProfile,
): int32 {.raises: [].} =
  if prepared.simpleLineWalkFastPath:
    return countPreparedLinesSimple(prepared, maxWidth, profile)
  return walkPreparedLinesComplex(prepared, maxWidth, profile)

proc walkPreparedLines*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile = defaultEngineProfile,
  onLine: proc(line: InternalLayoutLine) {.raises: [].},
): int32 {.raises: [].} =
  if prepared.simpleLineWalkFastPath:
    return walkPreparedLinesSimple(prepared, maxWidth, profile, onLine)
  return walkPreparedLinesComplex(prepared, maxWidth, profile, onLine)

proc layout*(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  lineHeight: float64,
  profile: EngineProfile = defaultEngineProfile,
): LayoutResult {.raises: [].} =
  let lineCount = countPreparedLines(prepared, maxWidth, profile)
  LayoutResult(lineCount: lineCount, height: float64(lineCount) * lineHeight)
