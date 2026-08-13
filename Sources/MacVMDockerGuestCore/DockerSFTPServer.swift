import Darwin
import Foundation

public struct DockerSFTPServerLimits: Equatable, Sendable {
    public var maximumPacketBytes: Int
    public var maximumReadBytes: Int
    public var maximumHandles: Int
    public var maximumDirectoryEntries: Int

    public init(
        maximumPacketBytes: Int = 1_048_576,
        maximumReadBytes: Int = 262_144,
        maximumHandles: Int = 256,
        maximumDirectoryEntries: Int = 10_000
    ) {
        self.maximumPacketBytes = maximumPacketBytes
        self.maximumReadBytes = maximumReadBytes
        self.maximumHandles = maximumHandles
        self.maximumDirectoryEntries = maximumDirectoryEntries
    }
}

public struct DockerSFTPFileAttributes: Equatable, Sendable {
    public var size: UInt64
    public var uid: UInt32
    public var gid: UInt32
    public var permissions: UInt32
    public var accessTime: UInt32
    public var modificationTime: UInt32

    init(metadata: stat) {
        size = UInt64(max(0, metadata.st_size))
        uid = metadata.st_uid
        gid = metadata.st_gid
        permissions = UInt32(metadata.st_mode)
        accessTime = UInt32(clamping: metadata.st_atimespec.tv_sec)
        modificationTime = UInt32(clamping: metadata.st_mtimespec.tv_sec)
    }
}

public final class DockerDescriptorRoot: @unchecked Sendable {
    private let rootPath: String
    private let rootDevice: dev_t
    private let rootInode: ino_t
    private let regularFileName: String?

