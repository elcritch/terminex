## Optional Sigils terminal facade. Managed sessions move once into their worker;
## subsequent access uses commands and owned snapshots, never a parser mutex.

import sigils/[core, rchannels, threadProxies, threads]
import ./[termsnapshots, workerthreads]
import ./private/[sessionmessages, sessionworker]

export termsnapshots, workerthreads

type ThreadedTerminalSession* = ref object of Agent
  cache: TerminalScreenSnapshot
  snapshots: RChan[TerminalSessionSnapshot]
  token, epoch, receivedSerial, readSerial, bytesRead: uint64
  commandSerial, appliedCommand, clipboardSerial: uint64
  submittedWriteBytes, processedWriteBytes: uint64
  cachedState: TerminexSessionState
  cachedExitCode, cachedPendingWrite, xReadLimit, xWriteLimit: int
  cachedError, clipboard: string
  pending: TerminexPollResult
  notificationPending, outputClosed: bool
  desiredColumns, desiredRows: int
  worker: AgentProxy[TerminalSessionWorker]

var nextIdentity {.threadvar.}: uint64

proc nextTerminalIdentity(): uint64 =
  inc nextIdentity
  nextIdentity

proc sessionOutputAvailable*(session: ThreadedTerminalSession) {.signal.}
func workerIdentity*(session: ThreadedTerminalSession): uint64 =
  session.token
func pendingCommands*(session: ThreadedTerminalSession): uint64 =
  session.commandSerial - session.appliedCommand

proc submit(session: ThreadedTerminalSession, command: sink TerminalCommand) =
  var command = ensureMove command
  inc session.commandSerial
  command.serial = session.commandSerial
  command.epoch = session.epoch
  emit session.worker.commandRequested(ensureMove command)

proc collectSnapshots(session: ThreadedTerminalSession) =
  var update: TerminalSessionSnapshot
  while session.snapshots.tryRecv(update):
    let acknowledgement = TerminalCommand(
      kind: tcAcknowledge,
      epoch: update.epoch,
      snapshotSerial: update.serial,
      historyAdded: update.screen.info.scrollbackLinesAdded,
      historyReset: update.screen.info.scrollbackResetCount,
      clipboardSerial: update.clipboardSerial,
    )
    if update.epoch == session.epoch and update.serial > session.receivedSerial:
      session.pending.bytesRead += int(update.bytesRead - session.bytesRead)
      session.pending.screenChanged =
        session.pending.screenChanged or update.screen.info != session.cache.info or
        update.state != session.cachedState or update.lastError != session.cachedError
      session.pending.processExited =
        session.pending.processExited or update.state == tssExited
      session.pending.outputClosed = update.outputClosed
      session.outputClosed = update.outputClosed
      session.receivedSerial = update.serial
      session.readSerial = update.readSerial
      session.bytesRead = update.bytesRead
      session.appliedCommand = update.appliedCommand
      session.cachedState = update.state
      session.cachedExitCode = update.exitCode
      session.cachedPendingWrite = update.pendingWriteBytes
      session.processedWriteBytes = update.processedWriteBytes
      session.cachedError = update.lastError
      var clipboardPending = session.cache.info.clipboardRequestPending
      if update.clipboardSerial > session.clipboardSerial:
        session.clipboardSerial = update.clipboardSerial
        session.clipboard = move(update.clipboard)
        clipboardPending = true
      update.screen.info.clipboardRequestPending = clipboardPending
      session.cache.applySnapshot(move(update.screen))
    # ACK releases publication credit, never PTY read/parse progress.
    emit session.worker.commandRequested(acknowledgement)
  if not session.notificationPending and (
    session.pending.bytesRead > 0 or session.pending.screenChanged or
    session.pending.processExited or session.pending.outputClosed
  ):
    session.notificationPending = true
    emit session.sessionOutputAvailable()

proc snapshotArrived(session: ThreadedTerminalSession, token: uint64) {.slot.} =
  if token == session.token:
    session.collectSnapshots()

proc newThreadedTerminalSession*(
    columns = 80, rows = 24, maxScrollback = 10_000
): ThreadedTerminalSession =
  ## All mutations run on the terminal dispatcher, including offline parsing.
  ## Queries return the latest received snapshot. Pump the owning event loop
  ## or call poll() to receive updates; pendingCommands() tracks completion.
  var initial = newCompactTerminalSession(columns, rows, maxScrollback)
  result = ThreadedTerminalSession(
    cache: initial.copyScreen(),
    snapshots: newRChan[TerminalSessionSnapshot](1),
    token: nextTerminalIdentity(),
    epoch: 1,
    cachedState: tssIdle,
    cachedExitCode: -1,
    xReadLimit: initial.readLimit(),
    xWriteLimit: initial.writeLimit(),
    desiredColumns: max(columns, 1),
    desiredRows: max(rows, 1),
  )
  result.worker = newTerminalSessionWorker(
    ensureMove initial, result.snapshots, result.token, result.epoch
  )
  connectThreaded(
    result.worker, snapshotAvailable, result, ThreadedTerminalSession.snapshotArrived()
  )
  emit result.worker.beginRequested()

