## GUI-neutral xterm input encoding for terminal frontends.

import std/[strutils, unicode]

import ./termscreen

type
  TerminalModifier* = enum
    tmShift
    tmControl
    tmAlt
    tmSuper

  TerminalKey* = enum
    tkUnknown
    tkA
    tkB
    tkC
    tkD
    tkE
    tkF
    tkG
    tkH
    tkI
    tkJ
    tkK
    tkL
    tkM
    tkN
    tkO
    tkP
    tkQ
    tkR
    tkS
    tkT
    tkU
    tkV
    tkW
    tkX
    tkY
    tkZ
    tkTilde
    tk1
    tk2
    tk3
    tk4
    tk5
    tk6
    tk7
    tk8
    tk9
    tk0
    tkMinus
    tkEqual
    tkF1
    tkF2
    tkF3
    tkF4
    tkF5
    tkF6
    tkF7
    tkF8
    tkF9
    tkF10
    tkF11
    tkF12
    tkF13
    tkF14
    tkF15
    tkLeftBracket
    tkRightBracket
    tkSpace
    tkEscape
    tkEnter
    tkTab
    tkBackspace
    tkSlash
    tkDot
    tkComma
    tkSemicolon
    tkQuote
    tkBackslash
    tkPageUp
    tkPageDown
    tkHome
    tkEnd
    tkInsert
    tkDelete
    tkArrowLeft
    tkArrowRight
    tkArrowUp
    tkArrowDown
    tkNumpad0
    tkNumpad1
    tkNumpad2
    tkNumpad3
    tkNumpad4
    tkNumpad5
    tkNumpad6
    tkNumpad7
    tkNumpad8
    tkNumpad9
    tkNumpadDot
    tkAdd
    tkSubtract
    tkMultiply
    tkDivide

  TerminalKeyEvent* = object
    key*: TerminalKey
    text*: string
    modifiers*: set[TerminalModifier]

  TerminalMouseButton* = enum
    tmbPrimary
    tmbMiddle
    tmbSecondary
    tmbWheelUp
    tmbWheelDown

  TerminalMouseEventKind* = enum
    tmekPress
    tmekRelease
    tmekMotion

func controlCharacter(event: TerminalKeyEvent): string =
  if event.key in tkA .. tkZ:
    return $char(ord(event.key) - ord(tkA) + 1)
  case event.key
  of tkSpace, tk2: "\x00"
  of tkLeftBracket: "\x1b"
  of tkBackslash: "\x1c"
  of tkRightBracket: "\x1d"
  of tk6: "\x1e"
  of tkMinus: "\x1f"
  of tkBackspace: "\x7f"
  else: ""

func functionKeyInput(key: TerminalKey): string =
  case key
  of tkF1: "\x1bOP"
  of tkF2: "\x1bOQ"
  of tkF3: "\x1bOR"
  of tkF4: "\x1bOS"
  of tkF5: "\x1b[15~"
  of tkF6: "\x1b[17~"
  of tkF7: "\x1b[18~"
  of tkF8: "\x1b[19~"
  of tkF9: "\x1b[20~"
  of tkF10: "\x1b[21~"
  of tkF11: "\x1b[23~"
  of tkF12: "\x1b[24~"
  of tkF13: "\x1b[25~"
  of tkF14: "\x1b[26~"
  of tkF15: "\x1b[28~"
  else: ""

func printableKeyText(event: TerminalKeyEvent): string =
  let shifted = tmShift in event.modifiers
  if event.key in tkA .. tkZ:
    let letter = char(ord(event.key) - ord(tkA) + ord('a'))
    return $(if shifted: letter.toUpperAscii() else: letter)
  case event.key
  of tkTilde:
    result = if shifted: "~" else: "`"
  of tk1:
    result = if shifted: "!" else: "1"
  of tk2:
    result = if shifted: "@" else: "2"
  of tk3:
    result = if shifted: "#" else: "3"
  of tk4:
    result = if shifted: "$" else: "4"
  of tk5:
    result = if shifted: "%" else: "5"
  of tk6:
    result = if shifted: "^" else: "6"
  of tk7:
    result = if shifted: "&" else: "7"
  of tk8:
    result = if shifted: "*" else: "8"
  of tk9:
    result = if shifted: "(" else: "9"
  of tk0:
    result = if shifted: ")" else: "0"
  of tkMinus:
    result = if shifted: "_" else: "-"
  of tkEqual:
    result = if shifted: "+" else: "="
  of tkLeftBracket:
    result = if shifted: "{" else: "["
  of tkRightBracket:
    result = if shifted: "}" else: "]"
  of tkSpace:
    result = " "
  of tkSlash:
    result = if shifted: "?" else: "/"
  of tkDot:
    result = if shifted: ">" else: "."
  of tkComma:
    result = if shifted: "<" else: ","
  of tkSemicolon:
    result = if shifted: ":" else: ";"
  of tkQuote:
    result = if shifted: "\"" else: "'"
  of tkBackslash:
    result = if shifted: "|" else: "\\"
  of tkNumpad0 .. tkNumpad9:
    result = $char(ord(event.key) - ord(tkNumpad0) + ord('0'))
  of tkNumpadDot:
    result = "."
  of tkAdd:
    result = "+"
  of tkSubtract:
    result = "-"
  of tkMultiply:
    result = "*"
  of tkDivide:
    result = "/"
  else:
    discard

