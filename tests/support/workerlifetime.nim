## Import before the threaded adapter: this check runs after its module guard
## and before the core parser and trace globals are destroyed.
import std/atomics
import terminex
import terminex/termtrace

export terminex, termtrace

var
  workerStarted*: Atomic[bool]
  exitStarted*: Atomic[bool]
  workerFinished*: Atomic[bool]

type CheckWorkerExit = object

proc `=destroy`(check: CheckWorkerExit) =
  if workerStarted.load(moAcquire):
    doAssert workerFinished.load(moAcquire),
      "terminal dispatcher must finish before parser dependencies are destroyed"

var checkWorkerExit {.used.}: CheckWorkerExit
