when defined(features.terminex.sigils) or defined(feature.terminex.sigils):
  ## The command/snapshot path must also work without a native PTY backend.
  import std/[atomics, monotimes, os, strutils, tempfiles, times, unittest]
  import sigils/[core, threads]
  import threading/smartptrs
  import terminex/threaded
  import ./support/threadedhelpers

  suite "Terminal worker ownership":
    test "offline parsing and resizing use queued commands on every platform":
      let session = newThreadedTerminalSession(columns = 12, rows = 2)
      defer:
        session.closeAndWait()
      let original = session.screen()
      session.processOutput("one\r\ntwo\r\nthree")
      session.resize(16, 3)
      check session.pendingCommands() == 2
      check session.screenInfo().columns == 12
      check session.screen().plainText() == ""
      session.waitForCommands()
      check session.screenInfo().columns == 16
      check session.screenInfo().rows == 3
      check "three" in session.screen().plainText()
      check original.plainText() == ""
      check original.columns == 12

    test "independent sessions keep their own history and clipboard requests":
      let first = newThreadedTerminalSession(columns = 12, rows = 2, maxScrollback = 3)
      let second = newThreadedTerminalSession(columns = 12, rows = 2, maxScrollback = 5)
      defer:
        first.closeAndWait()
        second.closeAndWait()
      first.processOutput("a\r\nb\r\nc\r\nd\r\ne\r\nf\x1b]52;c;aGVsbG8=\x07")
      second.processOutput("other\r\ntext\r\nhistory")
      first.waitForCommands()
      second.waitForCommands()
      check first.screenInfo().scrollbackCount == 3
      check second.screenInfo().scrollbackCount == 1
      # A later snapshot/ACK must not consume an unread clipboard request.
      first.clearScrollback()
      first.waitForCommands()
      check first.screenInfo().scrollbackCount == 0
      check first.screenInfo().clipboardRequestPending
      check first.takeClipboardRequest() == "hello"
      check not first.screenInfo().clipboardRequestPending
      check not second.screenInfo().clipboardRequestPending
      check second.screen().plainText() == "other\ntext\nhistory"

    when not defined(posix):
      test "unsupported native startup reports its failure through the worker":
        let session = newThreadedTerminalSession()
        defer:
          session.closeAndWait()
        session.start()
        session.waitForCommands()
        check session.state() == tssFailed
        check session.lastError().len > 0

  when defined(posix):
    type
      WorkerGateState = object
        entered, released, timedOut: Atomic[bool]

      WorkerGate = ref object of AgentActor
        state: SharedPtr[WorkerGateState]

      OutputSpy = ref object of Agent
        notifications: int

    proc enterGate(worker: AgentProxy[WorkerGate]) {.signal.}
    proc enterGate(worker: WorkerGate) {.slot.} =
      worker.state[].entered.store(true, moRelease)
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while not worker.state[].released.load(moAcquire) and getMonoTime() < deadline:
        sleep(1)
      if not worker.state[].released.load(moAcquire):
        worker.state[].timedOut.store(true, moRelease)

    proc outputAvailable(spy: OutputSpy) {.slot.} =
      inc spy.notifications

    template waitFor(condition: untyped) =
      block:
        let deadline = getMonoTime() + initDuration(seconds = 10)
        while not (condition) and getMonoTime() < deadline:
          discard getCurrentSigilThread().pollAll(NonBlocking)
          sleep(1)
        require condition

    suite "Threaded PTY ownership":
      test "output notifications coalesce without losing a flood or its exit":
        let session =
          newThreadedTerminalSession(columns = 60, rows = 3, maxScrollback = 8)
        let spy = OutputSpy()
        session.connect(sessionOutputAvailable, spy, outputAvailable)
        session.start(
          initTerminalSpawnOptions(
            shell = "/bin/sh",
            command =
              "stty -echo; printf 'ready\\n'; IFS= read -r start; " &
              "i=0; while [ $i -lt 10000 ]; do printf 'worker-line\\n'; i=$((i+1)); done; " &
              "printf 'worker-final\\n'; exit 9",
          )
        )
        defer:
          session.closeAndWait()
        waitFor("ready" in session.screen().plainText())
        discard session.poll()
        spy.notifications = 0
        let original = session.screen()
        session.write("start\n")
        waitFor(session.state() == tssExited)
        check spy.notifications == 1
        check "worker-final" in session.screen().plainText()
        check "worker-final" notin original.plainText()
        check session.exitCode() == 9
        check session.screenInfo().scrollbackCount == 8
        check session.poll().bytesRead > 100_000
        check session.poll().bytesRead == 0
        check session.poll().processExited

      test "withholding snapshots cannot block the PTY worker":
        let root = createTempDir("terminex-backpressure-", "")
        let marker = root / "drained"
        let session = spawnThreadedTerminalSession(
          initTerminalSpawnOptions(
            shell = "/bin/sh",
            command =
              "i=0; while [ $i -lt 2048 ]; do printf 'payload-abcdefghijklmnopqrstuvwxyz-0123456789\\n'; i=$((i+1)); done; " &
              "printf 'last-output\\n'; touch " & quoteShell(marker) & "; exit 11",
          ),
          rows = 3,
          maxScrollback = 10,
        )
        defer:
          session.closeAndWait()
          removeDir(root)
        # Deliberately withhold Sigils dispatch and ACKs until the child proves
        # the worker drained more than a PTY buffer without a consumer.
        let deadline = getMonoTime() + initDuration(seconds = 10)
        while not fileExists(marker) and getMonoTime() < deadline:
          sleep(1)
        require fileExists(marker)
        check session.screen().plainText() == ""
        waitFor(session.state() == tssExited)
        check session.exitCode() == 11
        check session.screenInfo().scrollbackCount == 10
        check "last-output" in session.screen().plainText()
        check session.poll().bytesRead > 90_000

      test "queries stay local and queued input reserves capacity while the worker is blocked":
        let session = spawnThreadedTerminalSession(
          initTerminalSpawnOptions(
            shell = "/bin/sh",
            command =
              "stty -echo; printf 'ready\\n'; while IFS= read -r line; do stty size; printf 'received:%s\\n' \"$line\"; done",
          ),
          columns = 60,
          rows = 8,
        )
        defer:
          session.closeAndWait()
        waitFor("ready" in session.screen().plainText())
        session.writeLimit = 8
        session.waitForCommands()
        let state = newSharedPtr(WorkerGateState())
        var actor = WorkerGate(state: state)
        let gate = actor.moveToThread(terminalWorkerThread())
        connectThreaded(gate, enterGate, gate, WorkerGate.enterGate())
        defer:
          state[].released.store(true, moRelease)
        emit gate.enterGate()
        waitFor(state[].entered.load(moAcquire))
        check not state[].timedOut.load(moAcquire)
        let original = session.screen()
        session.resize(41, 7)
        session.write("ordered\n")
        check session.pendingWriteBytes() == 8
        expect TerminexSessionError:
          session.write("overflow")
        check session.pendingCommands() == 2
        check session.screenInfo().columns == 60
        check not state[].timedOut.load(moAcquire)
        state[].released.store(true, moRelease)
        check not gate.isNil
        waitFor(
          session.pendingCommands() == 0 and
            "received:ordered" in session.screen().plainText()
        )
        check "7 41" in session.screen().plainText()
        check session.pendingWriteBytes() == 0
        check original.columns == 60

      test "close and restart discard stale lifecycle snapshots":
        let session = spawnThreadedTerminalSession(
          initTerminalSpawnOptions(
            shell = "/bin/sh",
            command = "stty -echo; printf 'first-ready\\n'; IFS= read -r line",
          )
        )
        defer:
          session.closeAndWait()
        waitFor("first-ready" in session.screen().plainText())
        session.close()
        check not session.running()
        session.start(
          initTerminalSpawnOptions(
            shell = "/bin/sh", command = "printf 'second-final\\n'; exit 7"
          )
        )
        waitFor(session.state() == tssExited and session.pendingCommands() == 0)
        check session.exitCode() == 7
        check "second-final" in session.screen().plainText()
        check session.poll().processExited
        check session.poll().processExited

  suite "Terminal dispatcher lifecycle":
    test "explicit shutdown is repeatable and new sessions can restart the dispatcher":
      block:
        let session = newThreadedTerminalSession()
        session.processOutput("before shutdown")
        session.waitForCommands()
        session.closeAndWait()
      shutdownTerminalWorkers()
      shutdownTerminalWorkers()
      block:
        let session = newThreadedTerminalSession()
        session.processOutput("after shutdown")
        session.waitForCommands()
        check session.screen().plainText() == "after shutdown"
        session.closeAndWait()
