## Core types for nim-pretext layout engine.
## Mirrors the PreparedLineBreakData from pretext's line-break.ts.

type
  SegmentBreakKind* {.pure.} = enum
    text = 0
    space = 1
    preservedSpace = 2
    tab = 3
    glue = 4
    zeroWidthBreak = 5
    softHyphen = 6
    hardBreak = 7

  PreparedLineChunk* = object
    startSegmentIndex*: int32
    endSegmentIndex*: int32
    consumedEndSegmentIndex*: int32

  EngineProfile* = object
    lineFitEpsilon*: float64
    preferPrefixWidthsForBreakableRuns*: bool
    preferEarlySoftHyphenBreak*: bool

  ## Struct-of-arrays layout data. For native Nim use with seq[].
  PreparedLineBreakData* = object
    widths*: seq[float64]
    lineEndFitAdvances*: seq[float64]
    lineEndPaintAdvances*: seq[float64]
    kinds*: seq[SegmentBreakKind]
    simpleLineWalkFastPath*: bool
    breakableWidths*: seq[seq[float64]]       ## per-segment grapheme widths; empty seq = null
    breakablePrefixWidths*: seq[seq[float64]] ## cumulative prefix widths; empty seq = null
    discretionaryHyphenWidth*: float64
    tabStopAdvance*: float64
    chunks*: seq[PreparedLineChunk]

  LineBreakCursor* = object
    segmentIndex*: int32
    graphemeIndex*: int32

  InternalLayoutLine* = object
    startSegmentIndex*: int32
    startGraphemeIndex*: int32
    endSegmentIndex*: int32
    endGraphemeIndex*: int32
    width*: float64

  LayoutResult* = object
    lineCount*: int32
    height*: float64

const defaultEngineProfile* = EngineProfile(
  lineFitEpsilon: 1e-3,
  preferPrefixWidthsForBreakableRuns: false,
  preferEarlySoftHyphenBreak: false,
)

proc canBreakAfter*(kind: SegmentBreakKind): bool {.inline, raises: [].} =
  kind in {SegmentBreakKind.space, SegmentBreakKind.preservedSpace,
           SegmentBreakKind.tab, SegmentBreakKind.zeroWidthBreak,
           SegmentBreakKind.softHyphen}

proc isSimpleCollapsibleSpace*(kind: SegmentBreakKind): bool {.inline, raises: [].} =
  kind == SegmentBreakKind.space