    public init(capability: DockerExportCapability) throws {
        try capability.validate()
        let path: String
        switch capability.kind {
        case .directory:
            path = capability.sourcePath
            regularFileName = nil
        case .regularFile:
            let url = URL(fileURLWithPath: capability.sourcePath)
            path = url.deletingLastPathComponent().path
            regularFileName = url.lastPathComponent
        }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerSFTPStatusError.currentErrno() }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw DockerSFTPStatusError.currentErrno() }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw DockerSFTPStatusError.currentErrno(ENOTDIR)
        }
        rootPath = path
        rootDevice = metadata.st_dev
        rootInode = metadata.st_ino
    }

    public func normalizedComponents(for path: String) throws -> [String] {
        guard path.utf8.count <= 4_096, !path.contains("\0") else {
            throw DockerSFTPStatusError(code: .badMessage, message: "Invalid path.")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty }) else {
            throw DockerSFTPStatusError(code: .permissionDenied, message: "Path escapes the export.")
        }
        if let regularFileName {
            guard components.isEmpty || components == ["source"] else {
                throw DockerSFTPStatusError(code: .permissionDenied, message: "Path is outside the file export.")
            }
            return components.isEmpty ? [] : [regularFileName]
        }
        return components
    }

    func openFile(path: String, flags: Int32, mode: mode_t = 0o666) throws -> Int32 {
        let components = try normalizedComponents(for: path)
        guard !components.isEmpty else {
            throw DockerSFTPStatusError(code: .failure, message: "The export root is a directory.")
        }
        let (parent, name) = try openParent(of: components)
        defer { close(parent) }
        let result = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard result >= 0 else { throw DockerSFTPStatusError.currentErrno() }
        return result
    }

    func openDirectory(path: String) throws -> Int32 {
        let components = try normalizedComponents(for: path)
        return try openDirectory(components: components)
    }

    func metadata(path: String) throws -> DockerSFTPFileAttributes {
        let components = try normalizedComponents(for: path)
        var value = stat()
        if components.isEmpty {
            let root = try openRoot()
            defer { close(root) }
            guard fstat(root, &value) == 0 else { throw DockerSFTPStatusError.currentErrno() }
        } else {
            let (parent, name) = try openParent(of: components)
            defer { close(parent) }
            guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DockerSFTPStatusError.currentErrno()
            }
        }
        return DockerSFTPFileAttributes(metadata: value)
    }

    fileprivate func setAttributes(path: String, attributes: DockerSFTPDecodedAttributes) throws {
        let file = try openFile(path: path, flags: O_RDWR)
        defer { close(file) }
        try Self.apply(attributes: attributes, to: file)
    }

    func remove(path: String, directory: Bool) throws {
        let components = try normalizedComponents(for: path)
        guard !components.isEmpty else { throw DockerSFTPStatusError(code: .permissionDenied, message: "Cannot remove export root.") }
        let (parent, name) = try openParent(of: components)
        defer { close(parent) }
        guard unlinkat(parent, name, directory ? AT_REMOVEDIR : 0) == 0 else {
            throw DockerSFTPStatusError.currentErrno()
        }
    }

    func createDirectory(path: String, mode: mode_t) throws {
        let components = try normalizedComponents(for: path)
        guard !components.isEmpty else { throw DockerSFTPStatusError(code: .failure, message: "Export root exists.") }
        let (parent, name) = try openParent(of: components)
        defer { close(parent) }
        guard mkdirat(parent, name, mode) == 0 else { throw DockerSFTPStatusError.currentErrno() }
    }

    func rename(from source: String, to destination: String) throws {
        let sourceComponents = try normalizedComponents(for: source)
        let destinationComponents = try normalizedComponents(for: destination)
        guard !sourceComponents.isEmpty, !destinationComponents.isEmpty else {
            throw DockerSFTPStatusError(code: .permissionDenied, message: "Cannot rename export root.")
        }
        let (sourceParent, sourceName) = try openParent(of: sourceComponents)
        defer { close(sourceParent) }
        let (destinationParent, destinationName) = try openParent(of: destinationComponents)
        defer { close(destinationParent) }
        guard renameat(sourceParent, sourceName, destinationParent, destinationName) == 0 else {
            throw DockerSFTPStatusError.currentErrno()
        }
    }

    func directoryEntries(path: String, limit: Int) throws -> [(String, DockerSFTPFileAttributes)] {
        let components = try normalizedComponents(for: path)
        if let regularFileName {
            guard components.isEmpty else { throw DockerSFTPStatusError.currentErrno(ENOTDIR) }
            let root = try openRoot()
            defer { close(root) }
            var metadata = stat()
            guard fstatat(root, regularFileName, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw DockerSFTPStatusError.currentErrno()
            }
            return [("source", DockerSFTPFileAttributes(metadata: metadata))]
        }
        let fd = try openDirectory(components: components)
        guard let directory = fdopendir(fd) else {
            close(fd)
            throw DockerSFTPStatusError.currentErrno()
        }
        defer { closedir(directory) }
        var result: [(String, DockerSFTPFileAttributes)] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard result.count < limit else {
                throw DockerSFTPStatusError(code: .failure, message: "Directory has too many entries.")
            }
            var metadata = stat()
            guard fstatat(dirfd(directory), name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            result.append((name, DockerSFTPFileAttributes(metadata: metadata)))
        }
        return result
    }

    private func openDirectory(components: [String]) throws -> Int32 {
        var current = try openRoot()
        do {
            for component in components {
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw DockerSFTPStatusError.currentErrno() }
                close(current)
                current = next
            }
            return current
        } catch {
            close(current)
            throw error
        }
    }

    private func openParent(of components: [String]) throws -> (Int32, String) {
        guard let name = components.last else {
            throw DockerSFTPStatusError(code: .failure, message: "Missing path.")
        }
        return (try openDirectory(components: Array(components.dropLast())), name)
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockerSFTPStatusError.currentErrno() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            let error = DockerSFTPStatusError.currentErrno()
            close(descriptor)
            throw error
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_dev == rootDevice,
              metadata.st_ino == rootInode else {
            close(descriptor)
            throw DockerSFTPStatusError(
                code: .permissionDenied,
                message: "The export root changed during the SFTP session."
            )
        }
        return descriptor
    }

    fileprivate static func apply(attributes: DockerSFTPDecodedAttributes, to descriptor: Int32) throws {
        if let size = attributes.size {
            guard size <= UInt64(Int64.max), ftruncate(descriptor, off_t(size)) == 0 else {
                throw DockerSFTPStatusError.currentErrno()
            }
        }
        if let permissions = attributes.permissions,
           fchmod(descriptor, mode_t(permissions & 0o7777)) != 0 {
            throw DockerSFTPStatusError.currentErrno()
        }
        if let uid = attributes.uid, let gid = attributes.gid,
           fchown(descriptor, uid, gid) != 0 {
            throw DockerSFTPStatusError.currentErrno()
        }
        if let accessTime = attributes.accessTime, let modificationTime = attributes.modificationTime {
            var times = [
                timespec(tv_sec: Int(accessTime), tv_nsec: 0),
                timespec(tv_sec: Int(modificationTime), tv_nsec: 0),
            ]
            guard futimens(descriptor, &times) == 0 else { throw DockerSFTPStatusError.currentErrno() }
        }
    }
}

