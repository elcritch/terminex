## Pseudo-terminal process transport and terminal parser integration.

import std/os

when defined(posix):
  import std/[posix, tables]

import ./[ringbuffer, termparser, termscreen]

const
  DefaultTerminalReadLimit* = 1024 * 1024
  DefaultTerminalWriteLimit* = 1024 * 1024
  TerminalReadChunkSize = 16 * 1024

type
  TerminexEnvironmentVariable* = object
    name*, value*: string

  TerminexSpawnOptions* = object
    command*: string
    shell*: string
    workingDirectory*: string
    environment*: seq[TerminexEnvironmentVariable]
    terminalName*: string
    colorTerminal*: string
    terminalProgram*: string

  TerminexSessionState* = enum
    tssIdle
    tssRunning
    tssExited
    tssClosed
    tssFailed

  TerminexPollResult* = object
    bytesRead*: int
    screenChanged*: bool
    processExited*: bool

  TerminexScreenInfo* = object
    ## Cheap session-owned screen metadata for rendering and input decisions.
    columns*, rows*: int
    scrollbackCount*, totalLineCount*: int
    generation*: uint64
    alternateScreen*: bool
    cursor*: TerminexCursor
    modes*: TerminexModes
    title*, currentDirectory*: string
    bellCount*: uint64
    clipboardRequestPending*: bool

  TerminexSessionError* = object of CatchableError

  TerminexSessionObj[Cell, Line, Scrollback] = object
    xScreen: TerminexScreen[Cell, Line, Scrollback]
    xParser: TerminexParser
    xState: TerminexSessionState
    xExitCode: int
    xError: string
    xPendingWrite: string
    xReadLimit, xWriteLimit: int
    when defined(posix):
      xMasterFd: cint
      xChildPid: Pid

  TerminexSession*[
    Cell = TerminexCell,
    Line = seq[Cell],
    Scrollback = RingBuffer[Line],
  ] = ref TerminexSessionObj[
    Cell, Line, Scrollback
  ]

when defined(posix):
  when defined(macosx):
    proc forkpty(
      master: var cint, name: cstring, termios: pointer, size: pointer
    ): Pid {.importc, header: "<util.h>".}

  elif defined(freebsd):
    {.passL: "-lutil".}
    proc forkpty(
      master: var cint, name: cstring, termios: pointer, size: pointer
    ): Pid {.importc, header: "<libutil.h>".}

  else:
    proc forkpty(
      master: var cint, name: cstring, termios: pointer, size: pointer
    ): Pid {.importc, header: "<pty.h>".}

  type TerminexWindowSize {.importc: "struct winsize", header: "<sys/ioctl.h>".} = object
    ws_row: cushort
    ws_col: cushort
    ws_xpixel: cushort
    ws_ypixel: cushort

  when defined(macosx) or defined(freebsd):
    const TerminalSetWindowSize = 0x80087467.culong
  else:
    const TerminalSetWindowSize = 0x5414.culong

  proc terminalIoctl(
    descriptor: cint, request: culong
  ): cint {.importc: "ioctl", header: "<sys/ioctl.h>", varargs.}

template releaseTerminalProcess[Cell, Line, Scrollback](
    session: TerminexSessionObj[Cell, Line, Scrollback]
) =
  when defined(posix):
    if session.xMasterFd >= 0:
      discard posix.close(session.xMasterFd)
    if session.xChildPid > 0 and session.xState == tssRunning:
      discard killpg(session.xChildPid, SIGHUP)
      discard killpg(session.xChildPid, SIGKILL)
      discard kill(session.xChildPid, SIGKILL)
      var status: cint
      discard waitpid(session.xChildPid, status, 0)

proc `=destroy`[Cell, Line, Scrollback](
    session: TerminexSessionObj[Cell, Line, Scrollback]
) =
  releaseTerminalProcess(session)

proc `=wasMoved`[Cell, Line, Scrollback](
    session: var TerminexSessionObj[Cell, Line, Scrollback]
) =
  when defined(posix):
    session.xMasterFd = -1
    session.xChildPid = 0

proc `=copy`[Cell, Line, Scrollback](
  destination: var TerminexSessionObj[Cell, Line, Scrollback],
  source: TerminexSessionObj[Cell, Line, Scrollback],
) {.error.}

proc `=dup`[Cell, Line, Scrollback](
  source: TerminexSessionObj[Cell, Line, Scrollback]
): TerminexSessionObj[Cell, Line, Scrollback] {.error.}

func initTerminalEnvironmentVariable*(
    name, value: string
): TerminexEnvironmentVariable =
  TerminexEnvironmentVariable(name: name, value: value)

