import Synchronization

/// Single-producer single-consumer ring of s16 samples between the tap thread
/// and the mic writer. The producer never blocks, locks or allocates: when the
/// ring is full the new samples are dropped and counted, and the consumer then
/// drops the backlog up to real time (plans/swift-helper.md section 7).
public final class SampleRing: @unchecked Sendable {
  public let capacity: Int
  private let mask: Int
  private let storage: UnsafeMutablePointer<Int16>
  /// Total samples written and read since creation; only the producer stores
  /// `head`, only the consumer stores `tail`.
  private let head = Atomic<Int>(0)
  private let tail = Atomic<Int>(0)
  private let dropped = Atomic<Int>(0)

  /// `capacity` is rounded up to a power of two.
  public init(capacity: Int) {
    var size = 1
    while size < capacity { size <<= 1 }
    self.capacity = size
    mask = size - 1
    storage = .allocate(capacity: size)
    storage.initialize(repeating: 0, count: size)
  }

  deinit {
    storage.deallocate()
  }

  // MARK: producer

  public func push(_ samples: UnsafeBufferPointer<Int16>) {
    let h = head.load(ordering: .relaxed)
    let t = tail.load(ordering: .acquiring)
    guard h - t + samples.count <= capacity else {
      dropped.add(samples.count, ordering: .relaxed)
      return
    }
    for (i, sample) in samples.enumerated() {
      storage[(h + i) & mask] = sample
    }
    head.store(h + samples.count, ordering: .releasing)
  }

  // MARK: consumer

  /// Position of the producer, for events that must follow the samples
  /// pushed so far.
  public var position: Int { head.load(ordering: .acquiring) }

  public var available: Int {
    head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
  }

  /// Copies exactly `count` samples into `out` if they are available.
  public func pop(into out: UnsafeMutablePointer<Int16>, count: Int) -> Bool {
    let t = tail.load(ordering: .relaxed)
    guard head.load(ordering: .acquiring) - t >= count else { return false }
    for i in 0..<count {
      out[i] = storage[(t + i) & mask]
    }
    tail.store(t + count, ordering: .releasing)
    return true
  }

  /// Drops everything up to `position` (default: everything written so far)
  /// and returns the number of samples dropped.
  @discardableResult
  public func discard(upTo position: Int? = nil) -> Int {
    let t = tail.load(ordering: .relaxed)
    let h = head.load(ordering: .acquiring)
    let target = min(position ?? h, h)
    guard target > t else { return 0 }
    tail.store(target, ordering: .releasing)
    return target - t
  }

  /// After an overrun: drops the backlog up to real time. Returns the samples
  /// lost (dropped by the producer plus the discarded backlog), 0 if none.
  public func takeOverrun() -> Int {
    let lost = dropped.exchange(0, ordering: .relaxed)
    guard lost > 0 else { return 0 }
    return lost + discard()
  }
}
