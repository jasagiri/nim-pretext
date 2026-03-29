import std/unittest
import nim_pretext/types
import nim_pretext/line_break

# ---------------------------------------------------------------------------
# Test helper: constructs real PreparedLineBreakData (no mocks)
# ---------------------------------------------------------------------------

proc makePrepared(
  widths: seq[float64],
  kinds: seq[SegmentBreakKind],
  breakableWidths: seq[seq[float64]] = @[],
  breakablePrefixWidths: seq[seq[float64]] = @[],
  simpleLineWalkFastPath: bool = true,
  discretionaryHyphenWidth: float64 = 0.0,
  tabStopAdvance: float64 = 0.0,
  chunks: seq[PreparedLineChunk] = @[],
): PreparedLineBreakData =
  let n = widths.len
  var bw = breakableWidths
  var bpw = breakablePrefixWidths
  if bw.len == 0:
    bw = newSeq[seq[float64]](n)
  if bpw.len == 0:
    bpw = newSeq[seq[float64]](n)

  var lineEndFit = newSeq[float64](n)
  var lineEndPaint = newSeq[float64](n)
  for i in 0 ..< n:
    let k = kinds[i]
    if k == SegmentBreakKind.space or k == SegmentBreakKind.preservedSpace or
       k == SegmentBreakKind.zeroWidthBreak:
      lineEndFit[i] = 0.0
    else:
      lineEndFit[i] = widths[i]
    if k == SegmentBreakKind.space or k == SegmentBreakKind.zeroWidthBreak:
      lineEndPaint[i] = 0.0
    else:
      lineEndPaint[i] = widths[i]

  var ch = chunks
  if ch.len == 0 and simpleLineWalkFastPath:
    ch = @[PreparedLineChunk(
      startSegmentIndex: 0,
      endSegmentIndex: n.int32,
      consumedEndSegmentIndex: n.int32,
    )]

  PreparedLineBreakData(
    widths: widths,
    lineEndFitAdvances: lineEndFit,
    lineEndPaintAdvances: lineEndPaint,
    kinds: kinds,
    simpleLineWalkFastPath: simpleLineWalkFastPath,
    breakableWidths: bw,
    breakablePrefixWidths: bpw,
    discretionaryHyphenWidth: discretionaryHyphenWidth,
    tabStopAdvance: tabStopAdvance,
    chunks: ch,
  )

# Helper: collect lines from walkPreparedLines
proc collectLines(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile = defaultEngineProfile,
): tuple[count: int32, lines: seq[InternalLayoutLine]] =
  var lines: seq[InternalLayoutLine] = @[]
  let count = walkPreparedLines(prepared, maxWidth, profile,
    proc(line: InternalLayoutLine) {.raises: [].} =
      lines.add(line)
  )
  (count, lines)

# Helper: assert count and walk produce same lineCount
proc assertCountWalkConsistent(
  prepared: PreparedLineBreakData,
  maxWidth: float64,
  profile: EngineProfile = defaultEngineProfile,
) =
  let countResult = countPreparedLines(prepared, maxWidth, profile)
  let (walkResult, _) = collectLines(prepared, maxWidth, profile)
  check countResult == walkResult

let profile = defaultEngineProfile

# ===========================================================================
suite "types - canBreakAfter":
# ===========================================================================

  test "Given each SegmentBreakKind / When canBreakAfter / Then correct result":
    check canBreakAfter(SegmentBreakKind.text) == false
    check canBreakAfter(SegmentBreakKind.space) == true
    check canBreakAfter(SegmentBreakKind.preservedSpace) == true
    check canBreakAfter(SegmentBreakKind.tab) == true
    check canBreakAfter(SegmentBreakKind.glue) == false
    check canBreakAfter(SegmentBreakKind.zeroWidthBreak) == true
    check canBreakAfter(SegmentBreakKind.softHyphen) == true
    check canBreakAfter(SegmentBreakKind.hardBreak) == false

  test "Given each SegmentBreakKind / When isSimpleCollapsibleSpace / Then only space":
    check isSimpleCollapsibleSpace(SegmentBreakKind.space) == true
    check isSimpleCollapsibleSpace(SegmentBreakKind.text) == false
    check isSimpleCollapsibleSpace(SegmentBreakKind.preservedSpace) == false
    check isSimpleCollapsibleSpace(SegmentBreakKind.tab) == false