public final class DockerSFTPServer {
    private enum Message: UInt8 {
        case initialize = 1, version = 2, open = 3, close = 4, read = 5, write = 6
        case lstat = 7, fstat = 8, setstat = 9, fsetstat = 10, opendir = 11
        case readdir = 12, remove = 13, mkdir = 14, rmdir = 15, realpath = 16
        case stat = 17, rename = 18, readlink = 19, symlink = 20
        case status = 101, handle = 102, data = 103, name = 104, attrs = 105
        case extended = 200
    }

    private final class FileHandleState {
        let descriptor: Int32
        init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { Darwin.close(descriptor) }
    }

    private final class DirectoryHandleState {
        let entries: [(String, DockerSFTPFileAttributes)]
        var offset = 0
        init(entries: [(String, DockerSFTPFileAttributes)]) { self.entries = entries }
    }

    private enum HandleState {
        case file(FileHandleState)
        case directory(DirectoryHandleState)
    }

    private let input: FileHandle
    private let output: FileHandle
    private let root: DockerDescriptorRoot
    private let limits: DockerSFTPServerLimits
    private var handles: [Data: HandleState] = [:]
    private var nextHandle: UInt64 = 1

    public init(
        capability: DockerExportCapability,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput,
        limits: DockerSFTPServerLimits = DockerSFTPServerLimits()
    ) throws {
        guard limits.maximumPacketBytes >= 64,
              limits.maximumReadBytes > 0,
              limits.maximumReadBytes <= limits.maximumPacketBytes,
              limits.maximumHandles > 0,
              limits.maximumDirectoryEntries > 0 else {
            throw DockerGuestCoreError("Invalid SFTP server limits.")
        }
        self.input = input
        self.output = output
        self.root = try DockerDescriptorRoot(capability: capability)
        self.limits = limits
    }

    public func run() throws {
        while let packet = try readPacket() {
            do {
                try dispatch(packet)
            } catch let error as DockerSFTPStatusError {
                if let requestID = packet.requestID {
                    try sendStatus(requestID: requestID, error: error)
                } else {
                    throw error
                }
            } catch {
                if let requestID = packet.requestID {
                    try sendStatus(requestID: requestID, error: DockerSFTPStatusError(code: .failure, message: "SFTP request failed."))
                } else {
                    throw error
                }
            }
        }
    }

