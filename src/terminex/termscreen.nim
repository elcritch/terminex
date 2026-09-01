## Terminal screen state independent of rendering and process transport.

import std/[sequtils, strutils, unicode]

import pkg/unicodedb/[properties, widths]

import ./ringbuffer

const
  DefaultTerminalColumns* = 80
  DefaultTerminalRows* = 24
  DefaultTerminalScrollback* = 10_000

type
  TerminalColorKind* = enum
    tckDefault
    tckIndexed
    tckRgb

  TerminalColor* = object
    case kind*: TerminalColorKind
    of tckDefault:
      discard
    of tckIndexed:
      index*: uint8
    of tckRgb:
      red*, green*, blue*: uint8

  TerminalAttribute* = enum
    taBold
    taFaint
    taItalic
    taUnderline
    taDoubleUnderline
    taBlink
    taInverse
    taHidden
    taStrikethrough
    taOverline

  TerminalStyle* = object
    foreground*, background*, underlineColor*: TerminalColor
    attributes*: set[TerminalAttribute]
    hyperlink*: string

  TerminalCell* = object
    text*: string
    style*: TerminalStyle
    continuation*: bool

  TerminalLine* = seq[TerminalCell]

  TerminalPosition* = object
    row*, column*: int

  TerminalCursorShape* = enum
    tcsBlock
    tcsUnderline
    tcsBar

  TerminalMouseTracking* = enum
    tmtNone
    tmtX10
    tmtButton
    tmtAny

  TerminalMouseEncoding* = enum
    tmeX10
    tmeUtf8
    tmeSgr
    tmeUrxvt

  TerminalModes* = object
    insert*: bool
    origin*: bool
    autoWrap*: bool
    applicationCursorKeys*: bool
    applicationKeypad*: bool
    bracketedPaste*: bool
    focusReporting*: bool
    alternateScroll*: bool
    mouseTracking*: TerminalMouseTracking
    mouseEncoding*: TerminalMouseEncoding

  TerminalCursor* = object
    position*: TerminalPosition
    visible*: bool
    blinking*: bool
    shape*: TerminalCursorShape

  TerminalSavedState = object
    cursor: TerminalCursor
    style: TerminalStyle
    modes: TerminalModes
    wrapPending: bool

  ## A cell implementation accepted by `TerminalScreen`. Custom cell types
  ## supply the `initTerminalCell`, `cellText`, `cellStyle`, and
  ## `cellContinuation` accessors documented below.
  TerminalCellAdapter* =
    concept cell
        mixin initTerminalCell, cellText, cellStyle, cellContinuation
        var writable: typeof(cell)
        initTerminalCell(typeof(cell), "", initTerminalStyle()) is typeof(cell)
        cellText(cell) is string
        cellStyle(cell) is TerminalStyle
        cellContinuation(cell) is bool
        writable.cellText = ""
        writable.cellStyle = initTerminalStyle()
        writable.cellContinuation = false

  ## A line implementation accepted by `TerminalScreen`.
  TerminalLineAdapter*[Cell] =
    concept line
        mixin initTerminalLine, len, `[]`, `[]=`
        var writable: typeof(line)
        initTerminalLine(typeof(line), 1) is typeof(line)
        line.len is int
        line[0] is Cell
        writable[0] = line[0]

  TerminalScrollbackAdapter*[Line] = RingBufferStorageAdapter[Line]

  TerminalScreen*[Cell = TerminalCell, Line = seq[Cell], Scrollback = seq[Line]] = object
    columns*, rows*: int
    cells: seq[Cell]
    scrollback: RingBuffer[Line, Scrollback]
    rowOrigin: int
    cursor*: TerminalCursor
    style*: TerminalStyle
    modes*: TerminalModes
    scrollTop*, scrollBottom*: int
    title*, iconName*, currentDirectory*: string
    pendingReplies: seq[string]
    clipboardText*: string
    clipboardRequestPending*: bool
    bellCount*: uint64
    alternateScreen*: bool
    generation*: uint64
    tabStops: seq[bool]
    saved: TerminalSavedState
    primaryCells: seq[Cell]
    primaryRowOrigin: int
    primaryCursor: TerminalCursor
    primarySaved: TerminalSavedState
    wrapPending: bool
    lastPrintedText: string

