## A capacity-bounded ring buffer with pluggable sequence-like storage.

type
  RingBufferStorageAdapter*[StorageItem] =
    concept storage
        mixin len, `[]`, `[]=`, add, setLen
        var writable: typeof(storage)
        storage.len is int
        storage[0] is StorageItem
        writable[0] = storage[0]
        writable.add storage[0]
        writable.setLen(0)

  RingBuffer*[Item; Storage = seq[Item]] = object
    values: Storage
    first: int
    capacity: int

static:
  doAssert seq[int] is RingBufferStorageAdapter[int]

func initRingBuffer*[Item; Storage: RingBufferStorageAdapter[Item]](
    _: typedesc[RingBuffer[Item, Storage]], capacity: int
): RingBuffer[Item, Storage] =
  ## Initialize an empty ring buffer with a fixed non-negative capacity.
  result.capacity = max(capacity, 0)

func initRingBuffer*[Item](capacity: int): RingBuffer[Item, seq[Item]] =
  ## Initialize a sequence-backed ring buffer.
  initRingBuffer(RingBuffer[Item, seq[Item]], capacity)

func len*[Item, Storage](buffer: RingBuffer[Item, Storage]): int =
  mixin len
  buffer.values.len

func cap*[Item, Storage](buffer: RingBuffer[Item, Storage]): int =
  buffer.capacity

func physicalIndex[Item, Storage](buffer: RingBuffer[Item, Storage], index: int): int =
  if index < 0 or index >= buffer.len:
    raise newException(IndexDefect, "ring buffer index out of bounds")
  (buffer.first + index) mod buffer.len

func `[]`*[Item, Storage](buffer: RingBuffer[Item, Storage], index: int): Item =
  mixin `[]`
  buffer.values[buffer.physicalIndex(index)]

proc `[]=`*[Item, Storage](
    buffer: var RingBuffer[Item, Storage], index: int, item: sink Item
) =
  mixin `[]=`
  buffer.values[buffer.physicalIndex(index)] = move(item)

proc add*[Item, Storage](buffer: var RingBuffer[Item, Storage], item: sink Item) =
  mixin len, `[]=`, add
  if buffer.capacity == 0:
    return
  if buffer.values.len < buffer.capacity:
    buffer.values.add(item)
  else:
    buffer.values[buffer.first] = move(item)
    buffer.first = (buffer.first + 1) mod buffer.values.len

proc clear*[Item, Storage](buffer: var RingBuffer[Item, Storage]) =
  mixin setLen
  buffer.values.setLen(0)
  buffer.first = 0

iterator items*[Item, Storage](buffer: RingBuffer[Item, Storage]): Item =
  for index in 0 ..< buffer.len:
    yield buffer[index]
