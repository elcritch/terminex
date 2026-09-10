import std/[sequtils, unittest]

import terminex

type CustomCell = object
  glyph: string
  style: TerminexStyle
  continuation: bool

func initTerminalCell(
    _: typedesc[CustomCell], text = "", style = initTerminalStyle()
): CustomCell =
  CustomCell(glyph: text, style: style)

func cellText(cell: CustomCell): string =
  cell.glyph

proc `cellText=`(cell: var CustomCell, text: string) =
  cell.glyph = text

func cellStyle(cell: CustomCell): TerminexStyle =
  cell.style

proc `cellStyle=`(cell: var CustomCell, style: TerminexStyle) =
  cell.style = style

func cellContinuation(cell: CustomCell): bool =
  cell.continuation

proc `cellContinuation=`(cell: var CustomCell, continuation: bool) =
  cell.continuation = continuation

func blankLine(length: int): TerminexLine =
  result = initTerminalLine(TerminexLine, length)
  for index in 0 ..< length:
    result[index] = initTerminalCell()

func numberedLine(number: int, length = 8): TerminexLine =
  result = blankLine(length)
  result[0] = initTerminalCell($number)

suite "terminex compact scrollback":
  test "round trips text styles continuations and implicit blanks":
    var line = blankLine(10)
    var styled = initTerminalStyle()
    styled.foreground = indexedTerminalColor(1)
    styled.background = rgbTerminalColor(2, 3, 4)
    styled.attributes = {taBold, taUnderline}
    styled.hyperlink = "https://example.test/"

    line[0] = initTerminalCell("A", styled)
    line[1] = initTerminalCell("日", styled)
    line[2] = initTerminalCell("", styled)
    line[2].continuation = true
    line[3] = initTerminalCell("e\u0301")
    line[5] = initTerminalCell("", styled)

    var history = initCompactScrollback[TerminexCell, TerminexLine](4)
    history.add(line)

    check history.len == 1
    check history.cap == 4
    check history[0] == line
    check history.payloadBytes < line.len * sizeof(TerminexCell)

  test "retains newest lines across segment boundaries":
    var history = initCompactScrollback[TerminexCell, TerminexLine](3)
    for number in 0 ..< 300:
      history.add(numberedLine(number))

    check history.len == 3
    check history[0][0].text == "297"
    check history[1][0].text == "298"
    check history[2][0].text == "299"
    check toSeq(history.items).mapIt(it[0].text) == @["297", "298", "299"]
    expect IndexDefect:
      discard history[-1]
    expect IndexDefect:
      discard history[3]

  test "zero capacity and clear release all logical history":
    var disabled = initCompactScrollback[TerminexCell, TerminexLine](-1)
    disabled.add(numberedLine(1))
    check disabled.cap == 0
    check disabled.len == 0
    check disabled.payloadBytes == 0

    var history = initCompactScrollback[TerminexCell, TerminexLine](2)
    history.add(numberedLine(1))
    history.add(numberedLine(2))
    history.clear()
    check history.payloadBytes == 0
    history.add(numberedLine(3))

    check history.len == 1
    check history[0][0].text == "3"

  test "compact screen integrates with parser and indexed history lookup":
    var
      screen = initCompactTerminalScreen(columns = 3, rows = 2, maxScrollback = 2)
      parser = initTerminalParser()

    parser.feed(screen, "A\r\nB\r\nC\r\nD")

    check screen.scrollbackCount == 2
    check screen.lineAtAbsolute(0)[0].text == "A"
    check screen.lineAtAbsolute(1)[0].text == "B"
    check screen.lineAtAbsolute(2)[0].text == "C"
    check screen.lineAtAbsolute(3)[0].text == "D"

  test "compact session constructor exposes the existing session API":
    let session = newCompactTerminalSession(columns = 5, rows = 2, maxScrollback = 20)

    session.processOutput("hello\r\nworld")

    check session.screenInfo.columns == 5
    check session.screenInfo.rows == 2
    check session.lineAtAbsolute(0).len == 5

  test "custom cells use the same compact backend":
    var
      screen = initCompactTerminalScreen(CustomCell, columns = 3, rows = 1)
      parser = initTerminalParser()

    parser.feed(screen, "one\r\ntwo")

    check screen.scrollbackCount == 1
    check screen.lineAtAbsolute(0)[0].glyph == "o"
    check screen.lineAtAbsolute(0)[1].glyph == "n"
    check screen.lineAtAbsolute(0)[2].glyph == "e"

suite "Compact history progress":
  test "session reports appends even when retained history is full":
    let session = newCompactTerminalSession(columns = 8, rows = 2, maxScrollback = 2)
    session.processOutput("a\r\nb\r\nc\r\nd")
    check session.screenInfo().scrollbackCount == 2
    check session.screenInfo().scrollbackLinesAdded == 2
    session.processOutput("\r\ne")
    check session.screenInfo().scrollbackCount == 2
    check session.screenInfo().scrollbackLinesAdded == 3
    session.clearScrollback()
    check session.screenInfo().scrollbackCount == 0
    check session.screenInfo().scrollbackResetCount == 1
    check session.screenInfo().scrollbackLinesAdded == 3
    session.processOutput("\ec")
    check session.screenInfo().scrollbackResetCount == 2
    check session.screenInfo().scrollbackLinesAdded == 3
