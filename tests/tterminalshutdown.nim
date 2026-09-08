## Inject only the process syscalls: a child stuck in kernel exit cannot be
## reproduced reliably with a real shell, even one that ignores SIGHUP.
import std/[monotimes, times, unittest]

when defined(posix):
  import std/posix

  var
    waitResult: Pid
    waitError: cint
    waitCalls: int
    signals: seq[cint]

  proc waitpid(child: Pid, status: var cint, options: cint): Pid =
    doAssert child == Pid(12345)
    # Fail immediately on the old blocking implementation, without hanging CI.
    doAssert options == WNOHANG
    inc waitCalls
    errno = waitError
    waitResult

  proc killpg(child: Pid, signal: cint): cint =
    doAssert child == Pid(12345)
    signals.add(signal)

  proc kill(child: Pid, signal: cint): cint =
    doAssert child == Pid(12345)
    signals.add(signal)

  include ../src/terminex/termsessions

  proc pendingSession(): auto =
    let session = newTerminalSession()
    session.xChildPid = Pid(12345)
    session.xState = tssRunning
    session

  suite "bounded terminal shutdown":
    setup:
      waitResult = 0
      waitError = 0
      waitCalls = 0
      signals.setLen(0)

    test "close times out and retains ownership until a later reap":
      let session = pendingSession()
      let started = getMonoTime()
      session.close()
      check getMonoTime() - started < initDuration(seconds = 1)
      check waitCalls > 1
      check session.state == tssClosed
      check session.xChildPid == Pid(12345)
      check signals == @[SIGHUP, SIGKILL, SIGKILL]

      waitResult = Pid(12345)
      signals.setLen(0)
      session.close()
      check session.xChildPid == 0
      check signals.len == 0
      let reapedCalls = waitCalls
      session.close()
      check waitCalls == reapedCalls

    test "destruction also bounds waits for an unreapable child":
      let started = getMonoTime()
      block:
        let session = pendingSession()
        check session.state == tssRunning
      check getMonoTime() - started < initDuration(seconds = 1)
      check waitCalls > 1
      check signals == @[SIGHUP, SIGKILL, SIGKILL]

    test "ECHILD clears ownership without signalling a possibly reused PID":
      let session = pendingSession()
      waitResult = -1
      waitError = ECHILD
      session.close()
      check session.xChildPid == 0
      check signals.len == 0

    test "interrupted and unexpected waits retain ownership":
      for error in [EINTR, EINVAL]:
        let session = pendingSession()
        waitResult = -1
        waitError = error
        session.close()
        check session.xChildPid == Pid(12345)
        waitError = ECHILD
        session.close()
        check session.xChildPid == 0

    test "restart cannot overwrite an unreaped child":
      let session = pendingSession()
      session.xState = tssClosed
      expect TerminexSessionError:
        session.start()
      check session.xChildPid == Pid(12345)
      check session.state == tssClosed
      waitResult = Pid(12345)
      session.close()
