## Exclusive PTY/session ownership on the shared terminal dispatcher.
## UI commands arrive through Sigils; owned snapshots leave through RChan.

import std/[isolation, monotimes, tables, times]
import chronos
import sigils/[core, rchannels, threadProxies, threads]
import ../[termsnapshots, termtrace, workerthreads]
import ./sessionmessages
when defined(posix):
  import std/posix

type TerminalWorkerRegistration = object
  descriptorPlusOne: cint
  token: uint64
  registered, armed: bool
  publishTimer, maintenanceTimer: TimerCallback

proc `=destroy`(registration: TerminalWorkerRegistration)
proc `=copy`(
  target: var TerminalWorkerRegistration, source: TerminalWorkerRegistration
) {.error.}

proc `=dup`(source: TerminalWorkerRegistration): TerminalWorkerRegistration {.error.}

type TerminalSessionWorker* = ref object of AgentActor
  session: CompactTerminalSession[TerminexCell]
  snapshots: RChan[TerminalSessionSnapshot]
  registration: TerminalWorkerRegistration
  epoch, serial, readSerial, bytesRead, appliedCommand: uint64
  historyAdded, historyReset, processedWriteBytes: uint64
  clipboardSerial: uint64
  clipboard: string
  commandError: string
  lastPublished: MonoTime
  outputClosed, watchFailed, dirty, outstanding: bool

var workers {.threadvar.}: Table[uint64, WeakRef[TerminalSessionWorker]]

proc closeDescriptor(registration: var TerminalWorkerRegistration) =
  when defined(posix):
    if registration.descriptorPlusOne > 0:
      let fd = AsyncFD(registration.descriptorPlusOne - 1)
      if registration.armed:
        discard removeReader2(fd)
      if registration.registered:
        discard unregister2(fd)
      discard posix.close(cint(fd))
      registration.descriptorPlusOne = 0
      registration.armed = false
      registration.registered = false

proc `=destroy`(registration: TerminalWorkerRegistration) =
  let owned = addr registration
  if not owned.publishTimer.isNil:
    clearTimer(owned.publishTimer)
  if not owned.maintenanceTimer.isNil:
    clearTimer(owned.maintenanceTimer)
  `=destroy`(owned.publishTimer)
  `=destroy`(owned.maintenanceTimer)
  owned[].closeDescriptor()
  workers.del(owned.token)

proc snapshotAvailable*(worker: TerminalSessionWorker, token: uint64) {.signal.}
proc beginRequested*(worker: AgentProxy[TerminalSessionWorker]) {.signal.}
proc commandRequested*(
  worker: AgentProxy[TerminalSessionWorker], command: sink TerminalCommand
) {.signal.}

proc publish(worker: TerminalSessionWorker) =
  let screen = worker.session.captureScreenUpdate(
    TerminexScreenInfo(
      scrollbackLinesAdded: worker.historyAdded,
      scrollbackResetCount: worker.historyReset,
    )
  )
  inc worker.serial
  var update = TerminalSessionSnapshot(
    epoch: worker.epoch,
    serial: worker.serial,
    workerToken: worker.registration.token,
    readSerial: worker.readSerial,
    bytesRead: worker.bytesRead,
    screen: screen,
    state: worker.session.state(),
    exitCode: worker.session.exitCode(),
    pendingWriteBytes: worker.session.pendingWriteBytes(),
    readLimit: worker.session.readLimit(),
    writeLimit: worker.session.writeLimit(),
    lastError: (
      if worker.commandError.len > 0: worker.commandError
      else: worker.session.lastError()
    ),
    outputClosed: worker.outputClosed,
    clipboardSerial: worker.clipboardSerial,
    clipboard: worker.clipboard,
    appliedCommand: worker.appliedCommand,
    processedWriteBytes: worker.processedWriteBytes,
  )
  # All nested fields are owned values, with no references into the live session.
  # Capacity one bounds pending presentation work. Final/command state can replace
  # an unread snapshot; history and byte counts remain cumulative until ACK.
  worker.snapshots.push(isolate(ensureMove update))
  worker.lastPublished = getMonoTime()
  worker.dirty = false
  if not worker.outstanding:
    worker.outstanding = true
    recordTerminalTrace("ready", worker.registration.token)
    emit worker.snapshotAvailable(worker.registration.token)

