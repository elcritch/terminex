import std/[sequtils, unittest]

import terminex

type CustomStorage[Item] = object
  values: seq[Item]

func len[Item](storage: CustomStorage[Item]): int =
  storage.values.len

func `[]`[Item](storage: CustomStorage[Item], index: int): Item =
  storage.values[index]

proc `[]=`[Item](storage: var CustomStorage[Item], index: int, item: Item) =
  storage.values[index] = item

proc add[Item](storage: var CustomStorage[Item], item: Item) =
  storage.values.add(item)

proc setLen[Item](storage: var CustomStorage[Item], length: int) =
  storage.values.setLen(length)

static:
  doAssert CustomStorage[int] is RingBufferStorageAdapter[int]

suite "terminex ring buffer":
  test "capacity is non-negative and bounds retained items":
    var buffer = initRingBuffer[int](-1)

    buffer.add(1)

    check buffer.cap == 0
    check buffer.len == 0
    check toSeq(buffer.items) == newSeq[int]()

  test "logical indexing follows rotation and supports replacement":
    var buffer = initRingBuffer[int](3)
    buffer.add(1)
    buffer.add(2)
    buffer.add(3)
    buffer.add(4)

    check buffer.cap == 3
    check toSeq(buffer.items) == @[2, 3, 4]

    buffer[1] = 9
    check toSeq(buffer.items) == @[2, 9, 4]
    expect IndexDefect:
      discard buffer[-1]
    expect IndexDefect:
      discard buffer[3]

  test "items iterate logically and clear resets rotation":
    var buffer = initRingBuffer[int](2)
    buffer.add(1)
    buffer.add(2)
    buffer.add(3)

    var values: seq[int]
    for item in buffer:
      values.add(item)
    check values == @[2, 3]

    buffer.clear()
    buffer.add(4)
    check buffer.cap == 2
    check toSeq(buffer.items) == @[4]

  test "custom sequence-like storage backs the ring":
    var buffer = initRingBuffer(RingBufferWithStorage[string, CustomStorage[string]], 2)

    buffer.add("a")
    buffer.add("b")
    buffer.add("c")

    check toSeq(buffer.items) == @["b", "c"]
