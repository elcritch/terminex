version       = "0.4.0"
author        = "Terminex contributors"
description   = "Reusable terminal-emulator state, ANSI parser, input encoder, and PTY transport."
license       = "BSD-3"
srcDir        = "src"

requires "nim >= 2.2.6"
requires "unicodedb >= 0.14.0"

feature "sigils":
  requires "sigils >= 0.31.0 [chronos]"
  requires "gh:status-im/nim-chronos >= 4.2.0"
