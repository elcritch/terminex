## Incremental ECMA-48/VT parser that applies terminal output to a screen.

import std/[base64, strutils]

import ./termscreen

const
  MaxTerminalCsiBytes* = 1024
  MaxTerminalStringBytes* = 64 * 1024
  ReplacementCharacter = "\xef\xbf\xbd"

type
  CsiParameter = object
    value: int
    subparameters: seq[int]

  TerminexParserState* = enum
    tpsGround
    tpsEscape
    tpsCsi
    tpsOsc
    tpsOscEscape
    tpsString
    tpsStringEscape
    tpsCharset
    tpsCsiIgnore

  TerminexParser* = object
    state*: TerminexParserState
    sequence: string
    incompleteUtf8: string
    discardingOsc: bool

func initTerminalParser*(): TerminexParser =
  TerminexParser(state: tpsGround)

proc parseDecimal(value: string, number: var int): bool =
  if value.len == 0:
    return
  number = 0
  for character in value:
    if character notin {'0' .. '9'}:
      return
    let digit = ord(character) - ord('0')
    if number > (high(int) - digit) div 10:
      return
    number = number * 10 + digit
  true

func parameterValue(
    parameters: openArray[CsiParameter], index, fallback: int, zeroIsFallback = true
): int =
  if index >= parameters.len:
    return fallback
  if zeroIsFallback and parameters[index].value == 0:
    fallback
  else:
    parameters[index].value

proc parseParameters(value: string): seq[CsiParameter] =
  for group in value.split(';'):
    let fields = group.split(':')
    var parameter: CsiParameter
    if fields[0].len > 0 and not parseDecimal(fields[0], parameter.value):
      return @[]
    for index in 1 ..< fields.len:
      var subparameter = -1
      if fields[index].len > 0 and not parseDecimal(fields[index], subparameter):
        return @[]
      parameter.subparameters.add subparameter
    result.add parameter

proc applyColonColor(color: var TerminexColor, values: openArray[int]) =
  if values.len == 2 and values[0] == 5 and values[1] >= 0:
    color = indexedTerminalColor(uint8(clamp(values[1], 0, 255)))
  elif values.len in {4, 5} and values[0] == 2:
    # The standard form includes a colorspace field, which xterm ignores.
    let first = if values.len == 5: 2 else: 1
    if values[first] >= 0 and values[first + 1] >= 0 and values[first + 2] >= 0:
      color = rgbTerminalColor(
        uint8(clamp(values[first], 0, 255)),
        uint8(clamp(values[first + 1], 0, 255)),
        uint8(clamp(values[first + 2], 0, 255)),
      )

proc applyExtendedColor(
    color: var TerminexColor, parameters: openArray[CsiParameter], index: var int
) =
  if parameters[index].subparameters.len > 0:
    color.applyColonColor(parameters[index].subparameters)
    inc index
    return
  if index + 1 >= parameters.len:
    inc index
    return
  if parameters[index + 1].subparameters.len > 0:
    var values = @[parameters[index + 1].value]
    values.add parameters[index + 1].subparameters
    color.applyColonColor(values)
    inc index, 2
    return
  case parameters[index + 1].value
  of 5:
    if index + 2 < parameters.len:
      if parameters[index + 2].subparameters.len == 0:
        color = indexedTerminalColor(uint8(clamp(parameters[index + 2].value, 0, 255)))
      inc index, 3
    else:
      inc index, 2
  of 2:
    if index + 4 < parameters.len:
      if parameters[index + 2].subparameters.len == 0 and
          parameters[index + 3].subparameters.len == 0 and
          parameters[index + 4].subparameters.len == 0:
        color = rgbTerminalColor(
          uint8(clamp(parameters[index + 2].value, 0, 255)),
          uint8(clamp(parameters[index + 3].value, 0, 255)),
          uint8(clamp(parameters[index + 4].value, 0, 255)),
        )
      inc index, 5
    else:
      index = parameters.len
  else:
    inc index, 2

proc applyUnderline(style: var TerminexStyle, value: int) =
  case value
  of 0:
    style.attributes.excl taUnderline
    style.attributes.excl taDoubleUnderline
  of 1:
    style.attributes.excl taDoubleUnderline
    style.attributes.incl taUnderline
  of 2:
    style.attributes.excl taUnderline
    style.attributes.incl taDoubleUnderline
  else:
    discard

