# Terminex

Terminex is a GUI-independent Nim terminal-emulator core. It provides a screen
and scrollback model, an incremental ECMA-48/VT parser, xterm input encoding,
and POSIX PTY session transport. GUI toolkits own rendering, event translation,
selections, and clipboard policy.

## Install and test

```sh
atlas install
atlas-run tests
```

## Use

```nim
import terminex

let session = spawnTerminalSession(
  initTerminalSpawnOptions(command = "printf 'hello\\n'"),
  columns = 80,
  rows = 24,
)
defer: session.close()
while session.running:
  discard session.poll()
echo session.screen.plainText()
```

The input helpers turn frontend key, mouse, paste, and focus events into terminal
bytes. `TerminalSpawnOptions.terminalProgram` defaults to `"Terminex"`; set it
to an empty string to omit `TERM_PROGRAM`.