# ===========================================================================
suite "Simple fast path - basic":
# ===========================================================================

  test "Given empty input / When counting lines / Then returns 0":
    let prepared = makePrepared(@[], @[])
    check countPreparedLines(prepared, 100.0, profile) == 0
    assertCountWalkConsistent(prepared, 100.0, profile)

  test "Given single segment fitting width / When counting lines / Then returns 1":
    let prepared = makePrepared(@[50.0], @[SegmentBreakKind.text])
    check countPreparedLines(prepared, 100.0, profile) == 1
    assertCountWalkConsistent(prepared, 100.0, profile)

  test "Given two words fitting in one line / When counting lines / Then returns 1":
    let prepared = makePrepared(
      @[40.0, 5.0, 40.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
    )
    check countPreparedLines(prepared, 100.0, profile) == 1
    assertCountWalkConsistent(prepared, 100.0, profile)

  test "Given two words not fitting in one line / When counting lines / Then returns 2":
    let prepared = makePrepared(
      @[40.0, 5.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
    )
    check countPreparedLines(prepared, 80.0, profile) == 2
    assertCountWalkConsistent(prepared, 80.0, profile)

  test "Given three words wrapping to two lines / When counting / Then returns 2":
    let prepared = makePrepared(
      @[30.0, 5.0, 30.0, 5.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text,
        SegmentBreakKind.space, SegmentBreakKind.text],
    )
    check countPreparedLines(prepared, 70.0, profile) == 2
    assertCountWalkConsistent(prepared, 70.0, profile)

# ===========================================================================
suite "Simple fast path - trailing space hang":
# ===========================================================================

  test "Given trailing space overflows / When counting / Then space hangs past edge":
    let prepared = makePrepared(
      @[40.0, 5.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space],
    )
    # 40 + 5 = 45 > 42 but space is collapsible, doesn't trigger break
    check countPreparedLines(prepared, 42.0, profile) == 1
    # NOTE: walkPreparedLinesSimple also returns 1 for this case because
    # canBreakAfter(space) triggers a line emit with paint width excluding the space,
    # then no remaining content → 1 line total. Count and walk agree here.
    assertCountWalkConsistent(prepared, 42.0, profile)

  test "Given multiple trailing spaces / When counting / Then all spaces hang":
    let prepared = makePrepared(
      @[40.0, 5.0, 5.0, 5.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space,
        SegmentBreakKind.space, SegmentBreakKind.space],
    )
    check countPreparedLines(prepared, 42.0, profile) == 1
    # CSS: collapsible spaces hang past edge, no break triggered.
    # count and walk must agree.
    assertCountWalkConsistent(prepared, 42.0, profile)

# ===========================================================================
suite "Simple fast path - overflow-wrap (breakable graphemes)":
# ===========================================================================

  test "Given oversized word with breakable graphemes / When counting / Then breaks at grapheme level":
    var bw = newSeq[seq[float64]](1)
    bw[0] = @[20.0, 20.0, 20.0, 20.0, 20.0]  # 5 graphemes @ 20px
    let prepared = makePrepared(
      @[100.0], @[SegmentBreakKind.text],
      breakableWidths = bw,
    )
    # maxWidth=50: 2 graphemes per line → 3 lines
    check countPreparedLines(prepared, 50.0, profile) == 3
    assertCountWalkConsistent(prepared, 50.0, profile)

  test "Given oversized word on fresh line / When walking / Then grapheme lines have correct cursors":
    var bw = newSeq[seq[float64]](1)
    bw[0] = @[15.0, 15.0, 15.0]
    let prepared = makePrepared(
      @[45.0], @[SegmentBreakKind.text],
      breakableWidths = bw,
    )
    let (count, lines) = collectLines(prepared, 25.0, profile)
    # 15+15=30>25 → each grapheme gets its own line
    check count == 3
    check lines[0].startSegmentIndex == 0
    check lines[0].startGraphemeIndex == 0
    check lines[0].endGraphemeIndex == 1  # exclusive: just grapheme 0
    check lines[1].startGraphemeIndex == 1
    check lines[2].startGraphemeIndex == 2

  test "Given word+space+oversizedWord / When overflow / Then breaks oversized at grapheme level":
    # Tests walkPreparedLinesSimple L236-240: breakable in overflow with pending break
    var bw = newSeq[seq[float64]](3)
    bw[2] = @[30.0, 30.0, 30.0]  # 3 graphemes @ 30px = 90px total
    let prepared = makePrepared(
      @[20.0, 5.0, 90.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
      breakableWidths = bw,
    )
    # maxWidth=50: text(20)+space(5)=25, +90 overflows.
    # Pending break at space → rewind: line1=[text,space] w=20
    # Then 90>50, breakable: 30+30=60>50, each grapheme on own line → 3 more lines
    # Total: 1 + 3 = 4 lines
    let (count, _) = collectLines(prepared, 50.0, profile)
    check count == 4
    assertCountWalkConsistent(prepared, 50.0, profile)

# ===========================================================================
suite "Simple fast path - pending break rewind":
# ===========================================================================

  test "Given word space word overflow / When pending break exists / Then rewinds to break":
    let prepared = makePrepared(
      @[30.0, 5.0, 30.0, 40.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space,
        SegmentBreakKind.text, SegmentBreakKind.text],
    )
    # maxWidth=70: 30+5+30=65 fits, +40=105 overflows, rewind to after space
    let (count, lines) = collectLines(prepared, 70.0, profile)
    check count == 2
    # Rewind to after space: pendingBreakSeg=2 means break before segment 2
    check lines[0].endSegmentIndex == 2
    check lines[0].width == 30.0  # paint width excludes trailing space
    assertCountWalkConsistent(prepared, 70.0, profile)

  test "Given unbreakable overflow without pending break / When no break point / Then emits line at current":
    # Tests the final fallback emitCurrentLine() — the bare emit with no rewind
    let prepared = makePrepared(
      @[50.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.text],
    )
    # maxWidth=80: 50+60=110 > 80, no pending break, text(60) not > maxWidth, no breakable
    # → fallback: emits current line (text(50)), then places text(60) on fresh line
    let (count, lines) = collectLines(prepared, 80.0, profile)
    check count == 2
    check lines[0].width == 50.0
    check lines[1].width == 60.0
    assertCountWalkConsistent(prepared, 80.0, profile)

# ===========================================================================
suite "Simple fast path - walk line details":
# ===========================================================================

  test "Given multiple words wrapping / When walking / Then line widths correct":
    let prepared = makePrepared(
      @[30.0, 5.0, 30.0, 5.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text,
        SegmentBreakKind.space, SegmentBreakKind.text],
    )
    let (count, lines) = collectLines(prepared, 70.0, profile)
    check count == 2
    check lines[0].width == 30.0 + 5.0 + 30.0
    check lines[1].startSegmentIndex == 4
    check lines[1].width == 30.0

  test "Given space as break point / When walking / Then paint width excludes trailing space":
    let prepared = makePrepared(
      @[40.0, 5.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
    )
    let (count, lines) = collectLines(prepared, 80.0, profile)
    check count == 2
    # First line: text(40) + space(5) → overflow at text(60)
    # canBreakAfter(space) → emitCurrentLine with width = lineW - w = lineW - 60 no...
    # Actually: space(5) triggers canBreakAfter, appendWholeSegment then emitCurrentLine
    # with paint width = lineW - w (w is the space width? no, w is text(60) at that point)
    check lines[0].width == 40.0  # paint width excludes trailing space

# ===========================================================================
suite "Simple fast path - zero-width-break":
# ===========================================================================

  test "Given zero-width-break between words / When overflow / Then breaks at zwb":
    let prepared = makePrepared(
      @[40.0, 0.0, 50.0],
      @[SegmentBreakKind.text, SegmentBreakKind.zeroWidthBreak, SegmentBreakKind.text],
    )
    # 40 + 0 + 50 = 90 > 80
    let (count, lines) = collectLines(prepared, 80.0, profile)
    check count == 2
    assertCountWalkConsistent(prepared, 80.0, profile)

# ===========================================================================
suite "Simple fast path - no content after overflow spaces":
# ===========================================================================

  test "Given only spaces / When counting / Then returns 1 (no content + 1)":
    let prepared = makePrepared(
      @[5.0, 5.0],
      @[SegmentBreakKind.space, SegmentBreakKind.space],
    )
    # All spaces are collapsible, hasContent stays false
    # countPreparedLinesSimple: not hasContent → lineCount + 1
    check countPreparedLines(prepared, 3.0, profile) == 1
    assertCountWalkConsistent(prepared, 3.0, profile)

# ===========================================================================
suite "Simple fast path - count/walk consistency":
# ===========================================================================

  test "Given various inputs / When count vs walk / Then always consistent":
    let inputs = @[
      # (widths, kinds, maxWidth)
      makePrepared(@[10.0], @[SegmentBreakKind.text]),
      makePrepared(@[100.0, 5.0, 100.0],
        @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text]),
      makePrepared(@[10.0, 5.0, 10.0, 5.0, 10.0, 5.0, 10.0],
        @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text,
          SegmentBreakKind.space, SegmentBreakKind.text, SegmentBreakKind.space,
          SegmentBreakKind.text]),
    ]
    let widths = @[20.0, 50.0, 100.0, 200.0, 500.0]
    for p in inputs:
      for w in widths:
        assertCountWalkConsistent(p, w, profile)

# ===========================================================================
suite "Complex path - hard-break":
# ===========================================================================

  test "Given text with hard-break / When counting / Then splits at hard-break":
    let prepared = makePrepared(
      @[40.0, 0.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.hardBreak, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 1, consumedEndSegmentIndex: 2),
        PreparedLineChunk(startSegmentIndex: 2, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    check countPreparedLines(prepared, 200.0, profile) == 2
    assertCountWalkConsistent(prepared, 200.0, profile)

  test "Given empty chunk (trailing newline) / When counting / Then counts empty line":
    let prepared = makePrepared(
      @[40.0, 0.0],
      @[SegmentBreakKind.text, SegmentBreakKind.hardBreak],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 1, consumedEndSegmentIndex: 2),
        PreparedLineChunk(startSegmentIndex: 2, endSegmentIndex: 2, consumedEndSegmentIndex: 2),
      ],
    )
    check countPreparedLines(prepared, 200.0, profile) == 2
    assertCountWalkConsistent(prepared, 200.0, profile)

  test "Given multiple consecutive hard-breaks / When counting / Then each produces a line":
    let prepared = makePrepared(
      @[0.0, 0.0, 0.0],
      @[SegmentBreakKind.hardBreak, SegmentBreakKind.hardBreak, SegmentBreakKind.hardBreak],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 0, consumedEndSegmentIndex: 1),
        PreparedLineChunk(startSegmentIndex: 1, endSegmentIndex: 1, consumedEndSegmentIndex: 2),
        PreparedLineChunk(startSegmentIndex: 2, endSegmentIndex: 2, consumedEndSegmentIndex: 3),
        PreparedLineChunk(startSegmentIndex: 3, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    check countPreparedLines(prepared, 200.0, profile) == 4
    assertCountWalkConsistent(prepared, 200.0, profile)

  test "Given complex path with onLine callback / When walking / Then emits lines":
    let prepared = makePrepared(
      @[40.0, 0.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.hardBreak, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 1, consumedEndSegmentIndex: 2),
        PreparedLineChunk(startSegmentIndex: 2, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    let (count, lines) = collectLines(prepared, 200.0, profile)
    check count == 2
    check lines[0].width == 40.0
    check lines[1].width == 30.0

# ===========================================================================
suite "Complex path - tabs":
# ===========================================================================

  test "Given tabs / When counting / Then tab advance is computed":
    let prepared = makePrepared(
      @[30.0, 0.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.tab, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      tabStopAdvance = 40.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # word(30) + tab-advance(40 - 30%40 = 10) + word(30) = 70
    check countPreparedLines(prepared, 100.0, profile) == 1
    check countPreparedLines(prepared, 60.0, profile) == 2
    assertCountWalkConsistent(prepared, 100.0, profile)
    assertCountWalkConsistent(prepared, 60.0, profile)

  test "Given tab on exact boundary / When computing advance / Then full tab stop":
    # lineWidth=40, tabStopAdvance=40 → remainder≈0 → advance = 40
    let prepared = makePrepared(
      @[40.0, 0.0, 10.0],
      @[SegmentBreakKind.text, SegmentBreakKind.tab, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      tabStopAdvance = 40.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # word(40) + tab(40, exactly on boundary) + word(10) = 90
    check countPreparedLines(prepared, 100.0, profile) == 1
    check countPreparedLines(prepared, 80.0, profile) == 2
    assertCountWalkConsistent(prepared, 100.0, profile)

  test "Given zero tabStopAdvance / When computing / Then tab advance is 0":
    let prepared = makePrepared(
      @[30.0, 0.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.tab, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      tabStopAdvance = 0.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # word(30) + tab(0) + word(30) = 60
    check countPreparedLines(prepared, 100.0, profile) == 1
    assertCountWalkConsistent(prepared, 100.0, profile)

# ===========================================================================
suite "Complex path - soft-hyphens":
# ===========================================================================

  test "Given soft-hyphen between words / When fits / Then no break at hyphen":
    let prepared = makePrepared(
      @[30.0, 0.0, 30.0],
      @[SegmentBreakKind.text, SegmentBreakKind.softHyphen, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      discretionaryHyphenWidth = 5.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # 30 + 0 (soft-hyphen zero width) + 30 = 60 fits in 100
    check countPreparedLines(prepared, 100.0, profile) == 1
    assertCountWalkConsistent(prepared, 100.0, profile)

  test "Given soft-hyphen before overflow / When overflow / Then breaks at hyphen":
    let prepared = makePrepared(
      @[30.0, 0.0, 50.0],
      @[SegmentBreakKind.text, SegmentBreakKind.softHyphen, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      discretionaryHyphenWidth = 5.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # 30 + 0 + 50 = 80 > 70 → break at soft-hyphen
    # pending break fit width = 30 + 5 = 35 <= 70 ✓
    check countPreparedLines(prepared, 70.0, profile) == 2
    assertCountWalkConsistent(prepared, 70.0, profile)

  test "Given preferEarlySoftHyphenBreak / When overflow with soft-hyphen / Then prefers early break":
    let prepared = makePrepared(
      @[30.0, 0.0, 50.0],
      @[SegmentBreakKind.text, SegmentBreakKind.softHyphen, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      discretionaryHyphenWidth = 5.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    let earlyProfile = EngineProfile(
      lineFitEpsilon: 1e-3,
      preferPrefixWidthsForBreakableRuns: false,
      preferEarlySoftHyphenBreak: true,

    )
    check countPreparedLines(prepared, 70.0, earlyProfile) == 2
    assertCountWalkConsistent(prepared, 70.0, earlyProfile)

  test "Given soft-hyphen with breakable continuation / When overflow / Then fits graphemes after hyphen":
    # continueSoftHyphenBreakableSegment: soft-hyphen pending, next segment has breakable widths
    var bw = newSeq[seq[float64]](3)
    bw[2] = @[10.0, 10.0, 10.0, 10.0, 10.0]  # 5 graphemes at 10px
    let prepared = makePrepared(
      @[30.0, 0.0, 50.0],
      @[SegmentBreakKind.text, SegmentBreakKind.softHyphen, SegmentBreakKind.text],
      breakableWidths = bw,
      simpleLineWalkFastPath = false,
      discretionaryHyphenWidth = 5.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # 30 + 50 = 80 > 60, pending soft-hyphen
    # continueSoftHyphenBreakableSegment: tries to fit graphemes of seg[2]
    # lineW=30, maxWidth=60, hyphenWidth=5
    # fitSoftHyphenBreak: fit graphemes while lineW + grapheme + hyphenWidth <= 60
    # 30+10+5=45 ✓, 30+20+5=55 ✓, 30+30=60 (last, no hyphen needed) ✓ → fitCount=3?
    # Actually: fitCount=2 (30+10+5=45 ✓, 30+20+5=55 ✓), 3rd: 30+30+5=65 > 60
    # Wait: cumulativeWidths depends on whether prefix widths are used
    # With non-prefix: fittedWidth = 30+10=40, +10=50, next: 50+10+5=65>60 → fitCount=2
    check countPreparedLines(prepared, 60.0, profile) == 2
    assertCountWalkConsistent(prepared, 60.0, profile)

  test "Given soft-hyphen without content before / When at line start / Then skipped":
    let prepared = makePrepared(
      @[0.0, 30.0],
      @[SegmentBreakKind.softHyphen, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      discretionaryHyphenWidth = 5.0,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 2, consumedEndSegmentIndex: 2),
      ],
    )
    # soft-hyphen at start with no content: skip
    check countPreparedLines(prepared, 100.0, profile) == 1
    assertCountWalkConsistent(prepared, 100.0, profile)

# ===========================================================================
suite "Complex path - preserved-space":
# ===========================================================================

  test "Given preserved-space / When overflow / Then can break at preserved-space":
    let prepared = makePrepared(
      @[40.0, 5.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.preservedSpace, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # 40 + 5 + 60 = 105 > 80
    # preserved-space is breakable (canBreakAfter = true)
    check countPreparedLines(prepared, 80.0, profile) == 2
    assertCountWalkConsistent(prepared, 80.0, profile)

# ===========================================================================
suite "Complex path - pending break rewind":
# ===========================================================================

  test "Given complex overflow with pending break / When rewinding / Then breaks at pending":
    let prepared = makePrepared(
      @[30.0, 5.0, 30.0, 40.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space,
        SegmentBreakKind.text, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 4, consumedEndSegmentIndex: 4),
      ],
    )
    # 30+5+30=65 fits in 70, +40=105 overflows, rewind to after space
    let (count, _) = collectLines(prepared, 70.0, profile)
    check count == 2
    assertCountWalkConsistent(prepared, 70.0, profile)

  test "Given complex breakable overflow / When segment > maxWidth / Then grapheme break":
    var bw = newSeq[seq[float64]](3)
    bw[2] = @[30.0, 30.0, 30.0]
    let prepared = makePrepared(
      @[20.0, 5.0, 90.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
      breakableWidths = bw,
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 3, consumedEndSegmentIndex: 3),
      ],
    )
    # text(20)+space(5)=25 fits, +90 overflows, pending break → line1
    # 90>50, 3 graphemes@30: 30+30=60>50 → 3 grapheme lines
    # Total: 1 + 3 = 4
    check countPreparedLines(prepared, 50.0, profile) == 4
    assertCountWalkConsistent(prepared, 50.0, profile)

  test "Given complex unbreakable overflow / When no break point / Then fallback emitCurrentLine":
    # Tests the bare emitCurrentLine() fallback at L477
    let prepared = makePrepared(
      @[50.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 2, consumedEndSegmentIndex: 2),
      ],
    )
    let (countC, _) = collectLines(prepared, 80.0, profile)
    check countC == 2
    assertCountWalkConsistent(prepared, 80.0, profile)

# ===========================================================================
suite "Complex path - empty/edge cases":
# ===========================================================================

  test "Given empty widths with empty chunks / When counting / Then returns 0":
    let prepared = makePrepared(
      @[], @[],
      simpleLineWalkFastPath = false,
      chunks = @[],
    )
    check countPreparedLines(prepared, 100.0, profile) == 0

  test "Given non-empty widths with empty chunks / When counting / Then returns 0":
    let prepared = makePrepared(
      @[10.0], @[SegmentBreakKind.text],
      simpleLineWalkFastPath = false,
      chunks = @[],
    )
    check countPreparedLines(prepared, 100.0, profile) == 0

  test "Given chunk final paint width with pending break at consumedEnd / When counting / Then uses pending paint width":
    let prepared = makePrepared(
      @[30.0, 5.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space],
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 2, consumedEndSegmentIndex: 2),
      ],
    )
    let (count, lines) = collectLines(prepared, 100.0, profile)
    check count == 1
    # The pending break at space points to consumedEndSegmentIndex=2
    # So final paint width should exclude trailing space
    check lines[0].width == 30.0

# ===========================================================================
suite "Complex path - breakable on fresh line":
# ===========================================================================

  test "Given oversized word at chunk start / When on fresh line / Then grapheme break":
    var bw = newSeq[seq[float64]](1)
    bw[0] = @[30.0, 30.0, 30.0]
    let prepared = makePrepared(
      @[90.0],
      @[SegmentBreakKind.text],
      breakableWidths = bw,
      simpleLineWalkFastPath = false,
      chunks = @[
        PreparedLineChunk(startSegmentIndex: 0, endSegmentIndex: 1, consumedEndSegmentIndex: 1),
      ],
    )
    # 3 graphemes@30px, maxWidth=50: 30+30=60>50 → 3 lines (1 per grapheme)
    check countPreparedLines(prepared, 50.0, profile) == 3
    assertCountWalkConsistent(prepared, 50.0, profile)

# ===========================================================================
suite "getBreakableAdvance - prefix widths":
# ===========================================================================

  test "Given preferPrefixWidths=true / When computing / Then uses prefix width differences":
    let prefixProfile = EngineProfile(
      lineFitEpsilon: 1e-3,
      preferPrefixWidthsForBreakableRuns: true,
      preferEarlySoftHyphenBreak: false,

    )
    var bw = newSeq[seq[float64]](1)
    bw[0] = @[10.0, 12.0, 11.0]  # individual widths
    var bpw = newSeq[seq[float64]](1)
    bpw[0] = @[10.0, 22.0, 33.0]  # cumulative prefix widths

    let prepared = makePrepared(
      @[33.0], @[SegmentBreakKind.text],
      breakableWidths = bw,
      breakablePrefixWidths = bpw,
    )
    # With prefix widths: grapheme 0 = 10, grapheme 1 = 22-10 = 12, grapheme 2 = 33-22 = 11
    # maxWidth=25: 10+12=22 fits, +11=33 > 25 → 2 lines
    check countPreparedLines(prepared, 25.0, prefixProfile) == 2
    assertCountWalkConsistent(prepared, 25.0, prefixProfile)

# ===========================================================================
suite "layout API":
# ===========================================================================

  test "Given prepared data / When layout / Then returns lineCount and height":
    let prepared = makePrepared(
      @[40.0, 5.0, 60.0],
      @[SegmentBreakKind.text, SegmentBreakKind.space, SegmentBreakKind.text],
    )
    let result = layout(prepared, 80.0, 20.0, profile)
    check result.lineCount == 2
    check result.height == 40.0

  test "Given single line / When layout with lineHeight / Then height equals lineHeight":
    let prepared = makePrepared(
      @[50.0], @[SegmentBreakKind.text],
    )
    let result = layout(prepared, 100.0, 24.0, profile)
    check result.lineCount == 1
    check result.height == 24.0

  test "Given empty input / When layout / Then zero lines and zero height":
    let prepared = makePrepared(@[], @[])
    let result = layout(prepared, 100.0, 20.0, profile)
    check result.lineCount == 0
    check result.height == 0.0