const ZeroWidthCategories = ctgMn + ctgMe + ctgCf

func defaultTerminalColor*(): TerminalColor =
  TerminalColor(kind: tckDefault)

func indexedTerminalColor*(index: uint8): TerminalColor =
  TerminalColor(kind: tckIndexed, index: index)

func rgbTerminalColor*(red, green, blue: uint8): TerminalColor =
  TerminalColor(kind: tckRgb, red: red, green: green, blue: blue)

func `==`*(left, right: TerminalColor): bool =
  if left.kind != right.kind:
    return false
  case left.kind
  of tckDefault:
    true
  of tckIndexed:
    left.index == right.index
  of tckRgb:
    left.red == right.red and left.green == right.green and left.blue == right.blue

func initTerminalStyle*(): TerminalStyle =
  TerminalStyle(
    foreground: defaultTerminalColor(),
    background: defaultTerminalColor(),
    underlineColor: defaultTerminalColor(),
  )

func initTerminalCell*(text = "", style = initTerminalStyle()): TerminalCell =
  TerminalCell(text: text, style: style)

func initTerminalCell*(
    _: typedesc[TerminalCell], text = "", style = initTerminalStyle()
): TerminalCell =
  ## Default custom-cell constructor used by `TerminalScreen`.
  initTerminalCell(text, style)

func cellText*(cell: TerminalCell): string =
  cell.text

proc `cellText=`*(cell: var TerminalCell, text: string) =
  cell.text = text

func cellStyle*(cell: TerminalCell): TerminalStyle =
  cell.style

proc `cellStyle=`*(cell: var TerminalCell, style: TerminalStyle) =
  cell.style = style

func cellContinuation*(cell: TerminalCell): bool =
  cell.continuation

proc `cellContinuation=`*(cell: var TerminalCell, continuation: bool) =
  cell.continuation = continuation

func initTerminalLine*[Cell](_: typedesc[seq[Cell]], length: int): seq[Cell] =
  newSeq[Cell](length)

template makeCell(
    screen: typed, text = "", style = initTerminalStyle(), continuation = false
): untyped =
  mixin initTerminalCell, `cellContinuation=`
  block:
    var result = initTerminalCell(typeof(screen.cells[0]), text, style)
    result.cellContinuation = continuation
    result

static:
  doAssert TerminalCell is TerminalCellAdapter
  doAssert TerminalLine is TerminalLineAdapter[TerminalCell]
  doAssert seq[TerminalLine] is TerminalScrollbackAdapter[TerminalLine]

func initTerminalPosition*(row, column: int): TerminalPosition =
  TerminalPosition(row: row, column: column)

func initTerminalModes*(): TerminalModes =
  TerminalModes(autoWrap: true, mouseEncoding: tmeX10)

func initTerminalCursor*(): TerminalCursor =
  TerminalCursor(visible: true, blinking: true, shape: tcsBlock)

func cellIndex[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], row, column: int
): int =
  ((screen.rowOrigin + row) mod screen.rows) * screen.columns + column

func contains*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], position: TerminalPosition
): bool =
  position.row in 0 ..< screen.rows and position.column in 0 ..< screen.columns

func cellAt*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], row, column: int
): lent Cell =
  screen.cells[screen.cellIndex(row, column)]

func lineAt*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], row: int
): Line =
  mixin initTerminalLine, `[]=`
  result = initTerminalLine(Line, screen.columns)
  for column in 0 ..< screen.columns:
    result[column] = screen.cellAt(row, column)

iterator scrollbackLines*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback]
): Line =
  for index in 0 ..< screen.scrollback.len:
    yield screen.scrollback[index]

func scrollbackCount*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback]
): int =
  screen.scrollback.len

func maxScrollback*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback]
): int =
  screen.scrollback.cap

func totalLineCount*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback]
): int =
  ## Return the number of addressable scrollback and live-screen lines.
  screen.scrollback.len + screen.rows

