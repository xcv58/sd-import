import Darwin
import Foundation

/// In-memory identity of a regular file used by a Scan Both plan.
public struct ReviewedFileIdentity: Sendable {
    private let device: Int32
    private let inode: UInt64
    private let size: Int64
    private let modified: (seconds: Int, nanoseconds: Int)
    private let changed: (seconds: Int, nanoseconds: Int)
    private let created: (seconds: Int, nanoseconds: Int)

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
        size = info.st_size
        modified = (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
        changed = (info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec)
        created = (info.st_birthtimespec.tv_sec, info.st_birthtimespec.tv_nsec)
    }

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(info)
    }

    func matches(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && device == info.st_dev && inode == info.st_ino
            && size == info.st_size
            && modified == (info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec)
            && changed == (info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec)
            && created == (info.st_birthtimespec.tv_sec, info.st_birthtimespec.tv_nsec)
    }

    func matches(path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && matches(info)
    }

    public static func matchesSources(
        of plans: [ImportFilePlan], files: [JobFileRecord], scanned: [String: Self]
    ) -> Bool {
        let ids = Set(plans.compactMap { plan -> Int64? in
            if plan.willCopy || plan.disposition == .alreadyExists { return plan.update?.id }
            if case .known = plan.disposition { return plan.update?.id }
            return nil
        })
        let selected = files.filter { file in file.id.map(ids.contains) == true }
        return selected.count == ids.count
            && selected.allSatisfy { scanned[$0.sourcePath]?.matches(path: $0.sourcePath) == true }
    }
}
