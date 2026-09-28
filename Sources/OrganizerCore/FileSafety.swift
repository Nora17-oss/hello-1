import Foundation
import CryptoKit
import Darwin

public enum FileSafety {
    public static func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw OrganizerError.unsafe("项目不存在或无法读取：\(url.lastPathComponent)")
        }
        return value
    }
    public static func identity(_ value: stat) -> String {
        "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)"
    }
    public static func exists(_ url: URL) -> Bool { (try? metadata(url)) != nil }
    public static func isLink(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFLNK }
    public static func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.standardizedFileURL.path
        let c = child.standardizedFileURL.path
        return c == p || c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }
    public static func availability(_ url: URL) -> String? {
        if ["download", "crdownload", "part", "partial", "tmp"].contains(url.pathExtension.lowercased()) {
            return "下载或写入中的临时文件"
        }
        guard let m = try? metadata(url) else { return "文件不可读取" }
        if isLink(m) { return "第一版不移动符号链接" }
        if !isDirectory(m), m.st_mode & S_IFMT != S_IFREG { return "不支持的文件类型" }
        let resource = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .ubiquitousItemIsDownloadingKey])
        if resource?.ubiquitousItemIsDownloading == true { return "iCloud 正在下载文件" }
        if resource?.isUbiquitousItem == true,
           resource?.ubiquitousItemDownloadingStatus == .notDownloaded { return "尚未下载到本机" }
        return nil
    }

    public static func stamp(_ url: URL) throws -> FileStamp {
        if let issue = availability(url) { throw OrganizerError.unsafe(issue) }
        let root = try metadata(url)
        var hasher = SHA256()
        var count = 0
        func visit(_ node: URL, relative: String) throws {
            try Task.checkCancellation()
            count += 1
            guard count <= 20000 else { throw OrganizerError.unsafe("文件夹超过两万项，请分批归档") }
            let before = try metadata(node)
            let key = "\(relative)|\(identity(before))|\(before.st_mode)|\(before.st_size)|\(before.st_mtimespec.tv_sec):\(before.st_mtimespec.tv_nsec)"
            hasher.update(data: Data(key.utf8))
            if isLink(before) {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: node.path)
                hasher.update(data: Data(target.utf8))
            } else if isDirectory(before) {
                for child in try FileManager.default.contentsOfDirectory(at: node, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else if before.st_mode & S_IFMT == S_IFREG {
                if let issue = availability(node) { throw OrganizerError.unsafe(issue) }
                let fd = Darwin.open(node.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw OrganizerError.unsafe("无法读取文件内容") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                defer { try? handle.close() }
                var bytesRead: Int64 = 0
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    bytesRead += Int64(data.count)
                    guard bytesRead <= before.st_size else { throw OrganizerError.unsafe("文件仍在增长，请稍后再试") }
                    hasher.update(data: data)
                }
            } else {
                throw OrganizerError.unsafe("文件夹包含不支持的特殊文件")
            }
            let after = try metadata(node)
            guard identity(before) == identity(after), before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
                throw OrganizerError.unsafe("文件正在变化，请稍后再试")
            }
        }
        try visit(url, relative: "")
        return FileStamp(identity: identity(root), signature: hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    public static func validateDestination(source: URL, destination: URL, project: URL) throws {
        guard contains(project, destination), destination != project else {
            throw OrganizerError.unsafe("目标必须位于选中的项目内")
        }
        let sourceMeta = try metadata(source)
        let projectMeta = try metadata(project)
        guard isDirectory(projectMeta), !isLink(projectMeta) else {
            throw OrganizerError.unsafe("项目目录不可用或是符号链接")
        }
        guard sourceMeta.st_dev == projectMeta.st_dev else {
            throw OrganizerError.unsafe("第一版仅支持同一磁盘卷内移动")
        }
        let resolvedSource = source.resolvingSymlinksInPath()
        guard !contains(resolvedSource, destination.resolvingSymlinksInPath()) else {
            throw OrganizerError.unsafe("不能将文件夹移入自身")
        }
        var current = project
        let relative = destination.deletingLastPathComponent().standardizedFileURL.pathComponents
            .dropFirst(project.standardizedFileURL.pathComponents.count)
        for component in relative {
            current.appendPathComponent(component)
            if exists(current) {
                let m = try metadata(current)
                guard isDirectory(m), !isLink(m), m.st_dev == sourceMeta.st_dev else {
                    throw OrganizerError.unsafe("目标路径包含链接、非文件夹或其他磁盘卷")
                }
            }
        }
        var existingParent = destination.deletingLastPathComponent()
        while !exists(existingParent) { existingParent.deleteLastPathComponent() }
        guard FileManager.default.isWritableFile(atPath: existingParent.path),
              FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path) else {
            throw OrganizerError.unsafe("没有源目录或目标目录的写入权限")
        }
    }

    public static func move(source: URL, destination: URL, project: URL, expected: FileStamp) throws {
        try validateDestination(source: source, destination: destination, project: project)
        guard try stamp(source) == expected else { throw OrganizerError.unsafe("预检后文件发生变化，请重新预检") }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try validateDestination(source: source, destination: destination, project: project)
        // RENAME_EXCL is atomic, does not replace a racing destination and never copies across volumes.
        let result = source.withUnsafeFileSystemRepresentation { src in
            destination.withUnsafeFileSystemRepresentation { dst in
                renameatx_np(AT_FDCWD, src!, AT_FDCWD, dst!, UInt32(RENAME_EXCL))
            }
        }
        guard result == 0 else {
            let code = errno
            throw OrganizerError.unsafe(code == EEXIST ? "目标已出现同名项，未覆盖" : "移动失败：\(String(cString: strerror(code)))")
        }
    }

    public static func availableName(_ original: URL, reserved: Set<String>) -> URL {
        if !exists(original), !reserved.contains(original.path) { return original }
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        for number in 2...10000 {
            let name = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = original.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(candidate), !reserved.contains(candidate.path) { return candidate }
        }
        return original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-" + original.lastPathComponent)
    }
}