func lineAtAbsolute*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], index: int
): Line =
  ## Return a line from the combined scrollback and live-screen history.
  ##
  ## Scrollback occupies the first indexes and the current screen the last
  ## `rows` indexes. An out-of-range index returns an empty line.
  mixin initTerminalLine
  if index < 0 or index >= screen.totalLineCount():
    return initTerminalLine(Line, 0)
  if index < screen.scrollback.len:
    return screen.scrollback[index]
  screen.lineAt(index - screen.scrollback.len)

func pendingReplies*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback]
): seq[string] =
  screen.pendingReplies

proc takePendingReplies*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
): seq[string] =
  result = move(screen.pendingReplies)
  screen.pendingReplies = @[]

proc markChanged[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  inc screen.generation

proc ringBell*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  inc screen.bellCount
  screen.markChanged()

proc takeClipboardRequest*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
): string =
  ## Consume text requested by an OSC 52 clipboard-write sequence.
  if not screen.clipboardRequestPending:
    return
  screen.clipboardRequestPending = false
  screen.clipboardText

proc resetTabStops[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.tabStops = newSeq[bool](screen.columns)
  for column in 0 ..< screen.columns:
    screen.tabStops[column] = column > 0 and column mod 8 == 0

proc initTerminalScreen*[
    Cell: TerminalCellAdapter,
    Line: TerminalLineAdapter[Cell],
    Scrollback: TerminalScrollbackAdapter[Line],
](
    _: typedesc[TerminalScreen[Cell, Line, Scrollback]],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminalScreen[Cell, Line, Scrollback] =
  result.columns = max(columns, 1)
  result.rows = max(rows, 1)
  result.cells = newSeqWith(result.columns * result.rows, result.makeCell())
  result.scrollback = initRingBuffer(RingBuffer[Line, Scrollback], maxScrollback)
  result.cursor = initTerminalCursor()
  result.style = initTerminalStyle()
  result.modes = initTerminalModes()
  result.scrollBottom = result.rows - 1
  result.resetTabStops()

proc initTerminalScreen*[Cell: TerminalCellAdapter](
    _: typedesc[Cell],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminalScreen[Cell, seq[Cell], seq[seq[Cell]]] =
  ## Construct a custom-cell screen with sequence-backed lines and scrollback.
  initTerminalScreen(
    TerminalScreen[Cell, seq[Cell], seq[seq[Cell]]], columns, rows, maxScrollback
  )

proc initTerminalScreen*(
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminalScreen[TerminalCell, TerminalLine, seq[TerminalLine]] =
  ## Construct the default `TerminalCell`/`TerminalLine` screen.
  initTerminalScreen(
    TerminalScreen[TerminalCell, TerminalLine, seq[TerminalLine]],
    columns,
    rows,
    maxScrollback,
  )

proc setCell[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], row, column: int, cell: Cell
) =
  if screen.contains(initTerminalPosition(row, column)):
    screen.cells[screen.cellIndex(row, column)] = cell

proc clearWideCell[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], row, column: int
) =
  mixin cellContinuation
  if not screen.contains(initTerminalPosition(row, column)):
    return
  let cell = screen.cellAt(row, column)
  if cell.cellContinuation and column > 0:
    screen.setCell(row, column - 1, screen.makeCell())
    screen.setCell(row, column, screen.makeCell())
  elif column + 1 < screen.columns and screen.cellAt(row, column + 1).cellContinuation:
    screen.setCell(row, column, screen.makeCell())
    screen.setCell(row, column + 1, screen.makeCell())

proc clearRange[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback],
    row, firstColumn, lastColumn: int,
) =
  if row notin 0 ..< screen.rows:
    return
  let
    first = clamp(firstColumn, 0, screen.columns - 1)
    last = clamp(lastColumn, 0, screen.columns - 1)
  if first > last:
    return
  screen.clearWideCell(row, first)
  screen.clearWideCell(row, last)
  for column in first .. last:
    screen.setCell(row, column, screen.makeCell(style = screen.style))

proc clearLine[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], row: int
) =
  screen.clearRange(row, 0, screen.columns - 1)

