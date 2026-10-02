## Observable command completion for tests of the asynchronous terminal API.
import std/[monotimes, os, times, unittest]
import sigils/threads
import terminex/threaded

proc waitForCommands*(session: ThreadedTerminalSession) =
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while session.pendingCommands() > 0 and getMonoTime() < deadline:
    discard getCurrentSigilThread().pollAll(NonBlocking)
    discard session.poll()
    sleep(1)
  require session.pendingCommands() == 0

proc closeAndWait*(session: ThreadedTerminalSession) =
  session.close()
  session.waitForCommands()
