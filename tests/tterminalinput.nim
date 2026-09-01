import std/unittest

import terminex

suite "terminex terminal input":
  test "key translation covers every supported keyboard input":
    let
      modes = initTerminalModes()
      specialInputs = [
        (tkEnter, "\r"),
        (tkBackspace, "\x7f"),
        (tkTab, "\t"),
        (tkEscape, "\x1b"),
        (tkArrowUp, "\x1b[A"),
        (tkArrowDown, "\x1b[B"),
        (tkArrowRight, "\x1b[C"),
        (tkArrowLeft, "\x1b[D"),
        (tkHome, "\x1b[H"),
        (tkEnd, "\x1b[F"),
        (tkInsert, "\x1b[2~"),
        (tkDelete, "\x1b[3~"),
        (tkPageUp, "\x1b[5~"),
        (tkPageDown, "\x1b[6~"),
      ]
      functionInputs = [
        "\x1bOP", "\x1bOQ", "\x1bOR", "\x1bOS", "\x1b[15~", "\x1b[17~", "\x1b[18~",
        "\x1b[19~", "\x1b[20~", "\x1b[21~", "\x1b[23~", "\x1b[24~", "\x1b[25~",
        "\x1b[26~", "\x1b[28~",
      ]

    for (key, expected) in specialInputs:
      check terminalKeyInput(TerminexKeyEvent(key: key), modes) == expected
    for key in tkA .. tkZ:
      let expected = $char(key.ord - tkA.ord + 1)
      check terminalKeyInput(TerminexKeyEvent(key: key, modifiers: {tmControl}), modes) ==
        expected
    for index, expected in functionInputs:
      let key = TerminexKey(tkF1.ord + index)
      check terminalKeyInput(TerminexKeyEvent(key: key), modes) == expected

    check terminalKeyInput(
      TerminexKeyEvent(key: tkSpace, modifiers: {tmControl}), modes
    ) == "\x00"
    check terminalKeyInput(TerminexKeyEvent(key: tk2, modifiers: {tmControl}), modes) ==
      "\x00"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkLeftBracket, modifiers: {tmControl}), modes
    ) == "\x1b"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkBackslash, modifiers: {tmControl}), modes
    ) == "\x1c"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkRightBracket, modifiers: {tmControl}), modes
    ) == "\x1d"
    check terminalKeyInput(TerminexKeyEvent(key: tk6, modifiers: {tmControl}), modes) ==
      "\x1e"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkMinus, modifiers: {tmControl}), modes
    ) == "\x1f"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkBackspace, modifiers: {tmControl}), modes
    ) == "\x7f"
    check terminalKeyInput(TerminexKeyEvent(key: tkTab, modifiers: {tmShift}), modes) ==
      "\x1b[Z"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkX, text: "x", modifiers: {tmAlt}), modes
    ) == "\x1bx"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkF, text: "ƒ", modifiers: {tmAlt}), modes
    ) == "\x1bf"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkF, text: "ƒ", modifiers: {tmAlt}),
      modes,
      altAsMeta = false,
    ).len == 0
    check terminalKeyInput(
      TerminexKeyEvent(key: tkF, modifiers: {tmControl, tmAlt}), modes
    ) == "\x1b\x06"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkX, text: "X", modifiers: {tmShift}), modes
    ) == "X"
    check terminalKeyInput(
      TerminexKeyEvent(key: tkC, text: "c", modifiers: {tmSuper}), modes
    ).len == 0
    check terminalKeyInput(TerminexKeyEvent(key: tkUnknown), modes).len == 0

    var applicationModes = modes
    applicationModes.applicationCursorKeys = true
    check terminalKeyInput(TerminexKeyEvent(key: tkArrowUp), applicationModes) ==
      "\x1bOA"
    check terminalKeyInput(TerminexKeyEvent(key: tkArrowDown), applicationModes) ==
      "\x1bOB"
    check terminalKeyInput(TerminexKeyEvent(key: tkArrowRight), applicationModes) ==
      "\x1bOC"
    check terminalKeyInput(TerminexKeyEvent(key: tkArrowLeft), applicationModes) ==
      "\x1bOD"
    check terminalKeyInput(TerminexKeyEvent(key: tkHome), applicationModes) == "\x1bOH"
    check terminalKeyInput(TerminexKeyEvent(key: tkEnd), applicationModes) == "\x1bOF"

  test "paste and focus input honor the active terminal modes":
    var modes = initTerminalModes()
    check terminalPasteInput("hello", modes) == "hello"
    check terminalFocusInput(true, modes).len == 0
    check terminalFocusInput(false, modes).len == 0

    modes.bracketedPaste = true
    modes.focusReporting = true
    check terminalPasteInput("hello", modes) == "\x1b[200~hello\x1b[201~"
    check terminalFocusInput(true, modes) == "\x1b[I"
    check terminalFocusInput(false, modes) == "\x1b[O"

  test "mouse tracking and encoding follow xterm modes":
    var modes = initTerminalModes()
    for kind in TerminexMouseEventKind:
      check not modes.mouseTrackingAccepts(kind)

    modes.mouseTracking = tmtX10
    check modes.mouseTrackingAccepts(tmekPress)
    check not modes.mouseTrackingAccepts(tmekRelease)
    check not modes.mouseTrackingAccepts(tmekMotion)

    modes.mouseTracking = tmtButton
    for kind in TerminexMouseEventKind:
      check modes.mouseTrackingAccepts(kind)

    modes.mouseEncoding = tmeSgr
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbPrimary) == "\x1b[<0;3;2M"
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbPrimary, release = true) ==
      "\x1b[<0;3;2m"
    check encodeTerminalMouseInput(
      modes, 80, 24, 1, 2, tmbMiddle, modifiers = {tmShift, tmAlt, tmControl}
    ) == "\x1b[<29;3;2M"
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbPrimary, motion = true) ==
      "\x1b[<32;3;2M"
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbWheelUp) == "\x1b[<64;3;2M"
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbWheelDown) == "\x1b[<65;3;2M"

    modes.mouseEncoding = tmeUrxvt
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbSecondary) == "\x1b[34;3;2M"

    modes.mouseEncoding = tmeX10
    check encodeTerminalMouseInput(modes, 80, 24, 1, 2, tmbPrimary) == "\x1b[M #\""
    check encodeTerminalMouseInput(
      modes, 80, 24, 1, 2, tmbPrimary, modifiers = {tmControl}, release = true
    ) == "\x1b[M3#\""