func screenInfo*(session: ThreadedTerminalSession): TerminexScreenInfo =
  session.cache.info
func screen*(session: ThreadedTerminalSession): TerminalScreenSnapshot =
  ## An owned copy of the last received screen/history, without a worker wait.
  session.cache
func lineAtAbsolute*(session: ThreadedTerminalSession, row: int): TerminexLine =
  session.cache.lineAtAbsolute(row)
func state*(session: ThreadedTerminalSession): TerminexSessionState =
  session.cachedState
func running*(session: ThreadedTerminalSession): bool =
  session.state() == tssRunning
func exitCode*(session: ThreadedTerminalSession): int =
  session.cachedExitCode
func lastError*(session: ThreadedTerminalSession): string =
  session.cachedError
func pendingWriteBytes*(session: ThreadedTerminalSession): int =
  session.cachedPendingWrite +
    int(session.submittedWriteBytes - session.processedWriteBytes)
func readLimit*(session: ThreadedTerminalSession): int =
  session.xReadLimit
func writeLimit*(session: ThreadedTerminalSession): int =
  session.xWriteLimit

proc `readLimit=`*(session: ThreadedTerminalSession, value: int) =
  session.xReadLimit = max(value, 1)
  session.submit(TerminalCommand(kind: tcReadLimit, value: value))

proc `writeLimit=`*(session: ThreadedTerminalSession, value: int) =
  session.xWriteLimit = max(value, 1)
  session.submit(TerminalCommand(kind: tcWriteLimit, value: value))

proc processOutput*(session: ThreadedTerminalSession, data: string) =
  session.submit(TerminalCommand(kind: tcProcessOutput, text: data))

proc write*(session: ThreadedTerminalSession, data: string) =
  if not session.running():
    raise newException(TerminexSessionError, "terminal session is not running")
  if data.len == 0:
    return
  if session.pendingWriteBytes() + data.len > session.xWriteLimit:
    raise newException(TerminexSessionError, "terminal input buffer is full")
  session.submittedWriteBytes += uint64(data.len)
  session.submit(TerminalCommand(kind: tcWrite, text: data))

proc resize*(session: ThreadedTerminalSession, columns, rows: int) =
  if session.desiredColumns != max(columns, 1) or session.desiredRows != max(rows, 1):
    session.desiredColumns = max(columns, 1)
    session.desiredRows = max(rows, 1)
    session.submit(TerminalCommand(kind: tcResize, columns: columns, rows: rows))

proc clearScrollback*(session: ThreadedTerminalSession) =
  session.submit(TerminalCommand(kind: tcClearScrollback))

proc takeClipboardRequest*(session: ThreadedTerminalSession): string =
  result = move(session.clipboard)
  session.cache.info.clipboardRequestPending = false

proc sendSignal*(session: ThreadedTerminalSession, signal: int): bool =
  ## True means queued for delivery, not OS success.
  if session.running():
    session.submit(TerminalCommand(kind: tcSignal, value: signal))
    result = true

proc interrupt*(session: ThreadedTerminalSession): bool =
  if session.running():
    session.submit(TerminalCommand(kind: tcInterrupt))
    result = true

proc terminate*(session: ThreadedTerminalSession): bool =
  if session.running():
    session.submit(TerminalCommand(kind: tcTerminate))
    result = true

proc close*(session: ThreadedTerminalSession) =
  ## Immediately marks the facade closed; the worker then terminates and reaps
  ## the process. pendingCommands() reaches zero after that work is acknowledged.
  if not session.isNil and session.cachedState != tssClosed:
    inc session.epoch
    session.pending = default(TerminexPollResult)
    session.notificationPending = false
    session.outputClosed = false
    session.cachedState = tssClosed
    session.submit(TerminalCommand(kind: tcClose))

proc start*(session: ThreadedTerminalSession, options = initTerminalSpawnOptions()) =
  ## Queue process startup. Failures arrive through state() and lastError().
  session.collectSnapshots()
  if session.running():
    raise newException(TerminexSessionError, "terminal session is already running")
  inc session.epoch
  session.pending = default(TerminexPollResult)
  session.notificationPending = false
  session.outputClosed = false
  session.cachedState = tssRunning
  session.cachedError.setLen(0)
  session.submit(TerminalCommand(kind: tcStart, options: options))

proc spawnThreadedTerminalSession*(
    options = initTerminalSpawnOptions(),
    columns = 80,
    rows = 24,
    maxScrollback = 10_000,
): ThreadedTerminalSession =
  result = newThreadedTerminalSession(columns, rows, maxScrollback)
  result.start(options)

func readSequence*(session: ThreadedTerminalSession): uint64 =
  ## Sequence of the last received PTY read batch, for correlating trace events.
  session.readSerial

proc poll*(session: ThreadedTerminalSession): TerminexPollResult =
  ## Consume available snapshots without waiting for commands or PTY reads.
  session.collectSnapshots()
  result = session.pending
  # Lifecycle state remains observable after another view/caller consumed the
  # one-shot byte count, matching Terminex's exited-session polling contract.
  result.processExited = session.cachedState == tssExited
  result.outputClosed = session.outputClosed
  session.pending = default(TerminexPollResult)
  session.notificationPending = false
