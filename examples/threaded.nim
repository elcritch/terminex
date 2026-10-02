import std/[monotimes, os, times]
import sigils/threads
import terminex/threaded

block:
  let session = newThreadedTerminalSession()
  session.processOutput("parsed on the worker\r\n")
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while session.pendingCommands() > 0 and getMonoTime() < deadline:
    discard getCurrentSigilThread().pollAll(NonBlocking)
    discard session.poll()
    sleep(1)
  doAssert session.pendingCommands() == 0
  echo session.screen().plainText()
  session.close()
  let closeDeadline = getMonoTime() + initDuration(seconds = 5)
  while session.pendingCommands() > 0 and getMonoTime() < closeDeadline:
    discard getCurrentSigilThread().pollAll(NonBlocking)
    discard session.poll()
    sleep(1)
  doAssert session.pendingCommands() == 0
shutdownTerminalWorkers()