func initTerminalSpawnOptions*(
    command = "",
    shell = "",
    workingDirectory = "",
    environment: openArray[TerminexEnvironmentVariable] = [],
    terminalName = "xterm-256color",
    colorTerminal = "truecolor",
    terminalProgram = "Terminex",
): TerminexSpawnOptions =
  TerminexSpawnOptions(
    command: command,
    shell: shell,
    workingDirectory: workingDirectory,
    environment: @environment,
    terminalName: terminalName,
    colorTerminal: colorTerminal,
    terminalProgram: terminalProgram,
  )

func terminalSessionsSupported*(): bool =
  defined(posix)

proc newTerminalSession*[
    Cell: TerminexCellAdapter,
    Line: TerminexLineAdapter[Cell],
    Scrollback: TerminexScrollbackAdapter[Line],
](
    screenType: typedesc[TerminexScreen[Cell, Line, Scrollback]],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[Cell, Line, Scrollback] =
  new(result)
  result.xScreen = initTerminalScreen(screenType, columns, rows, maxScrollback)
  result.xParser = initTerminalParser()
  result.xState = tssIdle
  result.xExitCode = -1
  result.xReadLimit = DefaultTerminalReadLimit
  result.xWriteLimit = DefaultTerminalWriteLimit
  when defined(posix):
    result.xMasterFd = -1

proc newTerminalSession*[Cell: TerminexCellAdapter](
    _: typedesc[Cell],
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[Cell, seq[Cell], RingBuffer[seq[Cell]]] =
  ## Construct a custom-cell session with sequence-backed lines and ring scrollback.
  newTerminalSession(
    TerminexScreen[Cell, seq[Cell], RingBuffer[seq[Cell]]], columns, rows, maxScrollback
  )

proc newTerminalSession*(
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[TerminexCell, TerminexLine, RingBuffer[TerminexLine]] =
  newTerminalSession(
    TerminexScreen[TerminexCell, TerminexLine, RingBuffer[TerminexLine]],
    columns,
    rows,
    maxScrollback,
  )

func screen*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): lent TerminexScreen[Cell, Line, Scrollback] =
  session.xScreen

func screenInfo*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): TerminexScreenInfo =
  ## Return screen metadata without copying the terminal cells or scrollback.
  TerminexScreenInfo(
    columns: session.xScreen.columns,
    rows: session.xScreen.rows,
    scrollbackCount: session.xScreen.scrollbackCount(),
    totalLineCount: session.xScreen.totalLineCount(),
    generation: session.xScreen.generation,
    alternateScreen: session.xScreen.alternateScreen,
    cursor: session.xScreen.cursor,
    modes: session.xScreen.modes,
    title: session.xScreen.title,
    currentDirectory: session.xScreen.currentDirectory,
    bellCount: session.xScreen.bellCount,
    clipboardRequestPending: session.xScreen.clipboardRequestPending,
  )

func lineAtAbsolute*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], index: int
): Line =
  session.xScreen.lineAtAbsolute(index)

func state*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): TerminexSessionState =
  session.xState

func running*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): bool =
  session.xState == tssRunning

func exitCode*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): int =
  session.xExitCode

func lastError*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): string =
  session.xError

func pendingWriteBytes*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): int =
  session.xPendingWrite.len

proc takeClipboardRequest*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): string =
  ## Consume a clipboard write requested by the child through OSC 52.
  session.xScreen.takeClipboardRequest()

proc clearScrollback*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
) =
  ## Remove saved terminal history without changing the live screen.
  if not session.isNil:
    session.xScreen.clearScrollback()

func readLimit*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): int =
  session.xReadLimit

proc `readLimit=`*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], value: int
) =
  session.xReadLimit = max(value, TerminalReadChunkSize)

func writeLimit*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): int =
  session.xWriteLimit

proc `writeLimit=`*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], value: int
) =
  session.xWriteLimit = max(value, 1)

proc processOutput*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], data: string
) =
  session.xParser.feed(session.xScreen, data)