proc clearScrollback*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  ## Remove saved history without changing the live terminal screen.
  if screen.scrollback.len == 0:
    return
  screen.scrollback.clear()
  screen.markChanged()

proc appendScrollback[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], line: sink Line
) =
  screen.scrollback.add(line)

proc replaceLine[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], row: int, line: Line
) =
  mixin len, `[]`
  for column in 0 ..< screen.columns:
    screen.setCell(
      row,
      column,
      if column < line.len:
        line[column]
      else:
        screen.makeCell(),
    )

proc scrollUp*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let amount = min(max(count, 0), screen.scrollBottom - screen.scrollTop + 1)
  if screen.scrollTop == 0 and screen.scrollBottom == screen.rows - 1:
    for _ in 0 ..< amount:
      screen.appendScrollback(screen.lineAt(0))
      screen.rowOrigin = (screen.rowOrigin + 1) mod screen.rows
      screen.clearLine(screen.rows - 1)
    if amount > 0:
      screen.markChanged()
    return
  for _ in 0 ..< amount:
    # A partial region can still feed terminal history when anchored at row 0.
    # Inline TUIs use this to keep a live composer below finalized output.
    if screen.scrollTop == 0:
      screen.appendScrollback(screen.lineAt(0))
    for row in screen.scrollTop ..< screen.scrollBottom:
      screen.replaceLine(row, screen.lineAt(row + 1))
    screen.clearLine(screen.scrollBottom)
  if amount > 0:
    screen.markChanged()

proc scrollDown*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let amount = min(max(count, 0), screen.scrollBottom - screen.scrollTop + 1)
  if screen.scrollTop == 0 and screen.scrollBottom == screen.rows - 1:
    for _ in 0 ..< amount:
      screen.rowOrigin = (screen.rowOrigin + screen.rows - 1) mod screen.rows
      screen.clearLine(0)
    if amount > 0:
      screen.markChanged()
    return
  for _ in 0 ..< amount:
    for row in countdown(screen.scrollBottom, screen.scrollTop + 1):
      screen.replaceLine(row, screen.lineAt(row - 1))
    screen.clearLine(screen.scrollTop)
  if amount > 0:
    screen.markChanged()

proc lineFeed*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.wrapPending = false
  if screen.cursor.position.row == screen.scrollBottom:
    screen.scrollUp()
  elif screen.cursor.position.row < screen.rows - 1:
    inc screen.cursor.position.row
    screen.markChanged()

proc reverseIndex*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.wrapPending = false
  if screen.cursor.position.row == screen.scrollTop:
    screen.scrollDown()
  elif screen.cursor.position.row > 0:
    dec screen.cursor.position.row
    screen.markChanged()

proc carriageReturn*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.cursor.position.column = 0
  screen.wrapPending = false
  screen.markChanged()

proc nextLine*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.lineFeed()
  screen.carriageReturn()

proc backspace*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.wrapPending = false
  if screen.cursor.position.column > 0:
    dec screen.cursor.position.column
    screen.markChanged()

proc horizontalTab*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.wrapPending = false
  for column in screen.cursor.position.column + 1 ..< screen.columns:
    if screen.tabStops[column]:
      screen.cursor.position.column = column
      screen.markChanged()
      return
  screen.cursor.position.column = screen.columns - 1
  screen.markChanged()

proc setTabStop*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.tabStops[screen.cursor.position.column] = true

proc clearTabStop*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], all = false
) =
  if all:
    for tabStop in screen.tabStops.mitems:
      tabStop = false
  else:
    screen.tabStops[screen.cursor.position.column] = false

proc terminalRuneWidth*(rune: Rune): int =
  let value = rune.int
  if value < 0x20 or value in 0x7f .. 0x9f:
    return 0
  if rune.unicodeCategory in ZeroWidthCategories:
    return 0
  case rune.unicodeWidth
  of uwdtWide, uwdtFull: 2
  else: 1

