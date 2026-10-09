import Foundation
import ReconnectCore

actor AgendaSyncTransport {
    private var fileServer: FileServer
    private var commands: RemoteCommandServicesClient
    private var closedAgenda: (process: String, executable: String, path: String)?
    private var connected = true
    private var verifiedBackup: String?
    private var unverifiedReplacementBackup: String?

    init(fileServer: FileServer, commands: RemoteCommandServicesClient) {
        self.fileServer = fileServer
        self.commands = commands
    }

    func disconnect() { connected = false }

    func metadata(path: String) throws -> FileServer.DirectoryEntry {
        try checkConnection()
        try validatePath(path)
        return try fileServer.getExtendedAttributes(path: path)
    }

    func read(path: String, closeAgenda: Bool) async throws -> Data {
        try checkConnection()
        try validatePath(path)
        if let process = try commands.processUsingFile(path: path) {
            guard closeAgenda else {
                throw failure("Agenda is open on the Psion. Close it or enable closing Agenda during sync.")
            }
            let executable = try commands.executableForProcess(process)
            guard executable.lowercased().hasSuffix("\\agenda.app") else {
                throw failure("The selected file is in use by another application. Close it on the Psion before syncing.")
            }
            closedAgenda = (process, executable, path)
            try commands.requestCloseProcess(process)
            let deadline = Date().addingTimeInterval(30)
            while try commands.isProcessRunning(process) {
                try checkConnection()
                guard Date() < deadline else {
                    throw failure("Agenda has not closed. Check the Psion for a save dialog, then try syncing again.")
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard try commands.processUsingFile(path: path) == nil else {
                throw failure("The Agenda file is still open on the Psion.")
            }
        }
        try checkConnection()
        return try fileServer.readFile(path: path)
    }

    func verifyUnchanged(path: String, original: Data) throws {
        try checkConnection()
        guard try commands.processUsingFile(path: path) == nil,
              try fileServer.readFile(path: path) == original else {
            throw failure("The Agenda changed during sync. No replacement was made; sync again to include the latest edits.")
        }
    }

    func replace(path: String, original: Data, replacement: Data) throws {
        try verifyUnchanged(path: path, original: original)
        let suffix = UUID().uuidString
        let temporary = path + ".reconnect-" + suffix + ".tmp"
        let backup = path + ".reconnect-" + suffix + ".bak"
        try fileServer.writeFile(path: temporary, data: replacement)
        guard try fileServer.readFile(path: temporary) == replacement else {
            throw failure("The uploaded Agenda could not be verified. The original file is unchanged.")
        }
        try verifyUnchanged(path: path, original: original)
        try fileServer.rename(from: path, to: backup)
        unverifiedReplacementBackup = backup
        do {
            try fileServer.rename(from: temporary, to: path)
        } catch {
            // A failed rename must not remove a file another process may have created.
            if !(try fileServer.exists(path: path)) {
                try fileServer.rename(from: backup, to: path)
                unverifiedReplacementBackup = nil
            }
            throw error
        }
        guard try fileServer.readFile(path: path) == replacement else {
            throw failure("The replacement Agenda could not be verified. Its original is retained on the Psion as \(backup).")
        }
        unverifiedReplacementBackup = nil
        verifiedBackup = backup
    }

    func finishVerifiedSync() {
        // The coordinator calls this only after both sides and the persisted baseline verify.
        // The original is still archived locally; remove the temporary remote backup to save Psion space.
        if connected, let verifiedBackup {
            try? fileServer.remove(path: verifiedBackup)
            self.verifiedBackup = nil
        }
    }

    func reopenAgenda() throws {
        guard connected, let closed = closedAgenda else { return }
        if let backup = unverifiedReplacementBackup {
            closedAgenda = nil
            unverifiedReplacementBackup = nil
            throw failure("Agenda was left closed because the replacement could not be verified. The original is retained at \(backup).")
        }
        if try !commands.isProcessRunning(closed.process), try commands.processUsingFile(path: closed.path) == nil {
            try commands.execProgram(program: closed.executable, args: "A" + closed.path)
        }
        closedAgenda = nil
    }

    private func checkConnection() throws {
        try Task.checkCancellation()
        guard connected else { throw CancellationError() }
    }

    private func validatePath(_ path: String) throws {
        let encoding: String.Encoding
        switch try fileServer.deviceEncoding() {
        case .stringEncoding(let value):
            encoding = value
        case .cfStringEncoding(let value):
            encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
        }
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              path.canBeConverted(to: encoding) else {
            throw failure("The file path contains characters the Psion cannot represent. Choose its original file name.")
        }
        guard path.utf16.count <= 200 else {
            throw failure("Shorten the Agenda file path to 200 characters or fewer to leave space for temporary sync file names.")
        }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Reconnect.AgendaSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