when defined(posix):
  proc ioError(operation: string): ref TerminexSessionError =
    newException(TerminexSessionError, operation & ": " & $strerror(errno))

  proc resolvedShell(options: TerminexSpawnOptions): string =
    if options.shell.len > 0:
      options.shell
    else:
      getEnv("SHELL", "/bin/sh")

  proc childEnvironment(options: TerminexSpawnOptions): seq[string] =
    var environment = initOrderedTable[string, string]()
    for name, value in envPairs():
      environment[name] = value
    environment["TERM"] = options.terminalName
    environment["COLORTERM"] = options.colorTerminal
    if options.terminalProgram.len > 0:
      environment["TERM_PROGRAM"] = options.terminalProgram
    else:
      environment.del("TERM_PROGRAM")
    for variable in options.environment:
      if variable.name.len > 0 and '=' notin variable.name:
        environment[variable.name] = variable.value
    for name, value in environment.pairs:
      result.add name & "=" & value

  proc executeChild(
      shell, workingDirectory: cstring, arguments, environment: cstringArray
  ) {.noreturn.} =
    if workingDirectory != nil and chdir(workingDirectory) != 0:
      exitnow(126)
    discard execve(shell, arguments, environment)
    exitnow(127)

  proc setNonBlocking(descriptor: cint) =
    let flags = fcntl(descriptor, F_GETFL)
    if flags < 0 or fcntl(descriptor, F_SETFL, flags or O_NONBLOCK) < 0:
      raise ioError("configure PTY")

proc start*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback],
    options = initTerminalSpawnOptions(),
) =
  if session.isNil:
    raise newException(TerminexSessionError, "cannot start a nil terminal session")
  if session.xState == tssRunning:
    raise newException(TerminexSessionError, "terminal session is already running")
  when defined(posix):
    # The child of a threaded process may only call async-signal-safe operations
    # before exec, so allocate its argument and environment blocks in the parent.
    let
      shell = options.resolvedShell()
      arguments = allocCStringArray(
        if options.command.len > 0:
          @[shell, "-lc", options.command]
        else:
          @[shell]
      )
      environment = allocCStringArray(options.childEnvironment())
      workingDirectory =
        if options.workingDirectory.len > 0: options.workingDirectory.cstring else: nil
    defer:
      deallocCStringArray(arguments)
      deallocCStringArray(environment)
    var
      descriptor: cint
      windowSize = TerminexWindowSize(
        ws_row: session.xScreen.rows.cushort, ws_col: session.xScreen.columns.cushort
      )
    let child = forkpty(descriptor, nil, nil, addr windowSize)
    if child < 0:
      session.xState = tssFailed
      session.xError = "start PTY: " & $strerror(errno)
      raise newException(TerminexSessionError, session.xError)
    if child == 0:
      executeChild(shell.cstring, workingDirectory, arguments, environment)

    try:
      descriptor.setNonBlocking()
    except TerminexSessionError as error:
      discard posix.close(descriptor)
      discard killpg(child, SIGKILL)
      discard kill(child, SIGKILL)
      var status: cint
      discard waitpid(child, status, 0)
      session.xState = tssFailed
      session.xError = error.msg
      raise
    session.xMasterFd = descriptor
    session.xChildPid = child
    session.xState = tssRunning
    session.xExitCode = -1
    session.xError.setLen(0)
    session.xPendingWrite.setLen(0)
  else:
    session.xState = tssFailed
    session.xError = "pseudo-terminals are not supported on this platform"
    raise newException(TerminexSessionError, session.xError)

proc spawnTerminalSession*[
    Cell: TerminexCellAdapter,
    Line: TerminexLineAdapter[Cell],
    Scrollback: TerminexScrollbackAdapter[Line],
](
    screenType: typedesc[TerminexScreen[Cell, Line, Scrollback]],
    options = initTerminalSpawnOptions(),
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[Cell, Line, Scrollback] =
  result = newTerminalSession(screenType, columns, rows, maxScrollback)
  result.start(options)

proc spawnTerminalSession*[Cell: TerminexCellAdapter](
    _: typedesc[Cell],
    options = initTerminalSpawnOptions(),
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[Cell, seq[Cell], RingBuffer[seq[Cell]]] =
  ## Spawn a custom-cell session with sequence-backed lines and ring scrollback.
  spawnTerminalSession(
    TerminexScreen[Cell, seq[Cell], RingBuffer[seq[Cell]]],
    options,
    columns,
    rows,
    maxScrollback,
  )

proc spawnTerminalSession*(
    options = initTerminalSpawnOptions(),
    columns = DefaultTerminalColumns,
    rows = DefaultTerminalRows,
    maxScrollback = DefaultTerminalScrollback,
): TerminexSession[TerminexCell, TerminexLine, RingBuffer[TerminexLine]] =
  spawnTerminalSession(
    TerminexScreen[TerminexCell, TerminexLine, RingBuffer[TerminexLine]],
    options,
    columns,
    rows,
    maxScrollback,
  )

when defined(posix):
  proc tryWrite[Cell, Line, Scrollback](
      session: TerminexSession[Cell, Line, Scrollback]
  ): int =
    while session.xPendingWrite.len > 0:
      let written = posix.write(
        session.xMasterFd,
        unsafeAddr session.xPendingWrite[0],
        session.xPendingWrite.len,
      )
      if written > 0:
        result += written.int
        if written.int >= session.xPendingWrite.len:
          session.xPendingWrite.setLen(0)
        else:
          session.xPendingWrite =
            session.xPendingWrite[written.int ..< session.xPendingWrite.len]
      elif written < 0 and errno == EINTR:
        discard
      elif written < 0 and (errno == EAGAIN or errno == EWOULDBLOCK):
        return
      else:
        raise ioError("write PTY")

proc flushInput*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): int {.discardable.} =
  if not session.running() or session.xPendingWrite.len == 0:
    return
  when defined(posix):
    result = session.tryWrite()

proc write*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], data: string
) =
  if not session.running():
    raise newException(TerminexSessionError, "terminal session is not running")
  if data.len == 0:
    return
  discard session.flushInput()
  if session.xPendingWrite.len + data.len > session.xWriteLimit:
    raise newException(TerminexSessionError, "terminal input buffer is full")
  session.xPendingWrite.add data
  discard session.flushInput()

