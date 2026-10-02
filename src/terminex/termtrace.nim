## Optional terminal-to-native-presentation timing, enabled with
## `-d:terminexTrace`. Events contain timings and identities, never PTY text.

when defined(terminexTrace):
  import std/[locks, monotimes]

  type TerminalTraceEvent* = object
    stage*: string
    ticks*: int64
    thread*: int
    identity*, detail*: uint64

  var
    traceLock: Lock
    traceEvents: seq[TerminalTraceEvent]
    traceDropped: int

  initLock(traceLock)

  proc terminalTraceTime*(): int64 =
    getMonoTime().ticks

  proc recordTerminalTrace*(
      stage: string, identity = 0'u64, detail = 0'u64, ticks = 0'i64
  ) {.gcsafe.} =
    let event = TerminalTraceEvent(
      stage: stage,
      ticks:
        if ticks == 0:
          getMonoTime().ticks
        else:
          ticks,
      thread: getThreadId(),
      identity: identity,
      detail: detail,
    )
    {.cast(gcsafe).}:
      withLock traceLock:
        if traceEvents.len < 100_000:
          traceEvents.add event
        else:
          inc traceDropped

  proc takeTerminalTrace*(): tuple[events: seq[TerminalTraceEvent], dropped: int] =
    ## Drain after stopping producers to obtain the complete trace.
    withLock traceLock:
      result = (move(traceEvents), traceDropped)
      traceDropped = 0

else:
  template terminalTraceTime*(): int64 =
    0'i64

  template recordTerminalTrace*(
      stage: string, identity = 0'u64, detail = 0'u64, ticks = 0'i64
  ) =
    discard