proc applyGraphicAttribute[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], code: int
) =
  case code
  of 0:
    screen.style = initTerminalStyle()
  of 1:
    screen.style.attributes.incl taBold
  of 2:
    screen.style.attributes.incl taFaint
  of 3:
    screen.style.attributes.incl taItalic
  of 4:
    screen.style.applyUnderline(1)
  of 5, 6:
    screen.style.attributes.incl taBlink
  of 7:
    screen.style.attributes.incl taInverse
  of 8:
    screen.style.attributes.incl taHidden
  of 9:
    screen.style.attributes.incl taStrikethrough
  of 21:
    screen.style.applyUnderline(2)
  of 22:
    screen.style.attributes.excl taBold
    screen.style.attributes.excl taFaint
  of 23:
    screen.style.attributes.excl taItalic
  of 24:
    screen.style.applyUnderline(0)
  of 25:
    screen.style.attributes.excl taBlink
  of 27:
    screen.style.attributes.excl taInverse
  of 28:
    screen.style.attributes.excl taHidden
  of 29:
    screen.style.attributes.excl taStrikethrough
  of 30 .. 37:
    screen.style.foreground = indexedTerminalColor(uint8(code - 30))
  of 39:
    screen.style.foreground = defaultTerminalColor()
  of 40 .. 47:
    screen.style.background = indexedTerminalColor(uint8(code - 40))
  of 49:
    screen.style.background = defaultTerminalColor()
  of 53:
    screen.style.attributes.incl taOverline
  of 55:
    screen.style.attributes.excl taOverline
  of 59:
    screen.style.underlineColor = defaultTerminalColor()
  of 90 .. 97:
    screen.style.foreground = indexedTerminalColor(uint8(code - 90 + 8))
  of 100 .. 107:
    screen.style.background = indexedTerminalColor(uint8(code - 100 + 8))
  else:
    discard

proc applyGraphicRendition[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], parameters: seq[CsiParameter]
) =
  var index = 0
  while index < parameters.len:
    let parameter = parameters[index]
    case parameter.value
    of 38:
      applyExtendedColor(screen.style.foreground, parameters, index)
    of 48:
      applyExtendedColor(screen.style.background, parameters, index)
    of 58:
      applyExtendedColor(screen.style.underlineColor, parameters, index)
    else:
      if parameter.subparameters.len == 0:
        screen.applyGraphicAttribute(parameter.value)
      elif parameter.value == 4 and parameter.subparameters.len == 1:
        screen.style.applyUnderline(parameter.subparameters[0])
      inc index

proc setPrivateMode[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], mode: int, enabled: bool
) =
  case mode
  of 1:
    screen.modes.applicationCursorKeys = enabled
  of 6:
    screen.modes.origin = enabled
    screen.moveCursor(0, 0)
  of 7:
    screen.modes.autoWrap = enabled
  of 12:
    screen.cursor.blinking = enabled
  of 25:
    screen.cursor.visible = enabled
  of 47, 1047:
    screen.useAlternateScreen(enabled, saveRestore = false)
  of 1048:
    if enabled:
      screen.saveCursor()
    else:
      screen.restoreCursor()
  of 1049:
    screen.useAlternateScreen(enabled, saveRestore = true)
  of 9:
    screen.modes.mouseTracking = if enabled: tmtX10 else: tmtNone
  of 1000, 1002:
    screen.modes.mouseTracking = if enabled: tmtButton else: tmtNone
  of 1003:
    screen.modes.mouseTracking = if enabled: tmtAny else: tmtNone
  of 1004:
    screen.modes.focusReporting = enabled
  of 1005:
    screen.modes.mouseEncoding = if enabled: tmeUtf8 else: tmeX10
  of 1006:
    screen.modes.mouseEncoding = if enabled: tmeSgr else: tmeX10
  of 1007:
    screen.modes.alternateScroll = enabled
  of 1015:
    screen.modes.mouseEncoding = if enabled: tmeUrxvt else: tmeX10
  of 2004:
    screen.modes.bracketedPaste = enabled
  else:
    discard

proc applyMode[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback],
    parameters: seq[CsiParameter],
    privateMode, enabled: bool,
) =
  for mode in parameters:
    if privateMode:
      screen.setPrivateMode(mode.value, enabled)
    elif mode.value == 4:
      screen.modes.insert = enabled