    private func dispatch(_ data: Data) throws {
        var reader = DockerSFTPPacketReader(data)
        guard let type = Message(rawValue: try reader.uint8()) else {
            throw DockerSFTPStatusError(code: .opUnsupported, message: "Unsupported SFTP message.")
        }
        if type == .initialize {
            let version = try reader.uint32()
            guard version >= 3 else { throw DockerSFTPStatusError(code: .badMessage, message: "SFTP v3 is required.") }
            var response = DockerSFTPPacketWriter(type: Message.version.rawValue)
            response.uint32(3)
            try writePacket(response.data)
            return
        }
        let requestID = try reader.uint32()
        switch type {
        case .open:
            try open(requestID: requestID, reader: &reader)
        case .close:
            let handle = try reader.dataString(maximumBytes: 64)
            guard handles.removeValue(forKey: handle) != nil else { throw invalidHandle() }
            try sendStatus(requestID: requestID, error: .ok)
        case .read:
            try read(requestID: requestID, reader: &reader)
        case .write:
            try write(requestID: requestID, reader: &reader)
        case .lstat, .stat:
            let path = try reader.path()
            try sendAttributes(requestID: requestID, attributes: root.metadata(path: path))
        case .fstat:
            try fileAttributes(requestID: requestID, reader: &reader)
        case .setstat:
            let path = try reader.path()
            let attributes = try reader.attributes()
            try root.setAttributes(path: path, attributes: attributes)
            try sendStatus(requestID: requestID, error: .ok)
        case .fsetstat:
            let handle = try reader.dataString(maximumBytes: 64)
            let attributes = try reader.attributes()
            guard case .file(let state) = handles[handle] else { throw invalidHandle() }
            try DockerDescriptorRoot.apply(attributes: attributes, to: state.descriptor)
            try sendStatus(requestID: requestID, error: .ok)
        case .opendir:
            try openDirectory(requestID: requestID, reader: &reader)
        case .readdir:
            try readDirectory(requestID: requestID, reader: &reader)
        case .remove:
            try root.remove(path: reader.path(), directory: false)
            try sendStatus(requestID: requestID, error: .ok)
        case .mkdir:
            let path = try reader.path()
            let attributes = try reader.attributes()
            try root.createDirectory(path: path, mode: mode_t(attributes.permissions ?? 0o755))
            try sendStatus(requestID: requestID, error: .ok)
        case .rmdir:
            try root.remove(path: reader.path(), directory: true)
            try sendStatus(requestID: requestID, error: .ok)
        case .realpath:
            let path = try reader.path()
            let components = try root.normalizedComponents(for: path)
            let canonical = "/" + (components.isEmpty ? "" : path.split(separator: "/").filter { $0 != "." }.joined(separator: "/"))
            try sendNames(requestID: requestID, entries: [(canonical, root.metadata(path: path))])
        case .rename:
            try root.rename(from: reader.path(), to: reader.path())
            try sendStatus(requestID: requestID, error: .ok)
        case .readlink, .symlink, .extended:
            throw DockerSFTPStatusError(code: .opUnsupported, message: "Operation is not supported by the bounded export server.")
        default:
            throw DockerSFTPStatusError(code: .opUnsupported, message: "Unsupported SFTP message.")
        }
    }

    private func open(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        guard handles.count < limits.maximumHandles else {
            throw DockerSFTPStatusError(code: .failure, message: "Too many open SFTP handles.")
        }
        let path = try reader.path()
        let pflags = try reader.uint32()
        let attributes = try reader.attributes()
        let access: Int32
        switch (pflags & 0x1 != 0, pflags & 0x2 != 0) {
        case (true, true): access = O_RDWR
        case (false, true): access = O_WRONLY
        default: access = O_RDONLY
        }
        var flags = access
        if pflags & 0x4 != 0 { flags |= O_APPEND }
        if pflags & 0x8 != 0 { flags |= O_CREAT }
        if pflags & 0x10 != 0 { flags |= O_TRUNC }
        if pflags & 0x20 != 0 { flags |= O_EXCL }
        let descriptor = try root.openFile(
            path: path,
            flags: flags,
            mode: mode_t(attributes.permissions ?? 0o666)
        )
        let handle = makeHandle()
        handles[handle] = .file(FileHandleState(descriptor))
        try sendHandle(requestID: requestID, handle: handle)
    }

    private func read(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        let handle = try reader.dataString(maximumBytes: 64)
        let offset = try reader.uint64()
        let requested = Int(try reader.uint32())
        guard requested <= limits.maximumReadBytes, offset <= UInt64(Int64.max) else {
            throw DockerSFTPStatusError(code: .badMessage, message: "SFTP read exceeds the protocol limit.")
        }
        guard case .file(let state) = handles[handle] else { throw invalidHandle() }
        var bytes = [UInt8](repeating: 0, count: requested)
        let count = pread(state.descriptor, &bytes, requested, off_t(offset))
        guard count >= 0 else { throw DockerSFTPStatusError.currentErrno() }
        guard count > 0 else { throw DockerSFTPStatusError(code: .eof, message: "End of file.") }
        var response = DockerSFTPPacketWriter(type: Message.data.rawValue, requestID: requestID)
        response.dataString(Data(bytes.prefix(count)))
        try writePacket(response.data)
    }

    private func write(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        let handle = try reader.dataString(maximumBytes: 64)
        let offset = try reader.uint64()
        let data = try reader.dataString(maximumBytes: limits.maximumReadBytes)
        guard offset <= UInt64(Int64.max), case .file(let state) = handles[handle] else { throw invalidHandle() }
        let count = data.withUnsafeBytes { bytes in
            pwrite(state.descriptor, bytes.baseAddress, data.count, off_t(offset))
        }
        guard count == data.count else { throw DockerSFTPStatusError.currentErrno() }
        try sendStatus(requestID: requestID, error: .ok)
    }

