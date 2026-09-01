import std/unittest

import terminex

suite "terminex":
  test "greets by name":
    check greet("Nim") == "hello, Nim"