proc insertCells*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let
    column = screen.cursor.position.column
    amount = min(max(count, 0), screen.columns - column)
  if amount == 0:
    return
  screen.clearWideCell(screen.cursor.position.row, column)
  screen.clearWideCell(screen.cursor.position.row, screen.columns - amount)
  for target in countdown(screen.columns - 1, column + amount):
    screen.setCell(
      screen.cursor.position.row,
      target,
      screen.cellAt(screen.cursor.position.row, target - amount),
    )
  screen.clearRange(screen.cursor.position.row, column, column + amount - 1)
  screen.markChanged()

proc deleteCells*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let
    column = screen.cursor.position.column
    amount = min(max(count, 0), screen.columns - column)
  if amount == 0:
    return
  screen.clearWideCell(screen.cursor.position.row, column)
  screen.clearWideCell(screen.cursor.position.row, column + amount - 1)
  for target in column ..< screen.columns - amount:
    screen.setCell(
      screen.cursor.position.row,
      target,
      screen.cellAt(screen.cursor.position.row, target + amount),
    )
  screen.clearRange(
    screen.cursor.position.row, screen.columns - amount, screen.columns - 1
  )
  screen.markChanged()

proc eraseCells*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let last = min(screen.cursor.position.column + max(count, 1) - 1, screen.columns - 1)
  screen.clearRange(screen.cursor.position.row, screen.cursor.position.column, last)
  screen.markChanged()

proc insertLines*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let row = screen.cursor.position.row
  if row notin screen.scrollTop .. screen.scrollBottom:
    return
  let amount = min(max(count, 1), screen.scrollBottom - row + 1)
  for target in countdown(screen.scrollBottom, row + amount):
    screen.replaceLine(target, screen.lineAt(target - amount))
  for target in row ..< row + amount:
    screen.clearLine(target)
  screen.markChanged()

proc deleteLines*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  let row = screen.cursor.position.row
  if row notin screen.scrollTop .. screen.scrollBottom:
    return
  let amount = min(max(count, 1), screen.scrollBottom - row + 1)
  for target in row .. screen.scrollBottom - amount:
    screen.replaceLine(target, screen.lineAt(target + amount))
  for target in screen.scrollBottom - amount + 1 .. screen.scrollBottom:
    screen.clearLine(target)
  screen.markChanged()

proc attachCombiningRune[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], text: string
): bool =
  mixin cellText, `cellText=`, cellContinuation
  var
    row = screen.cursor.position.row
    column = screen.cursor.position.column - 1
  if screen.wrapPending:
    column = screen.columns - 1
  if column < 0 and row > 0:
    dec row
    column = screen.columns - 1
  if row < 0 or column < 0:
    return false
  if screen.cellAt(row, column).cellContinuation and column > 0:
    dec column
  let index = screen.cellIndex(row, column)
  if screen.cells[index].cellText.len == 0:
    return false
  var cell = screen.cells[index]
  cell.cellText = cell.cellText & text
  screen.cells[index] = cell
  screen.markChanged()
  true

proc writeText*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], text: string
) =
  let runes = text.toRunes()
  if runes.len == 0:
    return
  let width = terminalRuneWidth(runes[0])
  if width == 0:
    discard screen.attachCombiningRune(text)
    return
  if screen.wrapPending and screen.modes.autoWrap:
    screen.cursor.position.column = 0
    screen.lineFeed()
  screen.wrapPending = false
  if width == 2 and screen.cursor.position.column == screen.columns - 1:
    if screen.modes.autoWrap:
      screen.cursor.position.column = 0
      screen.lineFeed()
    else:
      return
  if screen.modes.insert:
    screen.insertCells(width)
  let
    row = screen.cursor.position.row
    column = screen.cursor.position.column
  screen.clearWideCell(row, column)
  screen.setCell(row, column, screen.makeCell(text, screen.style))
  if width == 2 and column + 1 < screen.columns:
    screen.clearWideCell(row, column + 1)
    screen.setCell(
      row, column + 1, screen.makeCell(style = screen.style, continuation = true)
    )
  screen.lastPrintedText = text
  if column + width >= screen.columns:
    screen.cursor.position.column = screen.columns - 1
    screen.wrapPending = screen.modes.autoWrap
  else:
    screen.cursor.position.column = column + width
  screen.markChanged()

