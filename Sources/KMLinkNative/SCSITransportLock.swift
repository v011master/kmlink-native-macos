import Darwin
import Foundation

final class SCSITransportLock {
    private var fileDescriptor: Int32 = -1

    deinit {
        release()
    }

    func acquire() -> Bool {
        if fileDescriptor >= 0 {
            return true
        }

        let path = "/tmp/org.kmlinknative.scsi.lock"
        let fd = path.withCString { pointer in
            Darwin.open(pointer, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH)
        }
        guard fd >= 0 else {
            return false
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            fileDescriptor = fd
            return true
        }

        Darwin.close(fd)
        return false
    }

    func release() {
        guard fileDescriptor >= 0 else {
            return
        }

        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
        fileDescriptor = -1
    }
}