proc publishDue(data: pointer) {.gcsafe, raises: [].} =
  let reference = workers.getOrDefault(cast[uint64](data))
  if reference.isNil:
    return
  let worker = reference[]
  worker.registration.publishTimer = nil
  try:
    if worker.dirty and not worker.outstanding:
      worker.publish()
  except Exception:
    discard

proc requestPublish(worker: TerminalSessionWorker, force = false) =
  worker.dirty = true
  if force:
    if not worker.registration.publishTimer.isNil:
      clearTimer(worker.registration.publishTimer)
      worker.registration.publishTimer = nil
    worker.publish()
  elif not worker.outstanding and worker.registration.publishTimer.isNil:
    let delay = initDuration(milliseconds = 8) - (getMonoTime() - worker.lastPublished)
    if delay.inNanoseconds <= 0:
      worker.publish()
    else:
      worker.registration.publishTimer = setTimer(
        Moment.fromNow(chronos.nanoseconds(delay.inNanoseconds)),
        publishDue,
        cast[pointer](worker.registration.token),
      )

when defined(posix):
  proc arm(worker: TerminalSessionWorker): bool {.gcsafe.}
proc scheduleMaintenance(worker: TerminalSessionWorker) {.gcsafe.}

proc pollOutput(worker: TerminalSessionWorker) =
  let readyAt = terminalTraceTime()
  recordTerminalTrace("worker-poll-start", worker.registration.token)
  let pendingWrite = worker.session.pendingWriteBytes()
  let previousError = worker.session.lastError()
  let polled = worker.session.poll(timeBudget = initDuration(milliseconds = 2))
  recordTerminalTrace(
    "worker-poll-end", worker.registration.token, uint64(polled.bytesRead)
  )
  worker.bytesRead += uint64(polled.bytesRead)
  if polled.bytesRead > 0:
    inc worker.readSerial
    recordTerminalTrace(
      "worker-output", worker.registration.token, worker.readSerial, ticks = readyAt
    )
  worker.outputClosed = worker.outputClosed or polled.outputClosed
  if worker.session.screenInfo().clipboardRequestPending:
    inc worker.clipboardSerial
    worker.clipboard = worker.session.takeClipboardRequest()
  if polled.bytesRead > 0 or polled.screenChanged or polled.processExited or
      polled.outputClosed or pendingWrite != worker.session.pendingWriteBytes() or
      previousError != worker.session.lastError():
    worker.requestPublish(force = polled.processExited or polled.outputClosed)
  if worker.outputClosed or not worker.session.running():
    worker.registration.closeDescriptor()
  worker.scheduleMaintenance()

proc maintenanceDue(data: pointer) {.gcsafe, raises: [].} =
  let reference = workers.getOrDefault(cast[uint64](data))
  if reference.isNil:
    return
  let worker = reference[]
  worker.registration.maintenanceTimer = nil
  try:
    worker.pollOutput()
  except Exception:
    discard

proc scheduleMaintenance(worker: TerminalSessionWorker) =
  if worker.session.running() and worker.registration.maintenanceTimer.isNil and
      (
        worker.outputClosed or worker.watchFailed or
        worker.session.pendingWriteBytes() > 0
      ):
    worker.registration.maintenanceTimer = setTimer(
      Moment.fromNow(chronos.milliseconds(if worker.watchFailed: 16 else: 500)),
      maintenanceDue,
      cast[pointer](worker.registration.token),
    )

when defined(posix):
  proc descriptorReady(data: pointer) {.gcsafe, raises: [].} =
    let reference = workers.getOrDefault(cast[uint64](data))
    if reference.isNil:
      return
    let worker = reference[]
    if not worker.registration.armed:
      return
    discard removeReader2(AsyncFD(worker.registration.descriptorPlusOne - 1))
    worker.registration.armed = false
    try:
      worker.pollOutput()
      if worker.session.running() and not worker.outputClosed and not worker.arm():
        worker.watchFailed = true
        worker.scheduleMaintenance()
    except Exception:
      worker.registration.closeDescriptor()
      worker.watchFailed = true
      try:
        worker.scheduleMaintenance()
      except Exception:
        discard

  proc arm(worker: TerminalSessionWorker): bool =
    if not worker.registration.registered:
      return
    if worker.registration.armed:
      return true
    if addReader2(
      AsyncFD(worker.registration.descriptorPlusOne - 1),
      descriptorReady,
      cast[pointer](worker.registration.token),
    ).isErr:
      return
    worker.registration.armed = true
    true