proc setCursorStyle[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], value: int
) =
  case value
  of 0, 1:
    screen.cursor.shape = tcsBlock
    screen.cursor.blinking = true
  of 2:
    screen.cursor.shape = tcsBlock
    screen.cursor.blinking = false
  of 3:
    screen.cursor.shape = tcsUnderline
    screen.cursor.blinking = true
  of 4:
    screen.cursor.shape = tcsUnderline
    screen.cursor.blinking = false
  of 5:
    screen.cursor.shape = tcsBar
    screen.cursor.blinking = true
  of 6:
    screen.cursor.shape = tcsBar
    screen.cursor.blinking = false
  else:
    discard

proc processCsi[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], sequence: string
) =
  if sequence.len == 0:
    return
  let
    finalByte = sequence[^1]
    body = sequence[0 ..^ 2]
    privateMarker =
      if body.len > 0 and body[0] in {'<', '=', '>', '?'}:
        body[0]
      else:
        '\0'
    privateMode = privateMarker == '?'
    secondary = privateMarker == '>'
    parameterStart = if privateMarker != '\0': 1 else: 0
  # Private controls have their own meanings. Unsupported keyboard controls such
  # as CSI > 4 ; 2 m and CSI ? u must not fall through to SGR or cursor restore.
  case privateMarker
  of '?':
    if finalByte notin {'J', 'K', 'h', 'l', 'n'}:
      return
  of '>':
    if finalByte != 'c':
      return
  of '<', '=':
    return
  else:
    discard
  var parameterEnd = parameterStart
  while parameterEnd < body.len and body[parameterEnd] in {'0' .. '9', ';', ':'}:
    inc parameterEnd
  let intermediate = body[parameterEnd ..< body.len]
  if intermediate.len > 0 and
      not (privateMarker == '\0' and finalByte == 'q' and intermediate == " "):
    return
  let parameters = parseParameters(body[parameterStart ..< parameterEnd])
  if parameters.len == 0:
    return
  if finalByte != 'm':
    for parameter in parameters:
      if parameter.subparameters.len > 0:
        return
  let first = parameterValue(parameters, 0, 1)

  case finalByte
  of 'A':
    screen.moveCursorRelative(-first, 0)
  of 'B', 'e':
    screen.moveCursorRelative(first, 0)
  of 'C', 'a':
    screen.moveCursorRelative(0, first)
  of 'D':
    screen.moveCursorRelative(0, -first)
  of 'E':
    screen.moveCursorRelative(first, 0)
    screen.carriageReturn()
  of 'F':
    screen.moveCursorRelative(-first, 0)
    screen.carriageReturn()
  of 'G', '`':
    screen.moveCursorRelative(0, (first - 1) - screen.cursor.position.column)
  of 'H', 'f':
    screen.moveCursor(
      parameterValue(parameters, 0, 1) - 1, parameterValue(parameters, 1, 1) - 1
    )
  of 'd':
    screen.moveCursor(first - 1, screen.cursor.position.column)
  of 'J':
    screen.eraseInDisplay(parameterValue(parameters, 0, 0, zeroIsFallback = false))
  of 'K':
    screen.eraseInLine(parameterValue(parameters, 0, 0, zeroIsFallback = false))
  of 'L':
    screen.insertLines(first)
  of 'M':
    screen.deleteLines(first)
  of '@':
    screen.insertCells(first)
  of 'P':
    screen.deleteCells(first)
  of 'X':
    screen.eraseCells(first)
  of 'S':
    screen.scrollUp(first)
  of 'T':
    # The five-parameter form starts unsupported mouse highlight tracking.
    if parameters.len == 1:
      screen.scrollDown(first)
  of 'b':
    screen.repeatLastText(first)
  of 'c':
    if secondary:
      screen.queueReply("\x1b[>0;1;0c")
    else:
      screen.queueReply("\x1b[?62;22c")
  of 'g':
    let mode = parameterValue(parameters, 0, 0, zeroIsFallback = false)
    screen.clearTabStop(all = mode == 3)
  of 'h':
    screen.applyMode(parameters, privateMode, true)
  of 'l':
    screen.applyMode(parameters, privateMode, false)
  of 'm':
    screen.applyGraphicRendition(parameters)
  of 'n':
    let mode = parameterValue(parameters, 0, 0, zeroIsFallback = false)
    if privateMode and mode == 6:
      screen.queueReply(
        "\x1b[?" & $(screen.cursor.position.row + 1) & ";" &
          $(screen.cursor.position.column + 1) & "R"
      )
    elif not privateMode and mode == 5:
      screen.queueReply("\x1b[0n")
    elif not privateMode and mode == 6:
      screen.queueReply(
        "\x1b[" & $(screen.cursor.position.row + 1) & ";" &
          $(screen.cursor.position.column + 1) & "R"
      )
  of 'r':
    screen.setScrollRegion(
      parameterValue(parameters, 0, 1) - 1,
      parameterValue(parameters, 1, screen.rows) - 1,
    )
  of 's':
    screen.saveCursor()
  of 'u':
    screen.restoreCursor()
  of 'q':
    if intermediate == " ":
      screen.setCursorStyle(parameterValue(parameters, 0, 0, zeroIsFallback = false))
  else:
    discard

