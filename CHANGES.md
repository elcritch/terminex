# Changes

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
