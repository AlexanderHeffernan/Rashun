import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(WinSDK)
    import WinSDK
#endif

public protocol PersistenceBackend: Sendable {
    func data(forKey key: String) throws -> Data?
    func set(_ data: Data?, forKey key: String) throws
    @discardableResult
    func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data?
}

public enum PersistenceBackendError: Error, LocalizedError, Equatable {
    case readFailed(path: String, detail: String)
    case directoryCreationFailed(path: String, detail: String)
    case lockOpenFailed(path: String, code: Int32)
    case lockAcquireFailed(path: String, code: Int32)
    case writeFailed(path: String, detail: String)
    case removeFailed(path: String, detail: String)

    public var errorDescription: String? {
        switch self {
        case .readFailed(let path, let detail):
            "Could not read tracking data at \(path): \(detail)"
        case .directoryCreationFailed(let path, let detail):
            "Could not create the tracking data directory at \(path): \(detail)"
        case .lockOpenFailed(let path, let code):
            "Could not open the tracking data lock at \(path) (system error \(code))."
        case .lockAcquireFailed(let path, let code):
            "Could not acquire the tracking data lock at \(path) (system error \(code))."
        case .writeFailed(let path, let detail):
            "Could not save tracking data at \(path): \(detail)"
        case .removeFailed(let path, let detail):
            "Could not remove tracking data at \(path): \(detail)"
        }
    }
}

public final class UserDefaultsBackend: PersistenceBackend, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let lock = NSLock()

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func data(forKey key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return userDefaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        userDefaults.set(data, forKey: key)
    }

    @discardableResult
    public func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = try update(userDefaults.data(forKey: key))
        userDefaults.set(data, forKey: key)
        return data
    }
}

public final class FilePersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    public func data(forKey key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return try readData(at: url(forKey: key))
    }

    public func set(_ data: Data?, forKey key: String) throws {
        try updateData(forKey: key) { _ in data }
    }

    @discardableResult
    public func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data? {
        try withFileLock(forKey: key) {
            let fileURL = url(forKey: key)
            let data = try update(readData(at: fileURL))
            if let data {
                do {
                    try data.write(to: fileURL, options: .atomic)
                } catch {
                    throw PersistenceBackendError.writeFailed(
                        path: fileURL.path, detail: error.localizedDescription)
                }
            } else {
                do {
                    if fileManager.fileExists(atPath: fileURL.path) {
                        try fileManager.removeItem(at: fileURL)
                    }
                } catch {
                    throw PersistenceBackendError.removeFailed(
                        path: fileURL.path, detail: error.localizedDescription)
                }
            }
            return data
        }
    }

    private func withFileLock<T>(forKey key: String, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        try createDirectoryIfNeeded()
        let lockURL = url(forKey: key).appendingPathExtension("lock")
        #if canImport(Darwin) || canImport(Glibc)
            let descriptor = retryAfterInterruption {
                open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw PersistenceBackendError.lockOpenFailed(path: lockURL.path, code: errno)
            }
            let lockResult = retryAfterInterruption { flock(descriptor, LOCK_EX) }
            guard lockResult == 0 else {
                let code = errno
                close(descriptor)
                throw PersistenceBackendError.lockAcquireFailed(path: lockURL.path, code: code)
            }
            defer {
                _ = retryAfterInterruption { flock(descriptor, LOCK_UN) }
                close(descriptor)
            }
        #elseif canImport(WinSDK)
            let handle = lockURL.path.withCString(encodedAs: UTF16.self) { path in
                CreateFileW(
                    path, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE),
                    DWORD(FILE_SHARE_READ) | DWORD(FILE_SHARE_WRITE), nil, DWORD(OPEN_ALWAYS),
                    DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard handle != INVALID_HANDLE_VALUE else {
                throw PersistenceBackendError.lockOpenFailed(
                    path: lockURL.path, code: Int32(bitPattern: GetLastError()))
            }
            var overlapped = OVERLAPPED()
            guard
                LockFileEx(
                    handle, DWORD(LOCKFILE_EXCLUSIVE_LOCK), 0, DWORD.max, DWORD.max,
                    &overlapped)
            else {
                let code = Int32(bitPattern: GetLastError())
                CloseHandle(handle)
                throw PersistenceBackendError.lockAcquireFailed(path: lockURL.path, code: code)
            }
            defer {
                _ = UnlockFileEx(handle, 0, DWORD.max, DWORD.max, &overlapped)
                CloseHandle(handle)
            }
        #else
            #error("FilePersistenceBackend requires an operating-system file-lock API")
        #endif
        return try body()
    }

    private func readData(at fileURL: URL) throws -> Data? {
        do {
            return try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch {
            throw PersistenceBackendError.readFailed(
                path: fileURL.path, detail: error.localizedDescription)
        }
    }

    private func createDirectoryIfNeeded() throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw PersistenceBackendError.directoryCreationFailed(
                path: directoryURL.path, detail: error.localizedDescription)
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
        private func retryAfterInterruption(_ operation: () -> Int32) -> Int32 {
            var result: Int32
            repeat {
                result = operation()
            } while result == -1 && errno == EINTR
            return result
        }
    #endif

    private func url(forKey key: String) -> URL {
        directoryURL.appendingPathComponent(sanitizedKey(key)).appendingPathExtension("json")
    }

    private func sanitizedKey(_ key: String) -> String {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

public enum PersistenceBackendFactory {
    public static func `default`() -> PersistenceBackend {
        #if os(macOS)
            let fileManager = FileManager.default
            let appSupport =
                fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Application Support", isDirectory: true)
            let url = appSupport.appendingPathComponent("Rashun", isDirectory: true)
            return FilePersistenceBackend(directoryURL: url)
        #elseif os(iOS) || os(tvOS) || os(watchOS)
            return UserDefaultsBackend()
        #elseif os(Windows)
            let env = ProcessInfo.processInfo.environment
            if let appData = env["APPDATA"], !appData.isEmpty {
                let url = URL(fileURLWithPath: appData, isDirectory: true)
                    .appendingPathComponent("Rashun", isDirectory: true)
                return FilePersistenceBackend(directoryURL: url)
            }
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let fallbackURL = homeDirectory.appendingPathComponent(".rashun", isDirectory: true)
            return FilePersistenceBackend(directoryURL: fallbackURL)
        #else
            let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            let url = homeDirectory.appendingPathComponent(".rashun", isDirectory: true)
            return FilePersistenceBackend(directoryURL: url)
        #endif
    }

    public static func defaultLegacyBackends() -> [PersistenceBackend] {
        var backends: [PersistenceBackend] = [UserDefaultsBackend()]

        if let appSuite = UserDefaults(suiteName: "com.alexanderheffernan.rashun") {
            backends.append(UserDefaultsBackend(userDefaults: appSuite))
        }
        if let appSuite = UserDefaults(suiteName: "Rashun") {
            backends.append(UserDefaultsBackend(userDefaults: appSuite))
        }

        return backends
    }
}

public final class InMemoryPersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]

    public init(initialStorage: [String: Data] = [:]) {
        self.storage = initialStorage
    }

    public func data(forKey key: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }

    @discardableResult
    public func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let data = try update(storage[key])
        storage[key] = data
        return data
    }
}
