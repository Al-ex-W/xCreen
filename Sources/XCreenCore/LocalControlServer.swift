import Foundation
import Darwin

/// Same-user private IPC. The lifetime lock is acquired before AppState is created.
public final class LocalControlServer: @unchecked Sendable {
    public static var defaultDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".xcreen-control") }
    private var listener: Int32 = -1
    private var lock: Int32 = -1
    private let directory: URL
    private let queue = DispatchQueue(label: "xcreen.control.accept")
    private let slots = DispatchSemaphore(value: 8)
    private let handler: @Sendable (LocalControlCommand) async throws -> LocalControlResponse
    public init(directory: URL = LocalControlServer.defaultDirectory, handler: @escaping @Sendable (LocalControlCommand) async throws -> LocalControlResponse) throws {
        self.directory = directory; self.handler = handler
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw LocalControlError.unavailable("cannot create control directory") }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else { throw LocalControlError.unavailable("unsafe control directory") }
        lock = open(directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw LocalControlError.unavailable("cannot open instance lock") }
        guard fstat(lock, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600, flock(lock, LOCK_EX | LOCK_NB) == 0 else { close(lock); lock = -1; throw LocalControlError.unavailable("another instance or unsafe lock") }
        let path = directory.appendingPathComponent("control.sock").path
        if lstat(path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { stop(); throw LocalControlError.unavailable("unsafe existing endpoint") }
            unlink(path)
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { stop(); throw LocalControlError.unavailable("control path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else { stop(); throw LocalControlError.unavailable("cannot bind control endpoint") }
        let fd = listener
        queue.async { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                guard self.slots.wait(timeout: .now()) == .success else { close(client); continue }
                DispatchQueue.global(qos: .utility).async { [self] in defer { self.slots.signal(); close(client) }; self.serve(client) }
            }
        }
    }
    deinit { stop() }
    public func stop() {
        if listener >= 0 { shutdown(listener, SHUT_RDWR); close(listener); listener = -1; unlink(directory.appendingPathComponent("control.sock").path) }
        if lock >= 0 { flock(lock, LOCK_UN); close(lock); lock = -1 }
    }
    private func serve(_ fd: Int32) {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var frame = Data(); var byte: UInt8 = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while frame.count <= LocalControlProtocol.maximumFrameBytes {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { return }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) >= 0 else { return }
            if p.revents == 0 { continue }
            guard read(fd, &byte, 1) == 1 else { return }
            if byte == 10 { break }; frame.append(byte)
        }
        do {
            let command = try LocalControlCommand.decode(frame)
            let box = ResponseBox(); let done = DispatchSemaphore(value: 0)
            let task = Task { [handler] in
                do { box.set(try await handler(command)) } catch { box.set(.failure(error)) }
                done.signal()
            }
            let completed = done.wait(timeout: .now() + 35) == .success
            if !completed { task.cancel() }
            send(completed ? box.get() : .failure(LocalControlError.unavailable("command deadline exceeded; inspect live status")), fd)
        } catch { send(.failure(error), fd) }
    }
    private func send(_ response: LocalControlResponse, _ fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        if data.count > 1_048_576 { data = (try? JSONEncoder().encode(LocalControlResponse.failure(LocalControlError.failed("response exceeds local limit")))) ?? Data() }
        data.append(10)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count { let n = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset); if n <= 0 { break }; offset += n }
        }
    }
}
private final class ResponseBox: @unchecked Sendable {
    private let lock = NSLock(); private var value = LocalControlResponse.failure(LocalControlError.unavailable("no response"))
    func set(_ value: LocalControlResponse) { lock.lock(); self.value = value; lock.unlock() }
    func get() -> LocalControlResponse { lock.lock(); defer { lock.unlock() }; return value }
}
