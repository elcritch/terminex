# Terminex

Terminex is a GUI-independent Nim terminal-emulator core. It provides a screen
and scrollback model, an incremental ECMA-48/VT parser, xterm input encoding,
and POSIX PTY session transport. An optional Sigils adapter supplies shared
threaded sessions with owned screen snapshots. GUI toolkits own rendering, event translation,
selections, and clipboard policy.

## Install and test

```sh
atlas install
atlas-run tests
```

The core import, `import terminex`, has no Sigils, Chronos, or thread requirement.
It supports synchronous parsing and PTY polling, including `--threads:off`.
To install the optional threaded adapter in this checkout:

```sh
atlas install --features:sigils
atlas-run tests
atlas-run tests --compile-only examples/all_compile.nim
```

Applications can request the optional dependencies with
`requires "gh:elcritch/terminex >= 0.4.0 [sigils]"` in their manifest. Import
`terminex/threaded` explicitly and compile with threads and ARC, ORC, or atomicARC.

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

GUI event loops can call `session.poll(timeBudget = initDuration(milliseconds = 2))`
to yield between read chunks. Import `std/times` for `initDuration`. The budget
is checked between chunks, so a single chunk can exceed it. `readPaused` means
the caller should schedule another drain; it does not guarantee more bytes are
available. `outputClosed` distinguishes EOF/hangup from an empty nonblocking
read. Exit is collected only after draining, preserving the child's final bytes.
Pending input is discarded after hangup or exit, so a failed write cannot block
exit collection.
The default zero time budget retains byte-limited synchronous polling.

On POSIX, `close()` closes the PTY and signals the child process group, then
polls for child exit for up to 250 ms per session. Destruction uses the same
bounded wait. If the OS has not made the child reapable by that deadline,
`close()` retains its PID so a later `close()` can retry; restarting the session
raises `TerminexSessionError` while that child is still pending. There is no
background reaper: after session destruction, an unusually delayed child may
remain a zombie until the host process exits. This keeps a stuck child from
blocking GUI shutdown indefinitely.

## Owned screen snapshots

Synchronous sessions can produce detached screen/history values without starting
workers or using signals. This works with the default cells and either ring or
compact scrollback; custom cell/line storage remains available through the raw
session API.

```nim
import terminex

let session = newTerminalSession(columns = 80, rows = 24)
session.processOutput("first line\r\n")
var displayed = session.copyScreen()
session.processOutput("more output")
displayed.applySnapshot(session.captureScreenUpdate(displayed.info))
echo displayed.plainText()
```

`TerminalScreenSnapshot` contains owned live rows and compact history. Previous
copies remain unchanged by later parsing, resize, or history eviction.
`captureScreenUpdate(acknowledged)` copies current rows plus history since the
last applied metadata; omit the acknowledgement to include all retained history.
Apply updates in order to a cache for the same session. Capturing and polling
belong on the raw session's owning thread; the core does not add synchronization.

## Optional threaded sessions

```nim
import terminex/threaded

let session = newThreadedTerminalSession(columns = 80, rows = 24)
session.processOutput("parsed on the terminal worker\r\n")
# From your event loop, call session.poll() to receive available snapshots.
# Once session.pendingCommands() == 0, this output is in session.screen().
```

See [examples/threaded.nim](examples/threaded.nim) for a complete offline example
with bounded waits and explicit shutdown. `spawnThreadedTerminalSession(options)`
also queues native process startup. Offline parsing uses the same worker API on
every platform; native PTY startup currently requires POSIX. Windows startup
reports `tssFailed` with an error until a native backend is available.

Each calling thread lazily owns one dedicated Sigils/Chronos dispatcher, shared
by its terminal sessions and separate from the general worker pool. A raw session
moves into its worker once. Commands use Sigils `sink` arguments; screen and
lifecycle updates cross a capacity-one RChan as owned values. The facade and its
queries stay on the caller's thread. Never share a facade between threads.

`screenInfo()`, `lineAtAbsolute()`, and `screen()` query the last received cache
without waiting for the parser. `screen()` copies the whole retained screen, so
prefer the smaller queries during rendering. Mutations enqueue ordered commands;
`poll()` collects available updates without reading the PTY or waiting for
completion. `pendingCommands()` becomes zero after those commands are applied
and acknowledged. `running()` includes queued startup; startup errors arrive in
`state()` and `lastError()`. Signal methods report whether delivery was queued,
not whether the OS accepted it.

Applications can subscribe to the coalesced `sessionOutputAvailable` signal.
Pump the owning Sigils loop (for example, `getCurrentSigilThread().pollAll(NonBlocking)`)
and connect its wakeup to the host event loop. Call `session.poll()` when handling
the signal to consume the pending notification and allow another one. Explicit
polling also works without dispatching facade signals. Terminex supplies no GUI
event-loop integration, native menu tracking, rendering, or clipboard policy.

Healthy idle PTYs sleep on descriptor readiness. Reads yield between chunks with
a 2 ms budget; a single chunk can exceed it. The first snapshot after idle is
immediate, with at least 8 ms between ordinary publications during continuous
output. A stalled consumer does not stop parsing: history deltas and byte counts
are cumulative, and final state may replace an unread snapshot. Maintenance
timers only run for pending input, delayed child exit, or readiness failure.

`close()` marks the facade closed immediately and queues process cleanup. Await
`pendingCommands() == 0` when cleanup must have completed. Close and discard
facades before explicit `shutdownTerminalWorkers()`; shutdown is idempotent and
new sessions can start another dispatcher. Module guards also join the worker
before its imported parser dependencies are destroyed at program exit. Hosts
with worker tasks using their own globals can declare `TerminalWorkerLifetime`
after those globals, or shut down explicitly before destroying them.

On POSIX, synchronous integrations can use `duplicateReadDescriptor()` to watch
readiness in another event loop. The caller owns the close-on-exec duplicate and
must close it. Observe it only: read through `poll()` on the owning thread and
do not change the duplicate's blocking mode.

Optional `-d:terminexTrace` instrumentation records timings and identities, never
PTY contents. Import `terminex/termtrace` and drain `takeTerminalTrace()` after
stopping producers. The trace buffer is bounded and reports dropped events.

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

Session `screenInfo()` includes `scrollbackLinesAdded` and `scrollbackResetCount`.
The append count continues increasing when bounded history evicts old lines;
the reset count changes on explicit history clearing or a full terminal reset.
Views can use these counters to keep a scrollback viewport anchored to its content.
