## Compact, in-memory terminal scrollback storage.

import std/deques

import ./[termscreen, termsessions]

const
  SegmentLineCapacity = 256
  TokenKindBits = 2
  TokenKindMask = 0b11'u
  BlankRunToken = 0'u
  AsciiRunToken = 1'u
  TextCellToken = 2'u
  StyleToken = 3'u

type
  CompactScrollbackSegment = object
    data: seq[byte]
    lineOffsets: seq[uint32]
    styles: seq[TerminexStyle]
    payloadByteCount: int

  CompactScrollback*[Cell, Line] = object
    ## Capacity-bounded scrollback that encodes immutable terminal lines.
    ##
    ## Lines are divided into independently reclaimable segments. Styles are
    ## interned per segment, trailing default cells are implicit, and common
    ## blank and single-byte text cells are stored as runs.
    segments: Deque[CompactScrollbackSegment]
    firstLineInSegment: int
    lineCount: int
    capacity: int
    segmentLineCapacity: int
    payloadByteCount: int

  CompactTerminalScreen*[Cell = TerminexCell] =
    TerminexScreen[Cell, seq[Cell], CompactScrollback[Cell, seq[Cell]]]

  CompactTerminalSession*[Cell = TerminexCell] =
    TerminexSession[Cell, seq[Cell], CompactScrollback[Cell, seq[Cell]]]

func initCompactScrollback*[Cell, Line](capacity: int): CompactScrollback[Cell, Line] =
  ## Initialize compact scrollback with a fixed non-negative line capacity.
  CompactScrollback[Cell, Line](
    segments: initDeque[CompactScrollbackSegment](),
    capacity: max(capacity, 0),
    segmentLineCapacity: clamp(capacity, 1, SegmentLineCapacity),
  )

func initScrollback*[Cell, Line](
    _: typedesc[CompactScrollback[Cell, Line]], capacity: int
): CompactScrollback[Cell, Line] =
  ## Initialize compact storage for `TerminexScreen`.
  initCompactScrollback[Cell, Line](capacity)

func len*[Cell, Line](scrollback: CompactScrollback[Cell, Line]): int =
  scrollback.lineCount

func cap*[Cell, Line](scrollback: CompactScrollback[Cell, Line]): int =
  scrollback.capacity

proc addVarUInt(data: var seq[byte], value: uint) =
  var remaining = value
  while remaining >= 0x80:
    data.add(byte((remaining and 0x7f) or 0x80))
    remaining = remaining shr 7
  data.add(byte(remaining))

func readVarUInt(data: seq[byte], position: var int): uint =
  var shift = 0
  while position < data.len and shift < sizeof(uint) * 8:
    let current = data[position]
    inc position
    result = result or (uint(current and 0x7f) shl shift)
    if (current and 0x80) == 0:
      return
    shift += 7
  raise newException(AssertionDefect, "corrupt compact scrollback integer")

proc addText(data: var seq[byte], text: string) =
  for character in text:
    data.add(byte(character))

func readText(data: seq[byte], position: var int, length: uint): string =
  if length > uint(data.len - position):
    raise newException(AssertionDefect, "corrupt compact scrollback text")
  let byteCount = int(length)
  result = newString(byteCount)
  for index in 0 ..< byteCount:
    result[index] = char(data[position + index])
  position += byteCount

func initCompactScrollbackSegment(): CompactScrollbackSegment =
  CompactScrollbackSegment(
    styles: @[initTerminalStyle()], payloadByteCount: sizeof(TerminexStyle)
  )

proc styleId(segment: var CompactScrollbackSegment, style: TerminexStyle): uint =
  for index, storedStyle in segment.styles:
    if storedStyle == style:
      return uint(index)
  segment.styles.add(style)
  segment.payloadByteCount += sizeof(TerminexStyle) + style.hyperlink.len
  uint(segment.styles.high)

func isDefaultCell[Cell](cell: Cell): bool =
  mixin cellContinuation, cellStyle, cellText
  cell.cellText.len == 0 and not cell.cellContinuation and
    cell.cellStyle == initTerminalStyle()

