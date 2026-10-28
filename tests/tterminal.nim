import std/[monotimes, os, sequtils, strutils, tempfiles, times, unittest]
import terminex

when defined(posix):
  import std/posix

proc feed(screen: var TerminexScreen, parser: var TerminexParser, value: string) =
  parser.feed(screen, value)

type
  CustomCell = object
    glyph: string
    format: TerminexStyle
    trailingHalf: bool
    initialized: bool

  CustomLine = object
    slots: seq[CustomCell]

  CustomScrollback = object
    saved: seq[CustomLine]
    capacity: int

func initTerminalCell(
    _: typedesc[CustomCell], text = "", style = initTerminalStyle()
): CustomCell =
  CustomCell(glyph: text, format: style, initialized: true)

func cellText(cell: CustomCell): string =
  cell.glyph
proc `cellText=`(cell: var CustomCell, text: string) =
  cell.glyph = text

func cellStyle(cell: CustomCell): TerminexStyle =
  cell.format
proc `cellStyle=`(cell: var CustomCell, style: TerminexStyle) =
  cell.format = style

func cellContinuation(cell: CustomCell): bool =
  cell.trailingHalf
proc `cellContinuation=`(cell: var CustomCell, value: bool) =
  cell.trailingHalf = value

func initTerminalLine(_: typedesc[CustomLine], length: int): CustomLine =
  CustomLine(slots: newSeq[CustomCell](length))
func len(line: CustomLine): int =
  line.slots.len
func `[]`(line: CustomLine, index: int): CustomCell =
  line.slots[index]
proc `[]=`(line: var CustomLine, index: int, cell: CustomCell) =
  line.slots[index] = cell

func initScrollback(_: typedesc[CustomScrollback], capacity: int): CustomScrollback =
  CustomScrollback(capacity: max(capacity, 0))

func len(scrollback: CustomScrollback): int =
  scrollback.saved.len

iterator items(scrollback: CustomScrollback): CustomLine =
  for storedLine in scrollback.saved:
    yield storedLine

proc add(scrollback: var CustomScrollback, line: sink CustomLine) =
  if scrollback.capacity == 0:
    return
  if scrollback.saved.len == scrollback.capacity:
    scrollback.saved.delete(0)
  scrollback.saved.add(line)

proc clear(scrollback: var CustomScrollback) =
  scrollback.saved.setLen(0)

static:
  doAssert CustomCell is TerminexCellAdapter
  doAssert CustomLine is TerminexLineAdapter[CustomCell]
  doAssert CustomScrollback is TerminexScrollbackAdapter[CustomLine]

proc pollUntilExit(
    session: TerminexSession, timeout = initDuration(seconds = 3)
): bool =
  let deadline = getMonoTime() + timeout
  while session.running() and getMonoTime() < deadline:
    discard session.poll()
    if session.running():
      sleep(5)
  not session.running()

proc pollUntilText(
    session: TerminexSession, expected: string, timeout = initDuration(seconds = 3)
): bool =
  let deadline = getMonoTime() + timeout
  while getMonoTime() < deadline:
    discard session.poll()
    if expected in session.screen().plainText():
      return true
    sleep(5)