proc repeatLastText*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], count = 1
) =
  if screen.lastPrintedText.len > 0:
    for _ in 0 ..< max(count, 1):
      screen.writeText(screen.lastPrintedText)

proc moveCursor*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], row, column: int
) =
  let rowMin = if screen.modes.origin: screen.scrollTop else: 0
  let rowMax =
    if screen.modes.origin:
      screen.scrollBottom
    else:
      screen.rows - 1
  screen.cursor.position = initTerminalPosition(
    clamp(row + rowMin, rowMin, rowMax), clamp(column, 0, screen.columns - 1)
  )
  screen.wrapPending = false
  screen.markChanged()

proc moveCursorRelative*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], rows, columns: int
) =
  let
    rowMin = if screen.modes.origin: screen.scrollTop else: 0
    rowMax =
      if screen.modes.origin:
        screen.scrollBottom
      else:
        screen.rows - 1
  screen.cursor.position.row = clamp(screen.cursor.position.row + rows, rowMin, rowMax)
  screen.cursor.position.column =
    clamp(screen.cursor.position.column + columns, 0, screen.columns - 1)
  screen.wrapPending = false
  screen.markChanged()

proc eraseInLine*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], mode: int
) =
  case mode
  of 0:
    screen.clearRange(
      screen.cursor.position.row, screen.cursor.position.column, screen.columns - 1
    )
  of 1:
    screen.clearRange(screen.cursor.position.row, 0, screen.cursor.position.column)
  of 2:
    screen.clearLine(screen.cursor.position.row)
  else:
    return
  screen.markChanged()

proc eraseInDisplay*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], mode: int
) =
  case mode
  of 0:
    screen.eraseInLine(0)
    for row in screen.cursor.position.row + 1 ..< screen.rows:
      screen.clearLine(row)
  of 1:
    for row in 0 ..< screen.cursor.position.row:
      screen.clearLine(row)
    screen.eraseInLine(1)
  of 2:
    for row in 0 ..< screen.rows:
      screen.clearLine(row)
  of 3:
    screen.clearScrollback()
    return
  else:
    return
  screen.markChanged()

proc setScrollRegion*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], top, bottom: int
) =
  if top >= 0 and top < bottom and bottom < screen.rows:
    screen.scrollTop = top
    screen.scrollBottom = bottom
  else:
    screen.scrollTop = 0
    screen.scrollBottom = screen.rows - 1
  screen.moveCursor(0, 0)

proc saveCursor*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.saved = TerminalSavedState(
    cursor: screen.cursor,
    style: screen.style,
    modes: screen.modes,
    wrapPending: screen.wrapPending,
  )

proc restoreCursor*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  screen.cursor = screen.saved.cursor
  screen.style = screen.saved.style
  screen.modes = screen.saved.modes
  screen.wrapPending = screen.saved.wrapPending
  screen.cursor.position.row = clamp(screen.cursor.position.row, 0, screen.rows - 1)
  screen.cursor.position.column =
    clamp(screen.cursor.position.column, 0, screen.columns - 1)
  screen.markChanged()

proc useAlternateScreen*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], enabled, saveRestore: bool
) =
  if enabled == screen.alternateScreen:
    return
  if enabled:
    if saveRestore:
      screen.saveCursor()
    screen.primaryCells = move(screen.cells)
    screen.primaryRowOrigin = screen.rowOrigin
    screen.primaryCursor = screen.cursor
    screen.primarySaved = screen.saved
    screen.cells = newSeqWith(screen.columns * screen.rows, screen.makeCell())
    screen.rowOrigin = 0
    screen.cursor.position = initTerminalPosition(0, 0)
    screen.wrapPending = false
    screen.alternateScreen = true
  else:
    screen.cells = move(screen.primaryCells)
    screen.primaryCells = @[]
    screen.rowOrigin = screen.primaryRowOrigin
    screen.primaryRowOrigin = 0
    screen.alternateScreen = false
    if saveRestore:
      screen.cursor = screen.primaryCursor
      screen.saved = screen.primarySaved
    screen.wrapPending = false
  screen.scrollTop = 0
  screen.scrollBottom = screen.rows - 1
  screen.markChanged()

