# Terminex

Terminex is a GUI-independent Nim terminal-emulator core. It provides a screen
and scrollback model, an incremental ECMA-48/VT parser, xterm input encoding,
and POSIX PTY session transport. GUI toolkits own rendering, event translation,
selections, and clipboard policy.

## Install and test

```sh
atlas install
atlas-run tests
```

## Use

```nim
import terminex

let session = spawnTerminalSession(
  initTerminalSpawnOptions(command = "printf 'hello\\n'"),
  columns = 80,
  rows = 24,
)
defer: session.close()
while session.running:
  discard session.poll()
echo session.screen.plainText()
```

The input helpers turn frontend key, mouse, paste, and focus events into terminal
bytes. `TerminexSpawnOptions.terminalProgram` defaults to `"Terminex"`; set it
to an empty string to omit `TERM_PROGRAM`.

## Custom screen storage

`TerminexScreen` and `TerminexSession` can use application-owned cell, line,
and scrollback types. The default remains `TerminexCell`, `TerminexLine`, and
`seq[TerminexLine]`. Supply these small operations for custom types:

- `initTerminalCell(CellType, text, style)`; `cellText`, `cellText=`;
  `cellStyle`, `cellStyle=`; and `cellContinuation`, `cellContinuation=`.
- `initTerminalLine(LineType, length)`, `len`, `[]`, and `[]=` for lines.
- `len`, `[]`, `[]=`, `add`, and `setLen` for scrollback.

The exported `TerminexCellAdapter`, `TerminexLineAdapter[Cell]`, and
`TerminexScrollbackAdapter[Line]` concepts enforce this complete contract at
compile time. Accessors can live beside the application's types.

When only the cell representation is custom, `initTerminalScreen(CellType)` and
`newTerminalSession(CellType)` use `seq[CellType]` lines and sequence-backed
scrollback automatically. Pass a fully specialized `TerminexScreen` type when
customizing all three storage layers.

```nim
import terminex

type
  Cell = object
    glyph: string
    format: TerminexStyle
    continuation: bool

func initTerminalCell(_: typedesc[Cell], text = "",
    style = initTerminalStyle()): Cell = Cell(glyph: text, format: style)
func cellText(cell: Cell): string = cell.glyph
proc `cellText=`(cell: var Cell, text: string) = cell.glyph = text
func cellStyle(cell: Cell): TerminexStyle = cell.format
proc `cellStyle=`(cell: var Cell, style: TerminexStyle) = cell.format = style
func cellContinuation(cell: Cell): bool = cell.continuation
proc `cellContinuation=`(cell: var Cell, value: bool) = cell.continuation = value

var
  screen = initTerminalScreen(Cell, columns = 80, rows = 24)
  parser = initTerminalParser()
parser.feed(screen, "\x1b[31mhello")
echo screen.plainText()
```
