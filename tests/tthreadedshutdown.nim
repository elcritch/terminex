## Separate process: deliberately keep a worker task active until Nim teardown.
when defined(features.terminex.sigils) or defined(feature.terminex.sigils):
  import std/[atomics, monotimes, os, times, unittest]
  import sigils/[core, threads]
  import ./support/workerlifetime
  import terminex/threaded

  type
    ExitWorker = ref object of AgentActor
    ReleaseWorkerAtExit = object

  proc `=destroy`(release: ReleaseWorkerAtExit) =
    exitStarted.store(true, moRelease)

  var releaseWorkerAtExit {.used.}: ReleaseWorkerAtExit

  proc parseAtExit(worker: AgentProxy[ExitWorker]) {.signal.}
  proc parseAtExit(worker: ExitWorker) {.slot.} =
    workerStarted.store(true, moRelease)
    let deadline = getMonoTime() + initDuration(seconds = 60)
    while not exitStarted.load(moAcquire) and getMonoTime() < deadline:
      sleep(1)
    doAssert exitStarted.load(moAcquire), "main thread did not begin shutdown"
    let session = newCompactTerminalSession(columns = 30, rows = 3)
    for index in 0 ..< 1000:
      session.processOutput("\x1b[32mterminal 界\x1b[0m\r\n")
    doAssert session.screenInfo().scrollbackCount > 0
    recordTerminalTrace("shutdown-parse")
    workerFinished.store(true, moRelease)

  suite "Terminal worker automatic shutdown":
    test "module guard joins active work before core dependencies are destroyed":
      var actor = ExitWorker()
      let worker = actor.moveToThread(terminalWorkerThread())
      connectThreaded(worker, parseAtExit, worker, parseAtExit)
      emit worker.parseAtExit()
      let deadline = getMonoTime() + initDuration(seconds = 60)
      while not workerStarted.load(moAcquire) and getMonoTime() < deadline:
        discard getCurrentSigilThread().pollAll(NonBlocking)
        sleep(1)
      require workerStarted.load(moAcquire)
      check not workerFinished.load(moAcquire)
      # The release guard above permits parsing during global destruction.