    private func fileAttributes(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        let handle = try reader.dataString(maximumBytes: 64)
        guard case .file(let state) = handles[handle] else { throw invalidHandle() }
        var metadata = stat()
        guard fstat(state.descriptor, &metadata) == 0 else { throw DockerSFTPStatusError.currentErrno() }
        try sendAttributes(requestID: requestID, attributes: DockerSFTPFileAttributes(metadata: metadata))
    }

    private func openDirectory(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        guard handles.count < limits.maximumHandles else {
            throw DockerSFTPStatusError(code: .failure, message: "Too many open SFTP handles.")
        }
        let entries = try root.directoryEntries(path: reader.path(), limit: limits.maximumDirectoryEntries)
        let handle = makeHandle()
        handles[handle] = .directory(DirectoryHandleState(entries: entries))
        try sendHandle(requestID: requestID, handle: handle)
    }

    private func readDirectory(requestID: UInt32, reader: inout DockerSFTPPacketReader) throws {
        let handle = try reader.dataString(maximumBytes: 64)
        guard case .directory(let state) = handles[handle] else { throw invalidHandle() }
        guard state.offset < state.entries.count else { throw DockerSFTPStatusError(code: .eof, message: "End of directory.") }
        let end = min(state.offset + 64, state.entries.count)
        let entries = Array(state.entries[state.offset..<end])
        state.offset = end
        try sendNames(requestID: requestID, entries: entries)
    }

    private func makeHandle() -> Data {
        defer { nextHandle &+= 1 }
        var value = nextHandle.bigEndian
        return Data(bytes: &value, count: MemoryLayout.size(ofValue: value))
    }

    private func sendHandle(requestID: UInt32, handle: Data) throws {
        var response = DockerSFTPPacketWriter(type: Message.handle.rawValue, requestID: requestID)
        response.dataString(handle)
        try writePacket(response.data)
    }

    private func sendAttributes(requestID: UInt32, attributes: DockerSFTPFileAttributes) throws {
        var response = DockerSFTPPacketWriter(type: Message.attrs.rawValue, requestID: requestID)
        response.attributes(attributes)
        try writePacket(response.data)
    }

    private func sendNames(requestID: UInt32, entries: [(String, DockerSFTPFileAttributes)]) throws {
        var response = DockerSFTPPacketWriter(type: Message.name.rawValue, requestID: requestID)
        response.uint32(UInt32(entries.count))
        for (name, attributes) in entries {
            response.string(name)
            response.string(name)
            response.attributes(attributes)
        }
        try writePacket(response.data)
    }

    private func sendStatus(requestID: UInt32, error: DockerSFTPStatusError) throws {
        var response = DockerSFTPPacketWriter(type: Message.status.rawValue, requestID: requestID)
        response.uint32(error.code.rawValue)
        response.string(error.message)
        response.string("")
        try writePacket(response.data)
    }

    private func invalidHandle() -> DockerSFTPStatusError {
        DockerSFTPStatusError(code: .failure, message: "Invalid SFTP handle.")
    }

    private func readPacket() throws -> Data? {
        guard let prefix = try readExactly(4), !prefix.isEmpty else { return nil }
        guard prefix.count == 4 else { throw DockerSFTPStatusError(code: .badMessage, message: "Truncated SFTP frame.") }
        let length = Int(prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })
        guard length > 0, length <= limits.maximumPacketBytes else {
            throw DockerSFTPStatusError(code: .badMessage, message: "SFTP frame exceeds the protocol limit.")
        }
        guard let packet = try readExactly(length), packet.count == length else {
            throw DockerSFTPStatusError(code: .badMessage, message: "Truncated SFTP frame.")
        }
        return packet
    }

    private func readExactly(_ count: Int) throws -> Data? {
        var result = Data()
        while result.count < count {
            guard let data = try input.read(upToCount: count - result.count), !data.isEmpty else {
                return result.isEmpty ? nil : result
            }
            result.append(data)
        }
        return result
    }

    private func writePacket(_ data: Data) throws {
        guard data.count <= limits.maximumPacketBytes else {
            throw DockerSFTPStatusError(code: .failure, message: "SFTP response exceeds the protocol limit.")
        }
        var length = UInt32(data.count).bigEndian
        try output.write(contentsOf: Data(bytes: &length, count: 4))
        try output.write(contentsOf: data)
    }
}