suite "terminex terminal screen and parser":
  test "custom cell line and scrollback adapters drive the parser":
    var
      screen = initTerminalScreen(
        TerminexScreen[CustomCell, CustomLine, CustomScrollback],
        columns = 3,
        rows = 2,
        maxScrollback = 2,
      )
      parser = initTerminalParser()

    parser.feed(screen, "A\x1b[31m日\r\nB\r\nC")

    check screen.cellAt(0, 0).glyph == "B"
    check screen.cellAt(0, 0).format.foreground == indexedTerminalColor(1)
    check screen.scrollbackCount == 1
    check screen.lineAtAbsolute(0)[0].glyph == "A"
    check screen.lineAtAbsolute(0)[2].trailingHalf
    check screen.lineAtAbsolute(-1).slots.len == 0
    check screen.lineAtAbsolute(screen.totalLineCount()).slots.len == 0
    check screen.plainText() == "A日\nB\nC"

    parser.feed(screen, "\r\nD\r\nE")
    check screen.scrollbackCount == 2
    check screen.lineAtAbsolute(0)[0].glyph == "B"
    check screen.lineAtAbsolute(1)[0].glyph == "C"
    check screen.plainText() == "B\nC\nD\nE"

    screen.resize(5, 2)
    check screen.cellAt(0, 3).initialized
    check screen.cellAt(1, 4).initialized

    screen.clearScrollback()
    check screen.scrollbackCount == 0

  test "custom cell shorthand uses sequence lines and ring scrollback":
    var
      screen = initTerminalScreen(CustomCell, columns = 5, rows = 2)
      parser = initTerminalParser()

    parser.feed(screen, "short")

    check screen.cellAt(0, 0).glyph == "s"
    check screen.lineAtAbsolute(-1).len == 0

  test "screen starts with bounded dimensions and terminal defaults":
    let screen = initTerminalScreen(0, -1, maxScrollback = -4)

    check screen.columns == 1
    check screen.rows == 1
    check screen.maxScrollback == 0
    check screen.cursor.position == initTerminalPosition(0, 0)
    check screen.cursor.visible
    check screen.cursor.blinking
    check screen.cursor.shape == tcsBlock
    check screen.modes.autoWrap
    check screen.cellAt(0, 0) == initTerminalCell()

  test "printable text controls wrapping and scrollback":
    var
      screen = initTerminalScreen(5, 3, maxScrollback = 2)
      parser = initTerminalParser()

    screen.feed(parser, "ABCDE")
    check screen.cursor.position == initTerminalPosition(0, 4)
    screen.feed(parser, "F\r\nG\r\nH\r\nI")

    check screen.scrollbackCount == 2
    check screen.plainText() == "ABCDE\nF\nG\nH\nI"
    check screen.cursor.position == initTerminalPosition(2, 1)

  test "bounded scrollback retains newest lines in logical order":
    var
      screen = initTerminalScreen(8, 2, maxScrollback = 3)
      parser = initTerminalParser()

    screen.feed(parser, "zero\r\none\r\ntwo\r\nthree\r\nfour\r\nfive")

    let scrollback = toSeq(scrollbackLines(screen))
    check screen.scrollbackCount == 3
    check scrollback[0][0].text == "o"
    check scrollback[1][0].text == "t"
    check scrollback[1][1].text == "w"
    check scrollback[2][0].text == "t"
    check scrollback[2][1].text == "h"
    check screen.lineAtAbsolute(0)[0].text == "o"
    check screen.lineAtAbsolute(2)[0].text == "t"
    check screen.lineAtAbsolute(2)[1].text == "h"
    check screen.plainText() == "one\ntwo\nthree\nfour\nfive"

  test "carriage return line feed tab and backspace follow VT semantics":
    var
      screen = initTerminalScreen(12, 4)
      parser = initTerminalParser()

    screen.feed(parser, "abc\rZ\n\tQ\bR")

    check screen.cellAt(0, 0).text == "Z"
    check screen.cellAt(0, 1).text == "b"
    check screen.cellAt(1, 8).text == "R"
    check screen.cursor.position == initTerminalPosition(1, 9)
    check screen.plainText(includeScrollback = false).splitLines()[1] ==
      repeat(' ', 8) & "R"

  test "UTF-8 input is incremental and preserves wide and combining clusters":
    var
      screen = initTerminalScreen(8, 2)
      parser = initTerminalParser()

    screen.feed(parser, "A\xe6\x97")
    check screen.cellAt(0, 0).text == "A"
    check screen.cellAt(0, 1).text.len == 0

    screen.feed(parser, "\xa5e\xcc")
    screen.feed(parser, "\x81B")

    check screen.cellAt(0, 1).text == "日"
    check screen.cellAt(0, 2).continuation
    check screen.cellAt(0, 3).text == "e\xcc\x81"
    check screen.cellAt(0, 4).text == "B"
    check screen.cursor.position.column == 5

  test "invalid UTF-8 is replaced without swallowing following bytes":
    var
      screen = initTerminalScreen(10, 2)
      parser = initTerminalParser()

    screen.feed(parser, "\xc0A\xed\xa0\x80B")

    check screen.cellAt(0, 0).text == "\xef\xbf\xbd"
    check screen.cellAt(0, 1).text == "A"
    check screen.cellAt(0, 2).text == "\xef\xbf\xbd"
    check screen.cellAt(0, 3).text == "\xef\xbf\xbd"
    check screen.cellAt(0, 4).text == "\xef\xbf\xbd"
    check screen.cellAt(0, 5).text == "B"

  test "incremental CSI moves the cursor and edits cells":
    var
      screen = initTerminalScreen(10, 5)
      parser = initTerminalParser()

    screen.feed(parser, "0123456789\r\nabcdefghij")
    screen.feed(parser, "\x1b[2;")
    screen.feed(parser, "4H\x1b[2@XY\x1b[2P\x1b[3X")

    check screen.cursor.position == initTerminalPosition(1, 5)
    check screen.plainText(includeScrollback = false).splitLines()[0] == "0123456789"
    check screen.plainText(includeScrollback = false).splitLines()[1] == "abcXY"

    screen.feed(parser, "\x1b[5A\x1b[99C")
    check screen.cursor.position == initTerminalPosition(0, 9)

  test "erase operations clear requested line and display ranges":
    var
      screen = initTerminalScreen(6, 3)
      parser = initTerminalParser()

    screen.feed(parser, "AAAAAA\r\nBBBBBB\r\nCCCCCC\x1b[2;3H\x1b[1K")
    check screen.cellAt(1, 0).text.len == 0
    check screen.cellAt(1, 2).text.len == 0
    check screen.cellAt(1, 3).text == "B"

    screen.feed(parser, "\x1b[0J")
    check screen.cellAt(0, 0).text == "A"
    check screen.cellAt(1, 3).text.len == 0
    check screen.cellAt(2, 0).text.len == 0

    screen.feed(parser, "\x1b[3J")
    check screen.scrollbackCount == 0

  test "clearing scrollback preserves the live screen":
    var
      screen = initTerminalScreen(6, 2)
      parser = initTerminalParser()
    screen.feed(parser, "zero\r\none\r\ntwo")
    let visibleText = screen.plainText(includeScrollback = false)

    check screen.scrollbackCount == 1
    screen.clearScrollback()

    check screen.scrollbackCount == 0
    check screen.plainText(includeScrollback = false) == visibleText

  test "scroll regions and line insertion leave outside rows unchanged":
    var
      screen = initTerminalScreen(5, 5)
      parser = initTerminalParser()

    screen.feed(parser, "0\r\n1\r\n2\r\n3\r\n4")
    screen.feed(parser, "\x1b[2;4r\x1b[3;1H\x1b[L")

    check screen.cellAt(0, 0).text == "0"
    check screen.cellAt(1, 0).text == "1"
    check screen.cellAt(2, 0).text.len == 0
    check screen.cellAt(3, 0).text == "2"
    check screen.cellAt(4, 0).text == "4"

    screen.feed(parser, "\x1b[M")
    check screen.cellAt(2, 0).text == "2"
    check screen.cellAt(3, 0).text.len == 0
    check screen.scrollbackCount == 0

  test "graphic rendition supports attributes indexed and true colors":
    var
      screen = initTerminalScreen(8, 2)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b[1;3;4;38;5;200;48;2;10;20;30mX\x1b[22;23;24;39;49mY")

    let first = screen.cellAt(0, 0)
    check taBold in first.style.attributes
    check taItalic in first.style.attributes
    check taUnderline in first.style.attributes
    check first.style.foreground == indexedTerminalColor(200)
    check first.style.background == rgbTerminalColor(10, 20, 30)

    let second = screen.cellAt(0, 1)
    check second.style.attributes == {}
    check second.style.foreground.kind == tckDefault
    check second.style.background.kind == tckDefault

  test "truncated extended colors do not become unrelated attributes":
    var
      screen = initTerminalScreen(4, 1)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b[38;5mA\x1b[0;48;2;12;34mB")

    check screen.cellAt(0, 0).style.attributes == {}
    check screen.cellAt(0, 1).style.attributes == {}

  test "colon SGR colors retain their groups and independent following attributes":
    for code in [38, 48, 58]:
      for separator in [":", ";"]:
        for values in ["2::120:130:4", "2:0:120:130:4", "2:120:130:4"]:
          let control = "\x1b[" & $code & separator & values & ";1m"
          for split in 0 .. control.len:
            var
              screen = initTerminalScreen(8, 2)
              parser = initTerminalParser()
            screen.feed(parser, control[0 ..< split])
            screen.feed(parser, control[split ..< control.len] & "X")
            let style = screen.cellAt(0, 0).style
            check style.attributes == {taBold}
            case code
            of 38:
              check style.foreground == rgbTerminalColor(120, 130, 4)
            of 48:
              check style.background == rgbTerminalColor(120, 130, 4)
            else:
              check style.underlineColor == rgbTerminalColor(120, 130, 4)

    var
      screen = initTerminalScreen(8, 2)
      parser = initTerminalParser()
    screen.feed(parser, "\x1b[38:5:196;48:5:17;58:5:24mX")
    check screen.style.foreground == indexedTerminalColor(196)
    check screen.style.background == indexedTerminalColor(17)
    check screen.style.underlineColor == indexedTerminalColor(24)
    check screen.style.attributes == {}
    screen.feed(parser, "\x1b[0m\x1b[38;5:196;48;5:17;58;5:24mX")
    check screen.style.foreground == indexedTerminalColor(196)
    check screen.style.background == indexedTerminalColor(17)
    check screen.style.underlineColor == indexedTerminalColor(24)
    check screen.style.attributes == {}

  test "underline subparameters never become unrelated graphic attributes":
    for entry in [
      ("4:0", {taBold}),
      ("4:1", {taBold, taUnderline}),
      ("4:2", {taBold, taDoubleUnderline}),
      ("4:3", {taBold}),
      ("4:4", {taBold}),
      ("4:5", {taBold}),
      ("0:4", {taBold}),
      ("1:2", {taBold}),
      ("38:2::120:130;4", {taBold, taUnderline}),
    ]:
      var
        screen = initTerminalScreen(8, 2)
        parser = initTerminalParser()
      screen.feed(parser, "\x1b[1;31m\x1b[" & entry[0] & "mX")
      check screen.style.attributes == entry[1]
      check screen.style.foreground == indexedTerminalColor(1)

    var
      screen = initTerminalScreen(8, 2)
      parser = initTerminalParser()
    screen.feed(parser, "\x1b[1;31;4m\x1b[4:0mX")
    check screen.style.attributes == {taBold}
    check screen.style.foreground == indexedTerminalColor(1)

  test "oversized numeric selectors are ignored and parsing recovers":
    let digits = repeat('9', 40)
    for control in [
      "\x1b[" & digits & "C",
      "\x1b[" & digits & "m",
      "\x1b]" & digits & ";bad\x07",
      "\x1b]" & digits & ";bad\x1b\\",
    ]:
      for split in 0 .. control.len:
        var
          screen = initTerminalScreen(8, 2)
          parser = initTerminalParser()
        screen.feed(parser, "\x1b]2;kept\x07\x1b[31mA")
        screen.feed(parser, control[0 ..< split])
        screen.feed(parser, control[split ..< control.len] & "Z")
        check screen.plainText() == "AZ"
        check screen.title == "kept"
        check screen.style.foreground == indexedTerminalColor(1)

  test "large valid cursor and erase counts clamp before arithmetic":
    let largest = $high(int)
    for entry in [
      ("C", initTerminalPosition(1, 7)),
      ("D", initTerminalPosition(1, 0)),
      ("B", initTerminalPosition(4, 1)),
      ("A", initTerminalPosition(0, 1)),
    ]:
      var
        screen = initTerminalScreen(8, 5)
        parser = initTerminalParser()
      screen.feed(parser, "\x1b[2;2H\x1b[" & largest & entry[0])
      check screen.cursor.position == entry[1]
      screen.moveCursorRelative(low(int), high(int))
      check screen.cursor.position == initTerminalPosition(0, 7)
    for command in ['H', 'd']:
      var
        screen = initTerminalScreen(8, 5)
        parser = initTerminalParser()
      screen.feed(parser, "\x1b[3;5r\x1b[?6h\x1b[" & largest & $command)
      check screen.cursor.position == initTerminalPosition(4, 0)
    var
      screen = initTerminalScreen(8, 2)
      parser = initTerminalParser()
    screen.feed(parser, "ABCDEFGH\x1b[1;2H\x1b[" & largest & "X")
    check screen.plainText() == "A"
    check screen.cursor.position == initTerminalPosition(0, 1)

  test "a repeat command has a bounded work count":
    var
      screen = initTerminalScreen(1, 1, maxScrollback = 2)
      parser = initTerminalParser()
    screen.feed(parser, "X\x1b[" & $high(int) & "b")
    check screen.cellAt(0, 0).text == "X"
    check screen.scrollbackCount == 2
    check screen.scrollbackLinesAdded == MaxTerminalRepeatCount.uint64

  test "keyboard modifier controls do not change graphic rendition":
    for control in ["\x1b[>4;2m", "\x1b[?4m", "\x1b[>4;0m", "\x1b[>m"]:
      for split in 0 .. control.len:
        var
          screen = initTerminalScreen(8, 3)
          parser = initTerminalParser()
        screen.feed(parser, "\x1b[31m")
        let style = screen.style
        screen.feed(parser, control[0 ..< split])
        screen.feed(parser, control[split ..< control.len])
        screen.feed(parser, "X\x1b[K\r\nY")

        check screen.style == style
        check screen.cellAt(0, 0).style == style
        check screen.cellAt(0, 7).style == style
        check screen.cellAt(1, 0).style == style
        screen.resize(12, 5)
        screen.feed(parser, "\x1b[2J")
        for row in 0 ..< screen.rows:
          for cell in screen.lineAt(row):
            check cell.style == style

  test "keyboard protocol controls do not restore the saved cursor":
    for control in ["\x1b[?u", "\x1b[>1u", "\x1b[=1u", "\x1b[<u"]:
      for split in 0 .. control.len:
        var
          screen = initTerminalScreen(20, 5)
          parser = initTerminalParser()
        screen.feed(parser, "\x1b[2;3H\x1b[s\x1b[4;7H")
        screen.feed(parser, control[0 ..< split])
        screen.feed(parser, control[split ..< control.len])
        screen.feed(parser, "/")

        check screen.cellAt(3, 6).text == "/"
        check screen.cursor.position == initTerminalPosition(3, 7)
        screen.feed(parser, "\x1b[u")
        check screen.cursor.position == initTerminalPosition(1, 2)

  test "unsupported CSI variants do not edit the screen or move the cursor":
    for control in [
      "\x1b[#P", "\x1b[#S", "\x1b[1;2;4;8;1$r", "\x1b[1$2A", "\x1b[1;2;3;4;5T"
    ]:
      for split in 0 .. control.len:
        var
          screen = initTerminalScreen(8, 7)
          parser = initTerminalParser()
        screen.feed(parser, "row0\r\nrow1\r\nrow2\r\nrow3\r\nrow4\r\nrow5\r\nrow6")
        screen.feed(parser, "\x1b[3;7r\x1b[4;2H")
        let
          text = screen.plainText(includeScrollback = false)
          cursor = screen.cursor.position
        screen.feed(parser, control[0 ..< split])
        screen.feed(parser, control[split ..< control.len])

        check screen.plainText(includeScrollback = false) == text
        check screen.cursor.position == cursor
        check screen.scrollTop == 2
        check screen.scrollBottom == 6
        check screen.scrollbackCount == 0
        screen.feed(parser, "X")
        check screen.cellAt(3, 1).text == "X"

  test "OSC metadata hyperlinks and clipboard requests terminate across chunks":
    var
      screen = initTerminalScreen(12, 2)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b]2;Build output\x1b")
    screen.feed(parser, "\\\x1b]7;file:///tmp/project\x07")
    screen.feed(parser, "\x1b]8;id=docs;https://example.com\x07link\x1b]8;;\x07")
    screen.feed(parser, "\x1b]52;c;aGVsbG8=\x07")

    check screen.title == "Build output"
    check screen.currentDirectory == "file:///tmp/project"
    check screen.cellAt(0, 0).style.hyperlink == "https://example.com"
    check screen.cellAt(0, 4).style.hyperlink.len == 0
    check screen.clipboardText == "hello"
    check screen.clipboardRequestPending

  test "device queries queue replies for the session transport":
    var
      screen = initTerminalScreen(20, 10)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b[4;7H\x1b[5n\x1b[6n\x1b[c\x1b[>c")

    check screen.pendingReplies() ==
      @["\x1b[0n", "\x1b[4;7R", "\x1b[?62;22c", "\x1b[>0;1;0c"]
    check screen.takePendingReplies().len == 4
    check screen.pendingReplies().len == 0

  test "private modes expose application input mouse paste and cursor state":
    var
      screen = initTerminalScreen(20, 5)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b[?1;6;1003;1004;1006;1007;2004h\x1b[5 q\x1b[?25l")

    check screen.modes.applicationCursorKeys
    check screen.modes.origin
    check screen.modes.mouseTracking == tmtAny
    check screen.modes.mouseEncoding == tmeSgr
    check screen.modes.focusReporting
    check screen.modes.alternateScroll
    check screen.modes.bracketedPaste
    check screen.cursor.shape == tcsBar
    check screen.cursor.blinking
    check not screen.cursor.visible

    screen.feed(parser, "\x1b[?1;6;1003;1004;1006;1007;2004l\x1b[2 q\x1b[?25h")
    check not screen.modes.applicationCursorKeys
    check not screen.modes.origin
    check screen.modes.mouseTracking == tmtNone
    check screen.modes.mouseEncoding == tmeX10
    check not screen.modes.focusReporting
    check not screen.modes.alternateScroll
    check not screen.modes.bracketedPaste
    check screen.cursor.shape == tcsBlock
    check not screen.cursor.blinking
    check screen.cursor.visible

  test "alternate screen restores the primary contents and optional cursor":
    var
      screen = initTerminalScreen(10, 4)
      parser = initTerminalParser()

    screen.feed(parser, "primary\x1b[3;4H\x1b[?1049h")
    check screen.alternateScreen
    check screen.plainText() == ""
    screen.feed(parser, "alternate\x1b[?1049l")

    check not screen.alternateScreen
    check screen.plainText() == "primary"
    check screen.cursor.position == initTerminalPosition(2, 3)

  test "alternate screen overflow remains available in scrollback":
    var
      screen = initTerminalScreen(12, 3)
      parser = initTerminalParser()

    screen.feed(
      parser, "\x1b[?1049halternate-0\r\nalternate-1\r\nalternate-2\r\nalternate-3"
    )

    check screen.alternateScreen
    check screen.scrollbackCount == 1
    check screen.lineAtAbsolute(0)[0].text == "a"
    check screen.lineAtAbsolute(0)[10].text == "0"

    screen.feed(parser, "\x1b[?1049l")

    check not screen.alternateScreen
    check screen.scrollbackCount == 1
    check screen.lineAtAbsolute(0)[0].text == "a"
    check screen.lineAtAbsolute(0)[10].text == "0"

  test "save restore reset and resize keep cursor and wide-cell invariants":
    var
      screen = initTerminalScreen(8, 4)
      parser = initTerminalParser()

    screen.feed(parser, "A日\x1b7\x1b[4;8H\x1b8")
    check screen.cursor.position == initTerminalPosition(0, 3)

    screen.resize(2, 2)
    check screen.columns == 2
    check screen.rows == 2
    check screen.cellAt(0, 0).text == "A"
    check screen.cellAt(0, 1).text.len == 0
    check not screen.cellAt(0, 1).continuation

    screen.feed(parser, "\x1bc")
    check screen.plainText() == ""
    check screen.cursor.position == initTerminalPosition(0, 0)
    check screen.modes.autoWrap

  test "horizontal cursor addressing preserves the row in origin mode":
    for command in ['G', '`']:
      var
        screen = initTerminalScreen(12, 8)
        parser = initTerminalParser()
      screen.feed(parser, "\x1b[3;7r\x1b[?6h\x1b[2;4H\x1b[7" & $command & "X")
      check screen.cellAt(3, 6).text == "X"
      check screen.cursor.position == initTerminalPosition(3, 7)

  test "cursor restore preserves unrelated modes and cursor appearance":
    for saved in [false, true]:
      var
        screen = initTerminalScreen(8, 6)
        parser = initTerminalParser()
      if saved:
        screen.feed(parser, "\x1b[3;6r\x1b[?6h\x1b[2;3H\x1b[1;31m\x1b7")
      screen.modes = TerminexModes(
        origin: false,
        autoWrap: false,
        insert: true,
        applicationCursorKeys: true,
        applicationKeypad: true,
        bracketedPaste: true,
        focusReporting: true,
        alternateScroll: true,
        mouseTracking: tmtAny,
        mouseEncoding: tmeSgr,
      )
      screen.cursor.visible = false
      screen.cursor.blinking = false
      screen.cursor.shape = tcsBar
      var expectedModes = screen.modes
      expectedModes.origin = saved
      screen.feed(parser, "\x1b8")
      check screen.modes == expectedModes
      check not screen.cursor.visible
      check not screen.cursor.blinking
      check screen.cursor.shape == tcsBar
      check screen.cursor.position ==
        (if saved: initTerminalPosition(3, 2) else: initTerminalPosition(0, 0))
      check screen.style.foreground ==
        (if saved: indexedTerminalColor(1) else: defaultTerminalColor())

  test "cursor and alternate screen restoration preserve pending wrap and rendition":
    for alternate in [false, true]:
      var
        screen = initTerminalScreen(4, 3)
        parser = initTerminalParser()
      screen.feed(parser, "\x1b[31mABCD")
      if alternate:
        screen.feed(parser, "\x1b[?1049h\x1b[32m\x1b7\x1b[?1049l")
      else:
        screen.feed(parser, "\x1b7\r\x1b[32m\x1b8")
      screen.feed(parser, "X")
      check screen.lineAt(0).mapIt(it.text).join() == "ABCD"
      check screen.cellAt(1, 0).text == "X"
      check screen.cellAt(1, 0).style.foreground == indexedTerminalColor(1)

    var
      screen = initTerminalScreen(4, 3)
      parser = initTerminalParser()
    screen.feed(parser, "ABCD\x1b7\x1b[?7l\x1b8X")
    check not screen.modes.autoWrap
    check screen.plainText() == "ABCX"

  test "alternate screen cursor restoration clips after resize":
    var
      screen = initTerminalScreen(8, 5)
      parser = initTerminalParser()
    screen.feed(parser, "\x1b[5;8H\x1b[31m\x1b[?1049h\x1b[32m\x1b7")
    screen.resize(3, 2)
    screen.feed(parser, "\x1b[?1049lX")
    check screen.cellAt(1, 2).text == "X"
    check screen.cellAt(1, 2).style.foreground == indexedTerminalColor(1)

  test "oversized control strings are bounded and recover to normal text":
    var
      screen = initTerminalScreen(20, 2)
      parser = initTerminalParser()

    screen.feed(parser, "\x1b[" & repeat('1', MaxTerminalCsiBytes + 2) & "Z")
    check parser.state == tpsGround
    screen.feed(parser, "ok")
    check screen.plainText() == "ok"

    parser.reset()
    screen.feed(parser, "\x1b]2;" & repeat('x', MaxTerminalStringBytes + 2))
    check parser.state == tpsOsc
    screen.feed(parser, "LEAK\x1b\\safe")
    check parser.state == tpsGround
    check screen.title == ""
    check screen.plainText() == "oksafe"

  test "ESC restart and intermediate sequences never leak their final bytes":
    for control in ["\x1b%G", "\x1b%/G", "\x1b\x1b[31m"]:
      for split in 0 .. control.len:
        var
          screen = initTerminalScreen(8, 2)
          parser = initTerminalParser()
        screen.feed(parser, "A" & control[0 ..< split])
        screen.feed(parser, control[split ..< control.len] & "B")
        check screen.plainText() == "AB"
        if control.endsWith("31m"):
          check screen.cellAt(0, 1).style.foreground == indexedTerminalColor(1)

  test "ignored strings retain framing through BEL and oversized payloads":
    for introducer in ['P', 'X', '^', '_', ']']:
      let control =
        "\x1b" & $introducer & "2;" & repeat('a', MaxTerminalStringBytes + 8) &
        "LEAK\x1b\\"
      for split in [0, 1, 2, MaxTerminalStringBytes, control.len - 2, control.len - 1]:
        var
          screen = initTerminalScreen(8, 2)
          parser = initTerminalParser()
        screen.feed(parser, "\x1b]2;kept\x07A" & control[0 ..< split])
        screen.feed(parser, control[split ..< control.len] & "B")
        check screen.plainText() == "AB"
        check screen.title == "kept"
        check parser.state == tpsGround
    for introducer in ['P', 'X', '^', '_']:
      var
        screen = initTerminalScreen(8, 2)
        parser = initTerminalParser()
      screen.feed(parser, "A\x1b" & $introducer & "data\x07LEAK\x1b\\B")
      check screen.plainText() == "AB"

  test "oversized OSC payloads terminate and cancel across input chunks":
    for suffix in [
      "\x07B", "\x1b\\B", "\x18B", "\x1aB", "\x1b\x18B", "\x1b\x1aB", "\x1b\x1b\\B",
      "\x1b\x07B",
    ]:
      var
        screen = initTerminalScreen(8, 2)
        parser = initTerminalParser()
      screen.feed(
        parser, "\x1b]2;kept\x07A\x1b]2;" & repeat('a', MaxTerminalStringBytes + 3)
      )
      for character in suffix:
        screen.feed(parser, $character)
      check screen.plainText() == "AB"
      check screen.title == "kept"
      check parser.state == tpsGround

  test "ignored DCS payload cannot leak printable bytes into the screen":
    var
      screen = initTerminalScreen(20, 2)
      parser = initTerminalParser()

    screen.feed(parser, "before\x1bP1;2|private payload\x1b\\after")

    check screen.plainText() == "beforeafter"

suite "terminex terminal sessions":
  test "custom terminal session owns a custom screen":
    let session = newTerminalSession(
      TerminexScreen[CustomCell, CustomLine, CustomScrollback], columns = 6, rows = 2
    )

    session.processOutput("custom")

    check session.screen().cellAt(0, 0).glyph == "c"
    check session.screen().plainText() == "custom"

  test "custom terminal session shorthand uses sequence lines and ring scrollback":
    let session = newTerminalSession(CustomCell, columns = 6, rows = 2)

    session.processOutput("simple")

    check session.screen().cellAt(0, 0).glyph == "s"
    check session.screen().plainText() == "simple"

  test "session can parse supplied output before starting a process":
    let session = newTerminalSession(12, 2)

    session.processOutput("plain \x1b[32mgreen")

    check session.state == tssIdle
    check session.screen().plainText() == "plain green"
    check session.screen().cellAt(0, 6).style.foreground == indexedTerminalColor(2)
    expect TerminexSessionError:
      session.write("input")

  when defined(posix):
    test "readiness descriptors are owned duplicates and close on exec":
      let session = newTerminalSession()
      check session.duplicateReadDescriptor() == -1
      session.start(
        initTerminalSpawnOptions(
          shell = "/bin/sh",
          command =
            "stty -echo; printf 'ready\\n'; IFS= read -r line; printf 'received:%s' \"$line\"",
        )
      )
      defer:
        session.close()
      let descriptor = session.duplicateReadDescriptor()
      require descriptor >= 0
      check (fcntl(descriptor, F_GETFD) and FD_CLOEXEC) != 0
      check posix.close(descriptor) == 0
      # Releasing the readiness observer must leave the session's PTY usable.
      let readyDeadline = getMonoTime() + initDuration(seconds = 10)
      while "ready" notin session.screen().plainText() and getMonoTime() < readyDeadline:
        discard session.poll()
        sleep(1)
      require "ready" in session.screen().plainText()
      session.write("duplicate-closed\n")
      let exitDeadline = getMonoTime() + initDuration(seconds = 10)
      while session.running() and getMonoTime() < exitDeadline:
        discard session.poll()
        sleep(1)
      check session.state() == tssExited
      check "received:duplicate-closed" in session.screen().plainText()
      session.close()
      check session.duplicateReadDescriptor() == -1

    test "time-budgeted polls preserve final output across child exit":
      let root = createTempDir("terminex-budget-", "")
      defer:
        removeDir(root)
      let payload = repeat("payload-line\n", 10_000) & "final-output\n"
      let path = root / "output.txt"
      writeFile(path, payload)
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          shell = "/bin/sh",
          command =
            "stty -echo; printf ready; IFS= read -r start; cat " & quoteShell(path) &
            "; exit 7",
        ),
        columns = 60,
        rows = 8,
      )
      defer:
        session.close()
      require session.pollUntilText("ready")
      session.write("start\n")
      var
        bytesRead = 0
        pauses = 0
      let deadline = getMonoTime() + initDuration(seconds = 60)
      while session.running() and getMonoTime() < deadline:
        let polled = session.poll(timeBudget = initDuration(nanoseconds = 1))
        bytesRead += polled.bytesRead
        if polled.readPaused:
          inc pauses
          check not polled.processExited
        if polled.bytesRead == 0:
          sleep(1)
      require not session.running()
      check pauses > 1
      # The PTY adds a carriage return to each newline.
      check bytesRead == payload.len + 10_001
      check session.exitCode == 7
      check "final-output" in session.screen().plainText()

    test "an empty live PTY is not reported as closed":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          shell = "/bin/sh",
          command = "stty -echo; printf ready; IFS= read -r start; printf finished",
        ),
        columns = 60,
        rows = 8,
      )
      defer:
        session.close()
      require session.pollUntilText("ready")
      let empty = session.poll(timeBudget = initDuration(milliseconds = 2))
      check empty.bytesRead == 0
      check not empty.readPaused
      check not empty.outputClosed
      check not empty.processExited
      session.write("start\n")
      require session.pollUntilExit()
      check "finished" in session.screen().plainText()

    test "child exit is collected when pending input can no longer be written":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          shell = "/bin/sh",
          # Neither the shell nor sleep drains input, so writes back up.
          command = "stty raw -echo; printf ready; sleep 60",
        ),
        columns = 60,
        rows = 8,
      )
      defer:
        session.close()
      require session.pollUntilText("ready")
      session.write(repeat('x', session.writeLimit()))
      require session.pendingWriteBytes() > 0
      require session.terminate()
      check session.pollUntilExit()
      check session.pendingWriteBytes() == 0

    test "PTY drains styled output and reports the child exit status":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(command = "printf '\\033[31mred\\033[0m\\n'; exit 7"),
        columns = 20,
        rows = 4,
      )
      defer:
        session.close()

      check session.pollUntilExit()
      check session.state == tssExited
      check session.exitCode == 7
      check "red" in session.screen().plainText()
      check session.screen().cellAt(0, 0).style.foreground == indexedTerminalColor(1)

    test "PTY applies working directory environment and terminal size":
      let root = createTempDir("terminex-terminal-session-", "")
      defer:
        removeDir(root)
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          command =
            "printf '%s\\n%s\\n%s\\n%s\\n' \"$(basename \"$PWD\")\" \"$TERM\" " &
            "\"$TERMINEX_TEST\" \"$TERM_PROGRAM\"; stty size",
          workingDirectory = root,
          environment = [initTerminalEnvironmentVariable("TERMINEX_TEST", "ready")],
        ),
        columns = 80,
        rows = 7,
      )
      defer:
        session.close()

      check session.pollUntilExit()
      let output = session.screen().plainText()
      check root.extractFilename() in output
      check "xterm-256color" in output
      check "ready" in output
      check "Terminex" in output
      check "7 80" in output

    test "PTY accepts interactive input without blocking the caller":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          command = "IFS= read -r value; printf 'reply:%s' \"$value\""
        ),
        columns = 30,
        rows = 4,
      )
      defer:
        session.close()

      session.write("hello\r")
      check session.pollUntilText("reply:hello")
      check session.pollUntilExit()
      check session.exitCode == 0

    test "PTY can omit the terminal program environment variable":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          command =
            "if [ \"${TERM_PROGRAM+x}\" = x ]; then printf present; " &
            "else printf absent; fi",
          terminalProgram = "",
        ),
        columns = 20,
        rows = 2,
      )
      defer:
        session.close()

      check session.pollUntilExit()
      check session.screen().plainText() == "absent"

    test "PTY resize reaches the child process":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(command = "sleep 0.05; stty size"),
        columns = 10,
        rows = 3,
      )
      defer:
        session.close()

      session.resize(33, 7)
      check session.screen().columns == 33
      check session.screen().rows == 7
      check session.pollUntilExit()
      check "7 33" in session.screen().plainText()

    test "closing a live PTY reaps its owned child":
      let session = spawnTerminalSession(
        initTerminalSpawnOptions(
          shell = "/bin/sh", command = "printf 'READY %s\\n' \"$$\"; exec sleep 30"
        ),
        columns = 80,
        rows = 3,
      )
      defer:
        session.close()

      check session.running()
      require session.pollUntilText("READY ")
      let child =
        Pid(parseInt(session.screen().plainText().strip().splitWhitespace()[1]))
      let closeStarted = getMonoTime()
      session.close()
      check getMonoTime() - closeStarted < initDuration(seconds = 1)
      check session.state == tssClosed
      check not session.running()
      var status: cint
      check waitpid(child, status, WNOHANG) == -1
      check errno == ECHILD
      session.close()
  else:
    test "unsupported platforms report a catchable spawn error":
      let session = newTerminalSession()
      expect TerminexSessionError:
        session.start()
      check session.state == tssFailed
