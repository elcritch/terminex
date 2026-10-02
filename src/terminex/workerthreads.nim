## Shared, application-lifetime execution for optional Sigils terminal sessions.
## All access and shutdown calls belong to the facade's owning thread.

import std/exitprocs
import sigils/[threads, threadChronos]

var
  dispatcher {.threadvar.}: SigilChronosThreadPtr
  exitRegistered {.threadvar.}: bool

proc shutdownTerminalWorkers*() {.noconv.} =
  ## Stop and join the calling thread's shared terminal dispatcher. Repeated
  ## calls are harmless. Close sessions first and discard their facades before
  ## shutdown; new sessions may create a fresh dispatcher afterward.
  if not dispatcher.isNil:
    try:
      dispatcher.stop(immediate = true)
    finally:
      try:
        dispatcher.join()
      finally:
        dispatcher = nil

type TerminalWorkerLifetime* = object
  ## Module guard for applications whose own globals outlive Terminex. Declare
  ## it after those globals so worker tasks finish before their dependencies.

proc `=destroy`(lifetime: TerminalWorkerLifetime) {.raises: [].} =
  try:
    shutdownTerminalWorkers()
  except Exception:
    discard

proc terminalWorkerThread*(): SigilChronosThreadPtr =
  ## Borrow the calling thread's shared PTY dispatcher. It sleeps on readiness
  ## while idle and is independent of Sigils' general worker pool.
  startLocalThreadDefault()
  if dispatcher.isNil:
    dispatcher = newSigilChronosThread()
    dispatcher.start()
  if not exitRegistered:
    addExitProc(shutdownTerminalWorkers)
    exitRegistered = true
  dispatcher

var workerLifetime {.used.}: TerminalWorkerLifetime