proc beginReading(worker: TerminalSessionWorker) =
  worker.registration.closeDescriptor()
  if not worker.session.running():
    return
  when defined(posix):
    let duplicate = worker.session.duplicateReadDescriptor()
    if duplicate >= 0:
      worker.registration.descriptorPlusOne = duplicate + 1
      if register2(AsyncFD(duplicate)).isOk:
        worker.registration.registered = true
        if worker.arm():
          worker.watchFailed = false
          return
    worker.registration.closeDescriptor()
    worker.watchFailed = true
    worker.scheduleMaintenance()
  else:
    # Keep transport fallback work on the dispatcher too. Terminex currently
    # rejects native PTY startup here; a future backend can supply readiness.
    worker.watchFailed = true
    worker.scheduleMaintenance()

proc begin(worker: TerminalSessionWorker) {.slot.} =
  workers[worker.registration.token] = worker.unsafeWeakRef()

proc execute(worker: TerminalSessionWorker, command: sink TerminalCommand) {.slot.} =
  if command.kind == tcAcknowledge:
    if command.epoch == worker.epoch:
      worker.historyAdded = command.historyAdded
      worker.historyReset = command.historyReset
      if command.clipboardSerial == worker.clipboardSerial:
        worker.clipboard.setLen(0)
    if command.snapshotSerial >= worker.serial:
      worker.outstanding = false
      if worker.dirty:
        worker.requestPublish()
    else:
      # A final snapshot replaced the value after the UI consumed it but before
      # this ACK arrived. Its original wakeup has already been consumed too.
      emit worker.snapshotAvailable(worker.registration.token)
    return
  if command.epoch < worker.epoch:
    return
  worker.epoch = command.epoch
  worker.appliedCommand = command.serial
  try:
    case command.kind
    of tcWrite:
      worker.processedWriteBytes += uint64(command.text.len)
      worker.session.write(command.text)
    of tcResize:
      worker.session.resize(command.columns, command.rows)
    of tcClearScrollback:
      worker.session.clearScrollback()
    of tcProcessOutput:
      worker.session.processOutput(command.text)
    of tcSignal:
      discard worker.session.sendSignal(command.value)
    of tcInterrupt:
      discard worker.session.interrupt()
    of tcTerminate:
      discard worker.session.terminate()
    of tcReadLimit:
      worker.session.readLimit = command.value
    of tcWriteLimit:
      worker.session.writeLimit = command.value
    of tcClose, tcStart:
      worker.registration.closeDescriptor()
      if not worker.registration.maintenanceTimer.isNil:
        clearTimer(worker.registration.maintenanceTimer)
        worker.registration.maintenanceTimer = nil
      worker.outputClosed = false
      if command.kind == tcClose:
        worker.session.close()
      else:
        worker.commandError.setLen(0)
        worker.session.start(command.options)
        worker.beginReading()
    of tcAcknowledge:
      discard
  except CatchableError as error:
    worker.commandError = error.msg
  if worker.session.screenInfo().clipboardRequestPending:
    inc worker.clipboardSerial
    worker.clipboard = worker.session.takeClipboardRequest()
  worker.requestPublish(force = command.kind in {tcClose, tcStart})
  worker.scheduleMaintenance()

proc newTerminalSessionWorker*(
    session: sink CompactTerminalSession[TerminexCell],
    snapshots: RChan[TerminalSessionSnapshot],
    token, epoch: uint64,
): AgentProxy[TerminalSessionWorker] =
  let info = session.screenInfo()
  var worker = TerminalSessionWorker(
    session: ensureMove(session),
    snapshots: snapshots,
    registration: TerminalWorkerRegistration(token: token),
    epoch: epoch,
    historyAdded: info.scrollbackLinesAdded,
    historyReset: info.scrollbackResetCount,
  )
  result = worker.moveToThread(terminalWorkerThread())
  connectThreaded(result, beginRequested, result, begin)
  connectThreaded(result, commandRequested, result, execute)

var terminalSessionWorkerLifetime {.used.}: TerminalWorkerLifetime
