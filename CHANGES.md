# Changes

## 0.4.1

- Keep unsupported private CSI keyboard controls separate from text styling and
  cursor commands. Keyboard capability queries no longer restore the saved
  cursor, and modifier controls no longer leave terminal rows underlined or dim.
- Ignore unsupported CSI intermediate forms and mouse highlight tracking rather
  than treating them as text deletion, scrolling, or margin changes.
- Reject overflowing numeric CSI/OSC selectors, clamp cursor and erase operands
  before arithmetic, and cap one REP command at 65,535 copies.
- Preserve colon SGR subparameter groups for RGB/indexed colors and underline
  styles, without turning color components into unrelated attributes.
- Keep ignored and oversized escape-string payloads off the screen, consume ESC
  intermediate sequences, and restart correctly after repeated ESC bytes.
- Preserve the active row for horizontal cursor addressing in origin mode.
  Restore rendition and pending wrap when leaving the alternate screen, and keep
  unrelated input modes and cursor appearance when restoring a saved cursor.

## 0.4.0

- Add optional Sigils terminal sessions with exclusive worker ownership, ordered
  commands, and bounded RChan snapshots. One shared readiness dispatcher handles
  multiple sessions without parser locks on the consuming thread. Parsing
  continues while consumers are busy; history deltas and final output survive
  skipped snapshots.
- Add scheduler-independent owned screen snapshots and cumulative screen updates
  for ordinary and compact sessions. Core parsing, transport, and snapshots remain
  usable without Sigils or threads.
- Expose owned POSIX readiness descriptors without exposing private session
  fields. Add explicit dispatcher shutdown and automatic lifetime guards.
- Move reusable session management out of Merenda. GUI rendering, clipboard
  policy, viewport positioning, and native event-loop integration stay in the host.
