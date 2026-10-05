import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Advisory OS lock shared by all instances of the store, released even if the
/// process exits. A stale lock file is harmless; ownership is never inferred by age.
final class DoorInstallLease {
    private let descriptor: Int32
    init(directory: URL) throws {
        let path = directory.appendingPathComponent(".install.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw DoorOfflineError.unsafePath }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw DoorOfflineError.writerBusy
        }
        descriptor = fd
    }
    deinit { _ = flock(descriptor, LOCK_UN); close(descriptor) }
}
