## Internal command and snapshot wire values for the Sigils adapter.

import ../termsnapshots

type
  TerminalSessionSnapshot* = object
    ## History is cumulative since the last acknowledged snapshot. Replacing an
    ## unread snapshot therefore cannot lose retained history or final output.
    epoch*, serial*, workerToken*, readSerial*, bytesRead*: uint64
    screen*: TerminalScreenUpdate
    state*: TerminexSessionState
    exitCode*, pendingWriteBytes*, readLimit*, writeLimit*: int
    lastError*: string
    outputClosed*: bool
    clipboardSerial*: uint64
    clipboard*: string
    appliedCommand*, processedWriteBytes*: uint64

  TerminalCommandKind* = enum
    tcWrite
    tcResize
    tcClearScrollback
    tcProcessOutput
    tcSignal
    tcInterrupt
    tcTerminate
    tcStart
    tcClose
    tcReadLimit
    tcWriteLimit
    tcAcknowledge

  TerminalCommand* = object
    kind*: TerminalCommandKind
    epoch*, serial*: uint64
    text*: string
    columns*, rows*, value*: int
    options*: TerminexSpawnOptions
    snapshotSerial*, historyAdded*, historyReset*, clipboardSerial*: uint64