proc encodeLine[Cell, Line](segment: var CompactScrollbackSegment, line: Line) =
  mixin cellContinuation, cellStyle, cellText, len, `[]`
  if uint64(segment.data.len) > uint64(high(uint32)):
    raise newException(OverflowDefect, "compact scrollback segment is too large")
  let previousDataLength = segment.data.len
  segment.lineOffsets.add(uint32(segment.data.len))

  var storedCells = line.len
  while storedCells > 0 and line[storedCells - 1].isDefaultCell:
    dec storedCells

  segment.data.addVarUInt(uint(line.len))
  segment.data.addVarUInt(uint(storedCells))

  var
    column = 0
    currentStyle = initTerminalStyle()
  while column < storedCells:
    let
      cell = line[column]
      style = cell.cellStyle
    if style != currentStyle:
      let token = (segment.styleId(style) shl TokenKindBits) or StyleToken
      segment.data.addVarUInt(token)
      currentStyle = style

    let text = cell.cellText
    if text.len == 0 and not cell.cellContinuation:
      var runLength = 1
      while column + runLength < storedCells:
        let nextCell = line[column + runLength]
        if nextCell.cellText.len != 0 or nextCell.cellContinuation or
            nextCell.cellStyle != currentStyle:
          break
        inc runLength
      let token = (uint(runLength) shl TokenKindBits) or BlankRunToken
      segment.data.addVarUInt(token)
      column += runLength
    elif text.len == 1 and ord(text[0]) < 0x80 and not cell.cellContinuation:
      var runLength = 1
      while column + runLength < storedCells:
        let nextCell = line[column + runLength]
        if nextCell.cellText.len != 1 or ord(nextCell.cellText[0]) >= 0x80 or
            nextCell.cellContinuation or nextCell.cellStyle != currentStyle:
          break
        inc runLength
      let token = (uint(runLength) shl TokenKindBits) or AsciiRunToken
      segment.data.addVarUInt(token)
      for index in column ..< column + runLength:
        segment.data.add(byte(line[index].cellText[0]))
      column += runLength
    else:
      let
        cellPayload = (uint(text.len) shl 1) or uint(cell.cellContinuation)
        token = (cellPayload shl TokenKindBits) or TextCellToken
      segment.data.addVarUInt(token)
      segment.data.addText(text)
      inc column
  segment.payloadByteCount += sizeof(uint32) + segment.data.len - previousDataLength

func decodeLine[Cell, Line](segment: CompactScrollbackSegment, lineIndex: int): Line =
  mixin `[]=`, `cellContinuation=`, initTerminalCell, initTerminalLine
  var position = int(segment.lineOffsets[lineIndex])
  let
    columnCount = int(segment.data.readVarUInt(position))
    storedCells = int(segment.data.readVarUInt(position))
  if storedCells > columnCount:
    raise newException(AssertionDefect, "corrupt compact scrollback line")

  let defaultStyle = segment.styles[0]
  result = initTerminalLine(Line, columnCount)
  for column in 0 ..< columnCount:
    result[column] = initTerminalCell(Cell, "", defaultStyle)

  var
    column = 0
    currentStyleId = 0
  while column < storedCells:
    let
      token = segment.data.readVarUInt(position)
      kind = token and TokenKindMask
      payload = token shr TokenKindBits
    case kind
    of StyleToken:
      if payload >= uint(segment.styles.len):
        raise newException(AssertionDefect, "corrupt compact scrollback style")
      currentStyleId = int(payload)
    of BlankRunToken:
      let runLength = int(payload)
      if runLength == 0 or runLength > storedCells - column:
        raise newException(AssertionDefect, "corrupt compact scrollback blank run")
      for index in column ..< column + runLength:
        result[index] = initTerminalCell(Cell, "", segment.styles[currentStyleId])
      column += runLength
    of AsciiRunToken:
      let runLength = int(payload)
      if runLength == 0 or runLength > storedCells - column or
          runLength > segment.data.len - position:
        raise newException(AssertionDefect, "corrupt compact scrollback text run")
      for index in column ..< column + runLength:
        var text = newString(1)
        text[0] = char(segment.data[position])
        inc position
        result[index] = initTerminalCell(Cell, text, segment.styles[currentStyleId])
      column += runLength
    of TextCellToken:
      let
        continuation = (payload and 1) != 0
        textLength = payload shr 1
        text = segment.data.readText(position, textLength)
      var cell = initTerminalCell(Cell, text, segment.styles[currentStyleId])
      cell.cellContinuation = continuation
      result[column] = cell
      inc column
    else:
      raise newException(AssertionDefect, "corrupt compact scrollback token")