proc processOsc[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], sequence: string
) =
  let separator = sequence.find(';')
  if separator < 0:
    return
  var command = 0
  if not parseDecimal(sequence[0 ..< separator], command):
    return
  let payload = sequence[separator + 1 ..< sequence.len]
  case command
  of 0:
    screen.iconName = payload
    screen.title = payload
  of 1:
    screen.iconName = payload
  of 2:
    screen.title = payload
  of 7:
    screen.currentDirectory = payload
  of 8:
    let uriSeparator = payload.find(';')
    screen.style.hyperlink =
      if uriSeparator >= 0:
        payload[uriSeparator + 1 ..< payload.len]
      else:
        ""
  of 52:
    let dataSeparator = payload.find(';')
    if dataSeparator >= 0:
      let encoded = payload[dataSeparator + 1 ..< payload.len]
      if encoded == "?":
        screen.queueReply("\x1b]52;c;" & encode(screen.clipboardText) & "\x1b\\")
      else:
        try:
          screen.clipboardText = decode(encoded)
          screen.clipboardRequestPending = true
        except ValueError:
          discard
  else:
    discard

proc processControl[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], character: char
) =
  case character
  of '\x07':
    screen.ringBell()
  of '\x08':
    screen.backspace()
  of '\x09':
    screen.horizontalTab()
  of '\x0a', '\x0b', '\x0c':
    screen.lineFeed()
  of '\x0d':
    screen.carriageReturn()
  else:
    discard

proc processEscape[Cell, Line, Scrollback](
    screen: var TerminexScreen[Cell, Line, Scrollback], character: char
) =
  case character
  of '7':
    screen.saveCursor()
  of '8':
    screen.restoreCursor()
  of 'D':
    screen.lineFeed()
  of 'E':
    screen.nextLine()
  of 'H':
    screen.setTabStop()
  of 'M':
    screen.reverseIndex()
  of 'c':
    screen.reset()
  of '=':
    screen.modes.applicationKeypad = true
  of '>':
    screen.modes.applicationKeypad = false
  else:
    discard

func utf8Length(character: char): int =
  let value = character.uint8
  if value <= 0x7f'u8:
    1
  elif value in 0xc2'u8 .. 0xdf'u8:
    2
  elif value in 0xe0'u8 .. 0xef'u8:
    3
  elif value in 0xf0'u8 .. 0xf4'u8:
    4
  else:
    0

func validContinuation(character: char): bool =
  character.uint8 in 0x80'u8 .. 0xbf'u8

func validUtf8Sequence(value: string): bool =
  if value.len < 2:
    return value.len == 1 and value[0].uint8 <= 0x7f'u8
  for index in 1 ..< value.len:
    if not value[index].validContinuation():
      return false
  let first = value[0].uint8
  if value.len == 3:
    let second = value[1].uint8
    if (first == 0xe0'u8 and second < 0xa0'u8) or
        (first == 0xed'u8 and second >= 0xa0'u8):
      return false
  elif value.len == 4:
    let second = value[1].uint8
    if (first == 0xf0'u8 and second < 0x90'u8) or (
      first == 0xf4'u8 and second > 0x8f'u8
    ):
      return false
  true

proc finishOsc[Cell, Line, Scrollback](
    parser: var TerminexParser, screen: var TerminexScreen[Cell, Line, Scrollback]
) =
  if not parser.discardingOsc:
    screen.processOsc(parser.sequence)
  parser.sequence.setLen(0)
  parser.discardingOsc = false
  parser.state = tpsGround

