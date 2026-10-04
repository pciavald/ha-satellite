import Darwin
import Foundation

public enum SocketError: Error, CustomStringConvertible {
  case pathTooLong(String)
  case system(String, Int32)

  public var description: String {
    switch self {
    case .pathTooLong(let path): return "socket path too long: \(path)"
    case .system(let call, let code): return "\(call): \(String(cString: strerror(code)))"
    }
  }
}

func makeAddress(_ path: String) throws -> sockaddr_un {
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  let bytes = Array(path.utf8)
  let capacity = MemoryLayout.size(ofValue: address.sun_path)
  guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
  withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: bytes)
    raw[bytes.count] = 0
  }
  address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  return address
}

/// One accepted (or, in tests, connected) Unix stream socket with framing.
/// Sends are serialized by a lock; reads belong to one thread.
public final class Connection: @unchecked Sendable {
  public let fd: Int32
  private let sendLock = NSLock()
  private var parser = FrameParser()
  private var closed = false
  private let stateLock = NSLock()

  public init(fd: Int32) {
    self.fd = fd
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
  }

  deinit {
    Darwin.close(fd)
  }

  /// Connects to a server socket (tests and tools).
  public static func connect(path: String) throws -> Connection {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system("socket", errno) }
    var address = try makeAddress(path)
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard status == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError.system("connect", code)
    }
    return Connection(fd: fd)
  }

  public var isClosed: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return closed
  }

  /// Wakes the reader and fails further sends; the descriptor is released
  /// with the object.
  public func close() {
    stateLock.lock()
    let wasClosed = closed
    closed = true
    stateLock.unlock()
    if !wasClosed { shutdown(fd, SHUT_RDWR) }
  }

  @discardableResult
  public func send(_ frame: Frame) -> Bool {
    let data = Wire.encode(frame)
    sendLock.lock()
    defer { sendLock.unlock() }
    if isClosed { return false }
    let ok = data.withUnsafeBytes { raw -> Bool in
      var offset = 0
      while offset < raw.count {
        let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
        if n < 0 {
          if errno == EINTR { continue }
          return false
        }
        offset += n
      }
      return true
    }
    if !ok { close() }
    return ok
  }

  /// Blocks until a frame arrives. Returns nil on a clean end of stream or
  /// after `close()`; throws on a protocol error or after `timeout` seconds
  /// without a complete frame (when given).
  public func read(timeout: TimeInterval? = nil) throws -> Frame? {
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var chunk = [UInt8](repeating: 0, count: 16384)
    while true {
      if let frame = try parser.next() { return frame }
      if isClosed { return nil }
      var waitMs: Int32 = 1000
      if let deadline {
        let left = deadline.timeIntervalSinceNow
        if left <= 0 { throw ProtocolError.badPayload("timed out waiting for a frame") }
        waitMs = Int32(min(1000, max(1, left * 1000)))
      }
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, 1, waitMs)
      if ready < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if ready == 0 { continue }
      let n = recv(fd, &chunk, chunk.count, 0)
      if n < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        return nil
      }
      if n == 0 {
        try parser.finish()
        return nil
      }
      parser.append(Data(chunk[0..<n]))
    }
  }

  /// uid of the peer process.
  public var peerUID: uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
  }
}

/// Unix socket server: directory 0700, socket 0600, one thread per
/// connection, peers of another uid refused.
public final class SocketServer: @unchecked Sendable {
  public let path: String
  private let accept: (Connection) -> Void
  private var listenFD: Int32 = -1
  private var running = false
  private let lock = NSLock()

  /// `accept` runs on a new thread per connection and owns it.
  public init(path: String, accept: @escaping (Connection) -> Void) {
    self.path = path
    self.accept = accept
  }

  public func start() throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    chmod(dir, 0o700)
    var address = try makeAddress(path)
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system("socket", errno) }
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError.system("bind", code)
    }
    chmod(path, 0o600)
    guard listen(fd, 8) == 0 else {
      let code = errno
      Darwin.close(fd)
      throw SocketError.system("listen", code)
    }
    lock.lock()
    listenFD = fd
    running = true
    lock.unlock()
    let thread = Thread { [weak self] in self?.acceptLoop(fd) }
    thread.name = "socket-accept"
    thread.start()
  }

  public func stop() {
    lock.lock()
    let fd = listenFD
    running = false
    listenFD = -1
    lock.unlock()
    if fd >= 0 {
      shutdown(fd, SHUT_RDWR)
      Darwin.close(fd)
      unlink(path)
    }
  }

  private var isRunning: Bool {
    lock.lock()
    defer { lock.unlock() }
    return running
  }

  private func acceptLoop(_ fd: Int32) {
    let me = getuid()
    while isRunning {
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      let ready = poll(&pfd, 1, 500)
      if ready <= 0 { continue }
      let client = Darwin.accept(fd, nil, nil)
      if client < 0 {
        if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
        if !isRunning { return }
        continue
      }
      let connection = Connection(fd: client)
      guard connection.peerUID == me else {
        connection.close()
        continue
      }
      let thread = Thread { [accept] in accept(connection) }
      thread.name = "socket-connection"
      thread.start()
    }
  }
}
