import Foundation

/// The data folder of this process. `--data-dir=<absolute path>` points one process at its own folder, so that a staged build
/// that runs next to the installed app shares no settings, models or logs with it.
enum DataDirectory {
    static let argument = "--data-dir"

    /// Why the folder given with `--data-dir` cannot be used.
    enum Failure: Error, Equatable {
        case missingPath
        case notAbsolute(String)
        case notAFolder(String)
        case notCreated(String, reason: String)
        case notWritable(String)

        var message: String {
            switch self {
            case .missingPath: return "\(argument) needs a path: \(argument)=/absolute/path"
            case .notAbsolute(let value): return "\(argument) needs an absolute path, not \"\(value)\""
            case .notAFolder(let path): return "\(argument): \(path) is not a folder"
            case .notCreated(let path, let reason): return "\(argument): cannot create \(path): \(reason)"
            case .notWritable(let path): return "\(argument): cannot write to \(path)"
            }
        }
    }

    /// The folder named by the last `--data-dir=` argument, or nil when there is none. `~` and relative paths are refused,
    /// because the shell does not always expand them and the folder would then depend on where the app was started.
    static func requested(arguments: [String]) -> Result<URL?, Failure> {
        guard let last = arguments.last(where: { $0 == argument || $0.hasPrefix(argument + "=") }) else { return .success(nil) }
        let value = String(last.dropFirst(argument.count + 1))
        if value.isEmpty { return .failure(.missingPath) }
        guard value.hasPrefix("/") else { return .failure(.notAbsolute(value)) }
        return .success(URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL)
    }

    /// Creates `folder` with mode 0700 when it is missing, and checks that this process can write to it.
    static func prepare(_ folder: URL) -> Failure? {
        let fileManager = FileManager.default
        var isFolder: ObjCBool = false
        if !fileManager.fileExists(atPath: folder.path, isDirectory: &isFolder) {
            do { try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            catch { return .notCreated(folder.path, reason: error.localizedDescription) }
        } else if !isFolder.boolValue {
            return .notAFolder(folder.path)
        }
        return access(folder.path, W_OK | X_OK) == 0 ? nil : .notWritable(folder.path)
    }

    /// The folder of this process; nil means the standard one. A `--data-dir` that cannot be used stops the process: falling
    /// back to the standard folder would let a staged build change the data of the installed app.
    static let customURL: URL? = {
        switch requested(arguments: CommandLine.arguments) {
        case .success(nil):
            return nil
        case .success(let folder?):
            if let failure = prepare(folder) { stop(failure, code: EX_CANTCREAT) }
            return folder
        case .failure(let failure):
            stop(failure, code: EX_USAGE)
        }
    }()

    /// Checks `--data-dir` and creates its folder. main.swift calls it first, before anything reads `AppPaths`.
    static func setUp() { _ = customURL }

    private static func stop(_ failure: Failure, code: Int32) -> Never {
        fputs("[cadenza] \(failure.message)\n", stderr)
        exit(code)
    }

    /// The name that the settings window shows under the page title when the process uses its own folder, so that two running
    /// copies look different. Only the last part of the path, so that a screenshot of the window does not show the user name.
    static func displayName(_ folder: URL? = customURL) -> String? { folder?.lastPathComponent }
}