proc feed*[Cell, Line, Scrollback](
    parser: var TerminexParser,
    screen: var TerminexScreen[Cell, Line, Scrollback],
    data: string,
) =
  var input =
    if parser.incompleteUtf8.len > 0:
      parser.incompleteUtf8 & data
    else:
      data
  parser.incompleteUtf8.setLen(0)
  var index = 0
  while index < input.len:
    let character = input[index]
    case parser.state
    of tpsGround:
      if character == '\x1b':
        parser.state = tpsEscape
      elif character < '\x20' or character == '\x7f':
        screen.processControl(character)
      elif character < '\x80':
        screen.writeText($character)
      else:
        let length = character.utf8Length()
        if length == 0:
          screen.writeText(ReplacementCharacter)
        elif index + length > input.len:
          parser.incompleteUtf8 = input[index ..< input.len]
          return
        else:
          let candidate = input[index ..< index + length]
          if candidate.validUtf8Sequence():
            screen.writeText(candidate)
            inc index, length - 1
          else:
            screen.writeText(ReplacementCharacter)
    of tpsEscape:
      if character == '\x1b' or character == '\x7f':
        discard
      elif character in {'\x18', '\x1a'}:
        parser.state = tpsGround
      elif character < '\x20':
        screen.processControl(character)
      else:
        case character
        of '[':
          parser.sequence.setLen(0)
          parser.state = tpsCsi
        of ']':
          parser.sequence.setLen(0)
          parser.discardingOsc = false
          parser.state = tpsOsc
        of 'P', 'X', '^', '_':
          parser.sequence.setLen(0)
          parser.state = tpsString
        of '\x20' .. '\x2f':
          parser.state = tpsCharset
        else:
          screen.processEscape(character)
          parser.state = tpsGround
    of tpsCsi:
      if character in {'\x40' .. '\x7e'}:
        parser.sequence.add character
        screen.processCsi(parser.sequence)
        parser.sequence.setLen(0)
        parser.state = tpsGround
      elif character in {'\x20' .. '\x3f'}:
        if parser.sequence.len < MaxTerminalCsiBytes:
          parser.sequence.add character
        else:
          parser.sequence.setLen(0)
          parser.state = tpsCsiIgnore
      elif character == '\x1b':
        parser.sequence.setLen(0)
        parser.state = tpsEscape
      elif character in {'\x18', '\x1a'}:
        parser.sequence.setLen(0)
        parser.state = tpsGround
      elif character < '\x20':
        screen.processControl(character)
      elif character != '\x7f':
        parser.sequence.setLen(0)
        parser.state = tpsGround
    of tpsCsiIgnore:
      if character == '\x1b':
        parser.state = tpsEscape
      elif character in {'\x18', '\x1a', '\x40' .. '\x7e'}:
        parser.state = tpsGround
      elif character < '\x20':
        screen.processControl(character)
    of tpsOsc:
      if character == '\x07':
        parser.finishOsc(screen)
      elif character == '\x1b':
        parser.state = tpsOscEscape
      elif character in {'\x18', '\x1a'}:
        parser.sequence.setLen(0)
        parser.discardingOsc = false
        parser.state = tpsGround
      elif not parser.discardingOsc:
        if parser.sequence.len < MaxTerminalStringBytes:
          parser.sequence.add character
        else:
          parser.sequence.setLen(0)
          parser.discardingOsc = true
    of tpsOscEscape:
      if character in {'\\', '\x07'}:
        parser.finishOsc(screen)
      elif character in {'\x18', '\x1a'}:
        parser.sequence.setLen(0)
        parser.discardingOsc = false
        parser.state = tpsGround
      else:
        let extra = if character == '\x1b': 1 else: 2
        if not parser.discardingOsc:
          if parser.sequence.len <= MaxTerminalStringBytes - extra:
            parser.sequence.add '\x1b'
            if character != '\x1b':
              parser.sequence.add character
          else:
            parser.sequence.setLen(0)
            parser.discardingOsc = true
        if character != '\x1b':
          parser.state = tpsOsc
    of tpsString:
      if character == '\x1b':
        parser.state = tpsStringEscape
      elif character in {'\x18', '\x1a'}:
        parser.sequence.setLen(0)
        parser.state = tpsGround
    of tpsStringEscape:
      if character in {'\\', '\x18', '\x1a'}:
        parser.sequence.setLen(0)
        parser.state = tpsGround
      elif character != '\x1b':
        parser.state = tpsString
    of tpsCharset:
      if character == '\x1b':
        parser.state = tpsEscape
      elif character in {'\x18', '\x1a', '\x30' .. '\x7e'}:
        parser.state = tpsGround
      elif character < '\x20':
        screen.processControl(character)
    inc index

proc reset*(parser: var TerminexParser) =
  parser = initTerminalParser()
