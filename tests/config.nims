--path:"../src"

when defined(terminexSanitizers):
  switch("debugger", "native")
  switch("define", "noSignalHandler")
  switch("define", "useMalloc")
  switch("passC", "-fsanitize=address,undefined -fno-omit-frame-pointer")
  switch("passL", "-fsanitize=address,undefined")