proc dropFirst[Cell, Line](scrollback: var CompactScrollback[Cell, Line]) =
  inc scrollback.firstLineInSegment
  dec scrollback.lineCount
  if scrollback.firstLineInSegment == scrollback.segments.peekFirst.lineOffsets.len:
    let removedSegment = scrollback.segments.popFirst()
    scrollback.payloadByteCount -= removedSegment.payloadByteCount
    scrollback.firstLineInSegment = 0

proc add*[Cell, Line](scrollback: var CompactScrollback[Cell, Line], line: sink Line) =
  ## Encode and retain one immutable terminal line.
  if scrollback.capacity == 0:
    return
  if scrollback.segments.len == 0 or
      scrollback.segments.peekLast.lineOffsets.len == scrollback.segmentLineCapacity:
    scrollback.segments.addLast(initCompactScrollbackSegment())
    scrollback.payloadByteCount += scrollback.segments.peekLast.payloadByteCount
  let previousSegmentBytes = scrollback.segments.peekLast.payloadByteCount
  encodeLine[Cell, Line](scrollback.segments.peekLast(), line)
  scrollback.payloadByteCount +=
    scrollback.segments.peekLast.payloadByteCount - previousSegmentBytes
  inc scrollback.lineCount
  if scrollback.lineCount > scrollback.capacity:
    scrollback.dropFirst()

func `[]`*[Cell, Line](scrollback: CompactScrollback[Cell, Line], index: int): Line =
  ## Decode the line at `index` in logical history order.
  if index < 0 or index >= scrollback.lineCount:
    raise newException(IndexDefect, "compact scrollback index out of bounds")
  let
    physicalLine = scrollback.firstLineInSegment + index
    segmentIndex = physicalLine div scrollback.segmentLineCapacity
    lineIndex = physicalLine mod scrollback.segmentLineCapacity
  decodeLine[Cell, Line](scrollback.segments[segmentIndex], lineIndex)

iterator items*[Cell, Line](scrollback: CompactScrollback[Cell, Line]): Line =
  for index in 0 ..< scrollback.len:
    yield scrollback[index]

proc clear*[Cell, Line](scrollback: var CompactScrollback[Cell, Line]) =
  ## Remove all encoded lines and release their segments.
  scrollback.segments = initDeque[CompactScrollbackSegment]()
  scrollback.firstLineInSegment = 0
  scrollback.lineCount = 0
  scrollback.payloadByteCount = 0

func payloadBytes*[Cell, Line](scrollback: CompactScrollback[Cell, Line]): int =
  ## Estimate bytes retained by encoded data, indexes, and style values.
  ##
  ## Allocator bookkeeping, spare sequence capacity, and shared string headers
  ## are intentionally excluded.
  scrollback.payloadByteCount

static:
  doAssert CompactScrollback[TerminexCell, TerminexLine] is
    TerminexScrollbackAdapter[TerminexLine]

proc initCompactTerminalScreen*[Cell: TerminexCellAdapter](
    _: typedesc[Cell],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalScreen[Cell] =
  ## Construct a custom-cell screen with compact in-memory scrollback.
  initTerminalScreen(CompactTerminalScreen[Cell], columns, rows, maxScrollback)

proc initCompactTerminalScreen*(
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalScreen[TerminexCell] =
  ## Construct a default-cell screen with compact in-memory scrollback.
  initCompactTerminalScreen(TerminexCell, columns, rows, maxScrollback)

proc newCompactTerminalSession*[Cell: TerminexCellAdapter](
    _: typedesc[Cell],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalSession[Cell] =
  ## Construct a custom-cell session with compact in-memory scrollback.
  newTerminalSession(CompactTerminalScreen[Cell], columns, rows, maxScrollback)

proc newCompactTerminalSession*(
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalSession[TerminexCell] =
  ## Construct a default-cell session with compact in-memory scrollback.
  newCompactTerminalSession(TerminexCell, columns, rows, maxScrollback)

proc spawnCompactTerminalSession*[Cell: TerminexCellAdapter](
    _: typedesc[Cell],
    options = initTerminalSpawnOptions(),
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalSession[Cell] =
  ## Spawn a custom-cell session with compact in-memory scrollback.
  spawnTerminalSession(
    CompactTerminalScreen[Cell], options, columns, rows, maxScrollback
  )

proc spawnCompactTerminalSession*(
    options = initTerminalSpawnOptions(),
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): CompactTerminalSession[TerminexCell] =
  ## Spawn a default-cell session with compact in-memory scrollback.
  spawnCompactTerminalSession(TerminexCell, options, columns, rows, maxScrollback)