proc queueReply*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], reply: sink string
) =
  screen.pendingReplies.add reply

proc reset*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback]
) =
  let
    columns = screen.columns
    rows = screen.rows
    maxScrollback = screen.maxScrollback
    generation = screen.generation
  screen = initTerminalScreen(
    TerminalScreen[Cell, Line, Scrollback], columns, rows, maxScrollback
  )
  screen.generation = generation + 1

proc resizeLine[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], line: Line, columns: int
): Line =
  mixin initTerminalLine, len, `[]`, `[]=`, cellContinuation
  result = initTerminalLine(Line, columns)
  for column in 0 ..< columns:
    result[column] = screen.makeCell()
  for column in 0 ..< min(columns, line.len):
    result[column] = line[column]
  if columns > 0 and columns < line.len and line[columns].cellContinuation:
    result[columns - 1] = screen.makeCell()

proc resizeCells[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback],
    cells: seq[Cell],
    rowOrigin, oldColumns, oldRows, columns, rows: int,
): seq[Cell] =
  mixin initTerminalLine, `[]`, `[]=`
  result = newSeqWith(columns * rows, screen.makeCell())
  for row in 0 ..< min(oldRows, rows):
    var oldLine = initTerminalLine(Line, oldColumns)
    for column in 0 ..< oldColumns:
      oldLine[column] = cells[((rowOrigin + row) mod oldRows) * oldColumns + column]
    let line = screen.resizeLine(oldLine, columns)
    for column in 0 ..< columns:
      result[row * columns + column] = line[column]

proc resize*[Cell, Line, Scrollback](
    screen: var TerminalScreen[Cell, Line, Scrollback], columns, rows: int
) =
  let
    nextColumns = max(columns, 1)
    nextRows = max(rows, 1)
  if nextColumns == screen.columns and nextRows == screen.rows:
    return
  screen.cells = screen.resizeCells(
    screen.cells, screen.rowOrigin, screen.columns, screen.rows, nextColumns, nextRows
  )
  if screen.primaryCells.len > 0:
    screen.primaryCells = screen.resizeCells(
      screen.primaryCells, screen.primaryRowOrigin, screen.columns, screen.rows,
      nextColumns, nextRows,
    )
  screen.rowOrigin = 0
  screen.primaryRowOrigin = 0
  screen.columns = nextColumns
  screen.rows = nextRows
  screen.cursor.position.row = clamp(screen.cursor.position.row, 0, nextRows - 1)
  screen.cursor.position.column =
    clamp(screen.cursor.position.column, 0, nextColumns - 1)
  screen.scrollTop = 0
  screen.scrollBottom = nextRows - 1
  screen.resetTabStops()
  screen.wrapPending = false
  screen.markChanged()

func lineText[Line](line: Line): string =
  mixin len, `[]`, cellText, cellContinuation
  for index in 0 ..< line.len:
    let cell = line[index]
    if not cell.cellContinuation:
      if cell.cellText.len > 0:
        result.add cell.cellText
      else:
        result.add ' '
  result = result.strip(leading = false, trailing = true, chars = {' '})

func plainText*[Cell, Line, Scrollback](
    screen: TerminalScreen[Cell, Line, Scrollback], includeScrollback = true
): string =
  var lines: seq[string]
  if includeScrollback and not screen.alternateScreen:
    for index in 0 ..< screen.scrollback.len:
      lines.add screen.lineAtAbsolute(index).lineText()
  var lastContentRow = -1
  for row in 0 ..< screen.rows:
    let text = screen.lineAt(row).lineText()
    lines.add text
    if text.len > 0:
      lastContentRow = lines.high
  if lastContentRow < 0:
    if screen.scrollback.len == 0 or not includeScrollback:
      return ""
    lastContentRow = screen.scrollback.len - 1
  lines.setLen(lastContentRow + 1)
  lines.join("\n")
