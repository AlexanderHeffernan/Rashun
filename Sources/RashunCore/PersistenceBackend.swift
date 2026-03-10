import Foundation

public protocol PersistenceBackend: Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class UserDefaultsBackend: PersistenceBackend, @unchecked Sendable {
    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func data(forKey key: String) -> Data? {
        userDefaults.data(forKey: key)
    }

    public func set(_ data: Data?, forKey key: String) {
        userDefaults.set(data, forKey: key)
    }
}

public final class FilePersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        createDirectoryIfNeeded()
    }

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = url(forKey: key)
        return try? Data(contentsOf: fileURL)
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = url(forKey: key)
        if let data {
            do {
                createDirectoryIfNeeded()
                try data.write(to: fileURL, options: .atomic)
            } catch {
                return
            }
        } else {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func createDirectoryIfNeeded() {
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func url(forKey key: String) -> URL {
        directoryURL.appendingPathComponent(sanitizedKey(key)).appendingPathExtension("json")
    }

    private func sanitizedKey(_ key: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

public enum PersistenceBackendFactory {
    public static func `default`() -> PersistenceBackend {
        #if os(macOS)
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
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

    public func data(forKey key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = data
    }
}