private struct DockerSFTPDecodedAttributes {
    var size: UInt64?
    var uid: uid_t?
    var gid: gid_t?
    var permissions: UInt32?
    var accessTime: UInt32?
    var modificationTime: UInt32?
}

private struct DockerSFTPPacketReader {
    let data: Data
    var offset = 0

    init(_ data: Data) { self.data = data }

    mutating func uint8() throws -> UInt8 {
        guard offset < data.count else { throw malformed() }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw malformed() }
        defer { offset += 4 }
        return data[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    mutating func uint64() throws -> UInt64 {
        guard offset + 8 <= data.count else { throw malformed() }
        defer { offset += 8 }
        return data[offset..<offset + 8].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
    }

    mutating func dataString(maximumBytes: Int) throws -> Data {
        let count = Int(try uint32())
        guard count <= maximumBytes, offset + count <= data.count else { throw malformed() }
        defer { offset += count }
        return Data(data[offset..<offset + count])
    }

    mutating func string(maximumBytes: Int = 4_096) throws -> String {
        guard let value = String(data: try dataString(maximumBytes: maximumBytes), encoding: .utf8),
              !value.contains("\0") else { throw malformed() }
        return value
    }

    mutating func path() throws -> String { try string(maximumBytes: 4_096) }

    mutating func attributes() throws -> DockerSFTPDecodedAttributes {
        let flags = try uint32()
        guard flags & ~UInt32(0x8000_000F) == 0 else { throw malformed() }
        var result = DockerSFTPDecodedAttributes()
        if flags & 0x1 != 0 { result.size = try uint64() }
        if flags & 0x2 != 0 {
            result.uid = try uint32()
            result.gid = try uint32()
        }
        if flags & 0x4 != 0 { result.permissions = try uint32() }
        if flags & 0x8 != 0 {
            result.accessTime = try uint32()
            result.modificationTime = try uint32()
        }
        if flags & 0x8000_0000 != 0 {
            let count = try uint32()
            guard count <= 16 else { throw malformed() }
            for _ in 0..<count {
                _ = try dataString(maximumBytes: 4_096)
                _ = try dataString(maximumBytes: 65_536)
            }
        }
        return result
    }

    private func malformed() -> DockerSFTPStatusError {
        DockerSFTPStatusError(code: .badMessage, message: "Malformed SFTP packet.")
    }
}

private struct DockerSFTPPacketWriter {
    var data = Data()

    init(type: UInt8, requestID: UInt32? = nil) {
        data.append(type)
        if let requestID { uint32(requestID) }
    }

    mutating func uint32(_ value: UInt32) {
        var encoded = value.bigEndian
        data.append(Data(bytes: &encoded, count: 4))
    }

    mutating func uint64(_ value: UInt64) {
        var encoded = value.bigEndian
        data.append(Data(bytes: &encoded, count: 8))
    }

    mutating func dataString(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) { dataString(Data(value.utf8)) }

    mutating func attributes(_ value: DockerSFTPFileAttributes) {
        uint32(0xF)
        uint64(value.size)
        uint32(value.uid)
        uint32(value.gid)
        uint32(value.permissions)
        uint32(value.accessTime)
        uint32(value.modificationTime)
    }
}

private enum DockerSFTPStatusCode: UInt32 {
    case ok = 0, eof = 1, noSuchFile = 2, permissionDenied = 3, failure = 4
    case badMessage = 5, noConnection = 6, connectionLost = 7, opUnsupported = 8
}

private struct DockerSFTPStatusError: Error {
    var code: DockerSFTPStatusCode
    var message: String

    static let ok = DockerSFTPStatusError(code: .ok, message: "")

    static func currentErrno(_ value: Int32 = errno) -> DockerSFTPStatusError {
        let code: DockerSFTPStatusCode
        switch value {
        case ENOENT, ENOTDIR: code = .noSuchFile
        case EACCES, EPERM, ELOOP: code = .permissionDenied
        default: code = .failure
        }
        return DockerSFTPStatusError(code: code, message: String(cString: strerror(value)))
    }
}

private extension Data {
    var requestID: UInt32? {
        guard count >= 5, first != 1 else { return nil }
        return self[1..<5].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }
}
