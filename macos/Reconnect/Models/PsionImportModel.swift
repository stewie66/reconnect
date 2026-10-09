import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import PsionFormats

@MainActor @Observable
final class PsionImportModel {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case agenda, contacts
        var id: Self { self }
        var fileExtension: String { self == .agenda ? "agn" : "cdb" }
    }

    var format: Format = .agenda {
        didSet {
            if oldValue != format { sourceURL = nil; sourceData = nil; baseURL = nil; baseData = nil; status = nil }
        }
    }
    var mode: PsionImportMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "psionImportMode"); status = nil }
    }
    var timeZoneIdentifier: String {
        didSet { UserDefaults.standard.set(timeZoneIdentifier, forKey: "psionImportTimeZone"); status = nil }
    }
    var sourceURL: URL?
    var baseURL: URL?
    var isConverting = false
    var errorMessage: String?
    var status: String?
    let timeZoneIdentifiers: [String]
    private var sourceData: Data?
    private var baseData: Data?

    var canConvert: Bool { sourceData != nil && baseData != nil && !isConverting }

    init() {
        mode = PsionImportMode(rawValue: UserDefaults.standard.string(forKey: "psionImportMode") ?? "") ?? .createNew
        let saved = UserDefaults.standard.string(forKey: "psionImportTimeZone") ?? TimeZone.current.identifier
        let identifier = TimeZone(identifier: saved) != nil ? saved : TimeZone.current.identifier
        timeZoneIdentifier = identifier
        timeZoneIdentifiers = Array(Set(TimeZone.knownTimeZoneIdentifiers + [identifier])).sorted()
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = format == .agenda ? "Choose an iCalendar file" : "Choose a vCard file"
        panel.allowedContentTypes = [UTType(filenameExtension: format == .agenda ? "ics" : "vcf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try read(url, maximumSize: 16 * 1024 * 1024)
            sourceURL = url; sourceData = data; status = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func chooseBase() {
        let panel = NSOpenPanel()
        panel.title = mode == .createNew ? "Choose an empty Psion file" : "Choose the Psion file to merge into"
        panel.message = format == .agenda ? "Choose an ER5 Agenda file. Extensionless Agenda files are supported." : "Choose an ER5 Contacts database (.cdb)."
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try read(url, maximumSize: 64 * 1024 * 1024)
            baseURL = url; baseData = data; status = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func convert() async {
        guard canConvert, let sourceData, let baseData, let sourceURL, let baseURL else { return }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            errorMessage = "Choose a valid time zone for the Psion."; return
        }
        let selectedFormat = format, selectedMode = mode
        isConverting = true; status = nil
        defer { isConverting = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                if selectedFormat == .agenda {
                    return try AgendaImporter.convert(sourceData, using: baseData, mode: selectedMode, timeZone: timeZone)
                }
                return try ContactsImporter.convert(sourceData, using: baseData, mode: selectedMode)
            }.value
            if result.addedCount == 0 {
                status = "All \(result.skippedCount) entries already have matching identifiers. No new file was saved."
                return
            }
            let panel = NSSavePanel()
            panel.title = "Save the converted Psion file"
            panel.allowedContentTypes = [UTType(filenameExtension: selectedFormat.fileExtension) ?? .data]
            panel.canCreateDirectories = true
            let name = selectedMode == .merge ? baseURL.deletingPathExtension().lastPathComponent + "-merged" : sourceURL.deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = name + "." + selectedFormat.fileExtension
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            guard !sameFile(destination, baseURL), !sameFile(destination, sourceURL) else {
                throw PsionImportError.invalid("save to a different file so the original stays intact")
            }
            try result.data.write(to: destination, options: .atomic)
            status = "Saved \(destination.lastPathComponent). Added \(result.addedCount); skipped \(result.skippedCount) matching identifiers. Upload this file to your Psion using File → Upload."
        } catch { errorMessage = error.localizedDescription }
    }

    private func read(_ url: URL, maximumSize: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maximumSize {
            throw PsionImportError.invalid("the selected file is too large")
        }
        return try Data(contentsOf: url)
    }

    private func sameFile(_ first: URL, _ second: URL) -> Bool {
        if first.resolvingSymlinksInPath().standardizedFileURL == second.resolvingSymlinksInPath().standardizedFileURL { return true }
        // Also protect hard links to either input.
        let a = try? FileManager.default.attributesOfItem(atPath: first.path)
        let b = try? FileManager.default.attributesOfItem(atPath: second.path)
        return a?[.systemFileNumber] as? UInt64 != nil && a?[.systemFileNumber] as? UInt64 == b?[.systemFileNumber] as? UInt64 &&
            a?[.systemNumber] as? UInt64 == b?[.systemNumber] as? UInt64
    }
}