func terminalKeyInput*(
    event: TerminalKeyEvent, modes: TerminalModes, altAsMeta = true
): string =
  ## Translate a frontend-neutral key event into xterm-compatible bytes.
  if tmSuper in event.modifiers:
    return
  if tmControl in event.modifiers:
    result = event.controlCharacter()
  if result.len == 0:
    let prefix = if modes.applicationCursorKeys: "\x1bO" else: "\x1b["
    case event.key
    of tkEnter:
      result = "\r"
    of tkBackspace:
      result = "\x7f"
    of tkTab:
      result = if tmShift in event.modifiers: "\x1b[Z" else: "\t"
    of tkEscape:
      result = "\x1b"
    of tkArrowUp:
      result = prefix & "A"
    of tkArrowDown:
      result = prefix & "B"
    of tkArrowRight:
      result = prefix & "C"
    of tkArrowLeft:
      result = prefix & "D"
    of tkHome:
      result = prefix & "H"
    of tkEnd:
      result = prefix & "F"
    of tkInsert:
      result = "\x1b[2~"
    of tkDelete:
      result = "\x1b[3~"
    of tkPageUp:
      result = "\x1b[5~"
    of tkPageDown:
      result = "\x1b[6~"
    of tkF1 .. tkF15:
      result = event.key.functionKeyInput()
    else:
      if altAsMeta and tmAlt in event.modifiers:
        result = event.printableKeyText()
      elif tmAlt notin event.modifiers and event.modifiers - {tmShift} == {}:
        result = event.text
  if altAsMeta and tmAlt in event.modifiers and result.len > 0:
    result = "\x1b" & result

func terminalPasteInput*(text: string, modes: TerminalModes): string =
  ## Wrap pasted text when the application has enabled bracketed paste mode.
  if modes.bracketedPaste:
    "\x1b[200~" & text & "\x1b[201~"
  else:
    text

func terminalFocusInput*(focused: bool, modes: TerminalModes): string =
  ## Encode a focus change when the application has enabled focus reporting.
  if modes.focusReporting:
    if focused: "\x1b[I" else: "\x1b[O"
  else:
    ""

func mouseTrackingAccepts*(modes: TerminalModes, kind: TerminalMouseEventKind): bool =
  ## Report whether the active mouse-tracking mode accepts an event kind.
  case modes.mouseTracking
  of tmtNone:
    false
  of tmtX10:
    kind == tmekPress
  of tmtButton, tmtAny:
    kind in {tmekPress, tmekRelease, tmekMotion}

func mouseModifierCode(modifiers: set[TerminalModifier]): int =
  if tmShift in modifiers:
    result += 4
  if tmAlt in modifiers:
    result += 8
  if tmControl in modifiers:
    result += 16

func mouseButtonCode(button: TerminalMouseButton): int =
  case button
  of tmbPrimary: 0
  of tmbMiddle: 1
  of tmbSecondary: 2
  of tmbWheelUp: 64
  of tmbWheelDown: 65

func encodeTerminalMouseInput*(
    modes: TerminalModes,
    columns, rows, row, column: int,
    button: TerminalMouseButton,
    modifiers: set[TerminalModifier] = {},
    release = false,
    motion = false,
): string =
  ## Encode an xterm mouse event. `row` and `column` are zero-based.
  var code = button.mouseButtonCode() + modifiers.mouseModifierCode()
  if motion:
    code += 32
  let x = clamp(column + 1, 1, max(columns, 1))
  let y = clamp(row + 1, 1, max(rows, 1))
  case modes.mouseEncoding
  of tmeSgr:
    "\x1b[<" & $code & ";" & $x & ";" & $y & (if release: "m" else: "M")
  of tmeUrxvt:
    "\x1b[" & $(code + 32) & ";" & $x & ";" & $y & "M"
  of tmeX10, tmeUtf8:
    let releaseCode =
      if release:
        3 + modifiers.mouseModifierCode()
      else:
        code
    "\x1b[M" & $Rune(clamp(releaseCode + 32, 32, 255)) & $Rune(clamp(x + 32, 32, 255)) &
      $Rune(clamp(y + 32, 32, 255))
