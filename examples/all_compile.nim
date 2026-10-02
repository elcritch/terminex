## Compile-only examples of the independent synchronous and Sigils APIs.
import ./snapshots
when defined(features.terminex.sigils) or defined(feature.terminex.sigils):
  import ./threaded
