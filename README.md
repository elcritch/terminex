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

On POSIX, `close()` closes the PTY and signals the child process group, then
polls for child exit for up to 250 ms per session. Destruction uses the same
bounded wait. If the OS has not made the child reapable by that deadline,
`close()` retains its PID so a later `close()` can retry; restarting the session
raises `TerminexSessionError` while that child is still pending. There is no
background reaper: after session destruction, an unusually delayed child may
remain a zombie until the host process exits. This keeps a stuck child from
blocking GUI shutdown indefinitely.

## Compact scrollback

For large histories, use the optional compact in-memory backend. It stores
completed lines in encoded segments, interns repeated styles, omits trailing
default cells, and compresses blank and ASCII runs. Requested lines are decoded
back into the normal `TerminexLine` representation, so rendering APIs remain
unchanged.

```nim
import terminex

let session = newCompactTerminalSession(
  columns = 80,
  rows = 24,
  maxScrollback = 1_000_000,
)
```

`CompactScrollback[Cell, Line]` can also be used as the scrollback parameter of
a fully specialized `TerminexScreen`. It provides indexed lookup, so
`lineAtAbsolute` does not scan or decode preceding lines. The default
constructors continue to use `RingBuffer`. Rendering individual lines keeps the
decoded working set bounded; `plainText(includeScrollback = true)` still builds
one string containing the complete history.

## Custom screen storage

`TerminexScreen` and `TerminexSession` can use application-owned cell, line,
and scrollback types. The default remains `TerminexCell`, `TerminexLine`, and
`RingBuffer[TerminexLine]`. Supply these small operations for custom types:

- `initTerminalCell(CellType, text, style)`; `cellText`, `cellText=`;
  `cellStyle`, `cellStyle=`; and `cellContinuation`, `cellContinuation=`.
- `initTerminalLine(LineType, length)`, `len`, `[]`, and `[]=` for lines.
- `initScrollback(ScrollbackType, capacity)`, `len`, `items`, `add`, and
  `clear` for scrollback. An optional `[]` operation enables direct indexed
  lookup.

The exported `TerminexCellAdapter`, `TerminexLineAdapter[Cell]`, and
`TerminexScrollbackAdapter[Line]` concepts enforce this complete contract at
compile time. A custom scrollback's `add` operation owns its retention policy
and must honor the capacity received by `initScrollback`. This permits linked
lists and other containers that do not provide random access.

When only the cell representation is custom, `initTerminalScreen(CellType)` and
`newTerminalSession(CellType)` use `seq[CellType]` lines and
`RingBuffer[seq[CellType]]` scrollback automatically. Pass a fully specialized
`TerminexScreen` type when customizing all three storage layers.
`RingBufferWithStorage[Item, Storage]` supports custom sequence-compatible
backing stores through `RingBufferStorageAdapter[Item]`.

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