when defined(posix):
  proc recordExit[Cell, Line, Scrollback](
      session: TerminexSession[Cell, Line, Scrollback], status: cint
  ) =
    if WIFEXITED(status):
      session.xExitCode = WEXITSTATUS(status).int
    elif WIFSIGNALED(status):
      session.xExitCode = 128 + WTERMSIG(status).int
    else:
      session.xExitCode = -1
    session.xState = tssExited
    session.xChildPid = 0
    if session.xMasterFd >= 0:
      discard posix.close(session.xMasterFd)
      session.xMasterFd = -1

  proc checkExit[Cell, Line, Scrollback](
      session: TerminexSession[Cell, Line, Scrollback]
  ): bool =
    if session.xChildPid <= 0:
      return session.xState == tssExited
    var status: cint
    let child = waitpid(session.xChildPid, status, WNOHANG)
    if child > 0:
      session.recordExit(status)
      true
    else:
      false

proc poll*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): TerminexPollResult =
  if not session.running():
    result.processExited = session.xState == tssExited
    return
  let generation = session.xScreen.generation
  try:
    discard session.flushInput()
    when defined(posix):
      var consumed = 0
      while consumed < session.xReadLimit:
        var buffer =
          newString(min(TerminalReadChunkSize, session.xReadLimit - consumed))
        let count = posix.read(session.xMasterFd, addr buffer[0], buffer.len)
        if count > 0:
          buffer.setLen(count.int)
          consumed += count.int
          session.processOutput(buffer)
        elif count < 0 and errno == EINTR:
          discard
        elif count < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EIO):
          break
        else:
          break
      result.bytesRead = consumed
      let replies = session.xScreen.takePendingReplies()
      for reply in replies:
        session.write(reply)
      result.processExited = session.checkExit()
  except TerminexSessionError as error:
    session.xError = error.msg
  result.screenChanged = generation != session.xScreen.generation

proc resize*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], columns, rows: int
) =
  session.xScreen.resize(columns, rows)
  if session.running():
    when defined(posix):
      var size = TerminexWindowSize(
        ws_row: session.xScreen.rows.cushort, ws_col: session.xScreen.columns.cushort
      )
      if terminalIoctl(session.xMasterFd, TerminalSetWindowSize, addr size) < 0:
        session.xError = "resize PTY: " & $strerror(errno)

proc sendSignal*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback], signal: int
): bool {.discardable.} =
  if not session.running():
    return false
  when defined(posix):
    result = killpg(session.xChildPid, signal.cint) == 0

proc interrupt*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): bool {.discardable.} =
  when defined(posix):
    session.sendSignal(SIGINT)
  else:
    false

proc terminate*[Cell, Line, Scrollback](
    session: TerminexSession[Cell, Line, Scrollback]
): bool {.discardable.} =
  when defined(posix):
    session.sendSignal(SIGTERM)
  else:
    false

proc close*[Cell, Line, Scrollback](session: TerminexSession[Cell, Line, Scrollback]) =
  if session.isNil or session.xState == tssClosed:
    return
  when defined(posix):
    if session.xMasterFd >= 0:
      discard posix.close(session.xMasterFd)
      session.xMasterFd = -1
    if session.xChildPid > 0:
      if session.xState == tssRunning:
        discard killpg(session.xChildPid, SIGHUP)
        discard killpg(session.xChildPid, SIGKILL)
        discard kill(session.xChildPid, SIGKILL)
      var status: cint
      discard waitpid(session.xChildPid, status, 0)
      session.xChildPid = 0
  session.xPendingWrite.setLen(0)
  session.xState = tssClosed
