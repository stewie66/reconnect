import CryptoKit
import EventKit
import Foundation
import Observation
import PsionFormats
import ReconnectCore

@MainActor @Observable
final class AgendaSyncModel {
    var settings: AgendaSyncSettings {
        didSet {
            if oldValue.agendaPath.lowercased() != settings.agendaPath.lowercased() ||
                oldValue.calendarID != settings.calendarID || oldValue.timeZoneID != settings.timeZoneID {
                if let device {
                    settings.selectPairing(device: device.id, preserving: oldValue)
                }
                do {
                    state = try AgendaSyncState.load(from: stateURL)
                    loadingError = nil
                } catch { loadingError = error.localizedDescription }
                lastSuccessfulSync = state.lastSuccessfulSync
                lastMetadata = nil
                lastMacSnapshot = nil
            }
            if oldValue.direction != settings.direction {
                lastMetadata = nil
                lastMacSnapshot = nil
            }
            if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: defaultsKey) }
            automaticPaused = false
            macChanged = true
            if settings.enabled, settings.automatic, !oldValue.enabled || !oldValue.automatic {
                Task { syncNow(automatic: true) }
            }
        }
    }
    private(set) var calendars: [AgendaCalendarService.CalendarChoice] = []
    private(set) var isSyncing = false
    private(set) var isConnected = true
    private(set) var status = "Choose an Agenda file and a Mac calendar to enable sync."
    private(set) var errorMessage: String?
    private(set) var importNotice: String?
    private(set) var lastSuccessfulSync: Date?
    private(set) var automaticPaused = false
    private(set) var isCreatingCalendar = false

    @ObservationIgnored private weak var device: DeviceModel?
    @ObservationIgnored private weak var applicationModel: ApplicationModel?
    @ObservationIgnored private var calendarService = AgendaCalendarService()
    @ObservationIgnored private var transport: AgendaSyncTransport
    @ObservationIgnored private var state = AgendaSyncState()
    @ObservationIgnored private var defaultsKey: String
    @ObservationIgnored private var rootURL: URL
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var notificationObserver: NSObjectProtocol?
    @ObservationIgnored private var lastMetadata: FileServer.DirectoryEntry?
    @ObservationIgnored private var lastMacSnapshot: [String: AgendaSyncContent]?
    @ObservationIgnored private var macChanged = true
    @ObservationIgnored private var loadingError: String?

    var hasValidPairing: Bool {
        settings.agendaPath.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^[A-Za-z]:\\[^\r\n]+$"#, options: .regularExpression) != nil &&
            TimeZone(identifier: settings.timeZoneID) != nil && calendars.contains { $0.id == settings.calendarID }
    }

    var canSync: Bool {
        isConnected && settings.enabled && hasValidPairing && !isSyncing
    }

    init(device: DeviceModel, applicationModel: ApplicationModel) {
        self.device = device
        self.applicationModel = applicationModel
        defaultsKey = "agendaSync.settings." + device.id.uuidString
        if let data = UserDefaults.standard.data(forKey: defaultsKey) {
            do { settings = try JSONDecoder().decode(AgendaSyncSettings.self, from: data) }
            catch {
                settings = AgendaSyncSettings()
                loadingError = "The saved sync settings could not be read. Configure a new pairing before syncing."
            }
        } else { settings = AgendaSyncSettings() }
        rootURL = applicationModel.backupsURL.deletingLastPathComponent()
            .appendingPathComponent("AgendaSync", isDirectory: true).appendingPathComponent(device.id.uuidString, isDirectory: true)
        transport = AgendaSyncTransport(fileServer: device.transfersFileServer, commands: device.remoteCommandServicesClient)
        settings.selectPairing(device: device.id)
        if loadingError == nil, let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        do {
            state = try AgendaSyncState.load(from: stateURL)
            lastSuccessfulSync = state.lastSuccessfulSync
        } catch { loadingError = error.localizedDescription }
    }

    private var stateURL: URL { rootURL.appendingPathComponent(settings.pairingID.uuidString + ".json") }

    func start() {
        notificationObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.macChanged = true
                await self.refreshCalendars()
                if self.settings.automatic, !self.automaticPaused { self.syncNow(automatic: true) }
            }
        }
        pollingTask = Task { [weak self] in
            await self?.refreshCalendars()
            while !Task.isCancelled {
                await self?.poll()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    func stop() {
        isConnected = false
        pollingTask?.cancel()
        syncTask?.cancel()
        if let notificationObserver { NotificationCenter.default.removeObserver(notificationObserver) }
        notificationObserver = nil
        Task { await transport.disconnect() }
    }

    func allowCalendarAccess() async {
        do {
            try await calendarService.authorize()
            errorMessage = nil
            await refreshCalendars()
        } catch { errorMessage = error.localizedDescription }
    }

    func createPsionCalendar() async {
        guard !isCreatingCalendar, !settings.enabled else { return }
        isCreatingCalendar = true
        defer { isCreatingCalendar = false }
        do {
            let choice = try await calendarService.createCalendar(title: "Psion Agenda — " + (device?.name ?? "My Psion"))
            await refreshCalendars()
            settings.calendarID = choice.id
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshCalendars() async {
        do { calendars = try await calendarService.calendars() }
        catch { calendars = [] }
    }

    private func poll() async {
        guard settings.automatic, settings.isConfigured, !automaticPaused, !isSyncing, isConnected else { return }
        do {
            let metadata = try await transport.metadata(path: settings.agendaPath)
            if macChanged || lastMetadata?.modificationDate != metadata.modificationDate || lastMetadata?.size != metadata.size {
                syncNow(automatic: true)
            }
        } catch {
            errorMessage = error.localizedDescription
            automaticPaused = true
        }
    }

    func syncNow(automatic: Bool = false) {
        guard canSync, !automatic || !automaticPaused else { return }
        isSyncing = true
        automaticPaused = false
        errorMessage = nil
        importNotice = nil
        syncTask = Task { await performSync(automatic: automatic) }
    }

    func cancel() { syncTask?.cancel() }

    private func performSync(automatic: Bool) async {
        let configuration = settings
        let operationID = UUID()
        guard let device, let applicationModel else { isSyncing = false; return }
        guard !device.isBackingUp, applicationModel.longRunningOperations.isEmpty else {
            isSyncing = false
            status = "Waiting for the current device operation to finish."
            return
        }
        applicationModel.longRunningOperations.insert(operationID)
        defer {
            applicationModel.longRunningOperations.remove(operationID)
            isSyncing = false
        }
        do {
            if let loadingError { throw failure(loadingError) }
            guard let timeZone = TimeZone(identifier: configuration.timeZoneID) else { throw failure("Choose a valid Psion time zone.") }
            let identityTimeZoneID = configuration.pairings.pairing(device: device.id, path: configuration.agendaPath,
                calendar: configuration.calendarID)?.identityTimeZoneID ?? configuration.timeZoneID
            guard let identityTimeZone = TimeZone(identifier: identityTimeZoneID) else {
                throw failure("The saved pairing's time zone is unavailable. Restore its original time-zone setting before syncing.")
            }
            let previousZone = state.synchronizedTimeZoneID ?? identityTimeZoneID
            if configuration.direction == .bidirectional, state.links.contains(where: \.hasBaseline),
               previousZone != configuration.timeZoneID {
                throw failure("The Psion time zone changed. Run one sync with Agenda or Mac Calendar selected as the source before enabling Both directions again. Existing mappings are retained.")
            }
            let path = configuration.agendaPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.range(of: #"^[A-Za-z]:\\[^\r\n]+$"#, options: .regularExpression) != nil else {
                throw failure("Enter the full Psion file path, such as C:\\Documents\\Agenda.")
            }
            guard let calendar = calendars.first(where: { $0.id == configuration.calendarID }),
                  configuration.direction == .macToAgenda || calendar.writable else {
                throw failure("Choose an available calendar. Syncing to Mac Calendar requires a writable calendar.")
            }
            status = "Reading Mac Calendar…"
            let macSnapshot = try await calendarService.snapshot(calendarID: configuration.calendarID, timeZone: timeZone,
                                                                 identityTimeZone: identityTimeZone,
                                                                 allowSourceOnlyMetadata: configuration.direction == .macToAgenda)
            let macEvents = macSnapshot.events
            reportImportNotices(macEvents)
            let initialMac = Dictionary(uniqueKeysWithValues: macEvents.map { ($0.id, $0.content) })
            if automatic, lastMacSnapshot == initialMac, let lastMetadata {
                let metadata = try await transport.metadata(path: path)
                if metadata.modificationDate == lastMetadata.modificationDate, metadata.size == lastMetadata.size {
                    macChanged = false
                    status = "Up to date."
                    return
                }
            }
            status = "Closing Agenda and reading the saved file…"
            let original = try await transport.read(path: path, closeAgenda: configuration.closeAgenda)
            let document = try AgendaSyncDocument(original)
            var mac = Dictionary(uniqueKeysWithValues: macEvents.map { ($0.id, $0) })
            let agenda = Dictionary(uniqueKeysWithValues: document.events.map { ($0.id, $0.content) })
            var links = state.links
            for index in links.indices {
                guard links[index].macID.flatMap({ mac[$0] }) == nil else { continue }
                let url = recoveryURL(pairing: configuration.pairingID, link: links[index].id).absoluteString
                let candidates = macEvents.filter {
                    $0.recoveryURL == url || (links[index].externalID != nil && $0.externalID == links[index].externalID)
                }
                guard candidates.count <= 1 else { throw failure("A Mac event identifier matches more than one event. Resolve the duplicate before syncing.") }
                if let recovered = candidates.first {
                    links[index].macID = recovered.id
                    links[index].externalID = recovered.externalID
                } else if let oldID = links[index].macID {
                    // Calendar still owns an expanded series. Retire its old aggregate mapping so
                    // the repeating Agenda entry and its individual appointments cannot coexist.
                    if !macSnapshot.replacedSeriesIDs.contains(oldID) {
                        try await calendarService.verifyMissing(oldID, timeZone: identityTimeZone)
                    }
                }
            }
            var linkedAgenda = Set(links.map(\.agendaID))
            var linkedMac = Set(links.compactMap(\.macID))
            if configuration.direction != .macToAgenda {
                for event in document.events where !linkedAgenda.contains(event.id) {
                    let matches = configuration.direction == .bidirectional ? macEvents.filter {
                        !linkedMac.contains($0.id) && $0.content == event.content
                    } : []
                    guard matches.count <= 1 else { throw failure("Identical events make the initial pairing ambiguous. Use a one-way sync to establish a source.") }
                    let match = matches.first
                    links.append(.init(agendaID: event.id, macID: match?.id, externalID: match?.externalID))
                    linkedAgenda.insert(event.id)
                    if let match { linkedMac.insert(match.id) }
                }
            }
            if configuration.direction != .agendaToMac {
                for event in macEvents where !linkedMac.contains(event.id) {
                    let digest = SHA256.hash(data: Data((configuration.pairingID.uuidString + event.id).utf8))
                        .prefix(16).map { String(format: "%02x", $0) }.joined()
                    links.append(.init(agendaID: "global:" + digest, macID: event.id, externalID: event.externalID))
                    linkedMac.insert(event.id)
                }
            }
            var desired: [UUID: AgendaSyncContent] = [:]
            var nativeUpserts: [AgendaSyncEvent] = []
            var nativeDeletions = Set<String>()
            var macUpdates: [Int] = []
            for index in links.indices {
                let link = links[index]
                let nativeContent = agenda[link.agendaID]
                let macContent = link.macID.flatMap { mac[$0]?.content }
                let result = try AgendaSyncPlanner.resolve(agenda: nativeContent, mac: macContent,
                    baseline: link.baseline, hasBaseline: link.hasBaseline,
                    direction: configuration.direction, conflicts: configuration.conflicts)
                desired[link.id] = result
                if nativeContent != result, configuration.direction != .agendaToMac {
                    if let result { nativeUpserts.append(.init(id: link.agendaID, content: result)) }
                    else if nativeContent != nil { nativeDeletions.insert(link.agendaID) }
                }
                if macContent != result, configuration.direction != .macToAgenda {
                    try await calendarService.validateChange(result, replacing: link.macID, timeZone: timeZone)
                    macUpdates.append(index)
                }
            }
            status = "Validating sync changes…"
            let replacement = try document.applying(upserts: nativeUpserts, deleting: nativeDeletions, timeZone: timeZone)
            try Task.checkCancellation()
            // Save links before the first write, keeping the old baseline until both sides verify.
            state.links = links
            try state.save(to: stateURL)
            try await transport.verifyUnchanged(path: path, original: original)
            if replacement != original {
                let backup = rootURL.appendingPathComponent("Backups", isDirectory: true)
                    .appendingPathComponent(configuration.pairingID.uuidString + "-" + UUID().uuidString + ".agn")
                try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                try original.write(to: backup, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                status = "Updating Agenda…"
                try await transport.replace(path: path, original: original, replacement: replacement)
            }
            status = "Updating Mac Calendar…"
            for index in macUpdates {
                try Task.checkCancellation()
                let link = state.links[index]
                let currentID = link.macID.flatMap { mac[$0] != nil ? $0 : nil }
                let saved = try await calendarService.write(desired[link.id], replacing: currentID,
                    expected: link.macID.flatMap { mac[$0]?.content }, calendarID: configuration.calendarID,
                    timeZone: timeZone, recoveryURL: recoveryURL(pairing: configuration.pairingID, link: link.id))
                if let saved {
                    state.links[index].macID = saved.id
                    state.links[index].externalID = saved.externalID
                    mac[saved.id] = saved
                }
                try state.save(to: stateURL)
            }
            try await transport.verifyUnchanged(path: path, original: replacement)
            let finalMac = try await calendarService.snapshot(calendarID: configuration.calendarID, timeZone: timeZone,
                                                              identityTimeZone: identityTimeZone,
                                                              allowSourceOnlyMetadata: configuration.direction == .macToAgenda).events
            reportImportNotices(finalMac)
            let finalMap = Dictionary(uniqueKeysWithValues: finalMac.map { ($0.id, $0.content) })
            for index in state.links.indices {
                let link = state.links[index]
                guard link.macID.flatMap({ finalMap[$0] }) == desired[link.id] else {
                    throw failure("Mac Calendar changed before sync completed. The saved mappings allow the next sync to resume.")
                }
                state.links[index].baseline = desired[link.id]
                state.links[index].hasBaseline = true
            }
            state.lastSuccessfulSync = Date()
            state.synchronizedTimeZoneID = configuration.timeZoneID
            try state.save(to: stateURL)
            await transport.finishVerifiedSync()
            lastSuccessfulSync = state.lastSuccessfulSync
            lastMacSnapshot = finalMap
            macChanged = false
            status = "Sync complete. \(nativeUpserts.count + nativeDeletions.count) Agenda changes; \(macUpdates.count) Mac Calendar changes."
        } catch {
            automaticPaused = true
            if error is CancellationError {
                status = "Sync canceled. Choose Sync Now to resume."
            } else {
                errorMessage = error.localizedDescription
                status = "Sync paused."
            }
        }
        do {
            try await transport.reopenAgenda()
        } catch {
            let message = "Agenda could not be reopened: " + error.localizedDescription
            errorMessage = [errorMessage, message].compactMap { $0 }.joined(separator: "\n")
            automaticPaused = true
        }
        if isConnected, !Task.isCancelled {
            do { lastMetadata = try await transport.metadata(path: configuration.agendaPath) }
            catch {
                errorMessage = [errorMessage, "Could not read the Psion's status: " + error.localizedDescription]
                    .compactMap { $0 }.joined(separator: "\n")
                automaticPaused = true
            }
        }
    }

    private func recoveryURL(pairing: UUID, link: UUID) -> URL {
        URL(string: "x-reconnect://agenda-sync/\(pairing.uuidString)/\(link.uuidString)")!
    }

    private func reportImportNotices(_ events: [AgendaCalendarService.EventSnapshot]) {
        var messages: [String] = []
        for notice in AgendaSyncCalendarProjection.Notice.allCases {
            let count = events.filter { $0.notices.contains(notice) }.count
            guard count > 0 else { continue }
            let appointments = "\(count) " + (count == 1 ? "appointment" : "appointments")
            switch notice {
            case .invitationDetails:
                messages.append("Invitation details for \(appointments) stay in Mac Calendar.")
            case .extraAlarms:
                messages.append("Extra alerts for \(appointments) stay in Mac Calendar. Agenda keeps the earliest supported alert, if available.")
            case .unsupportedAlarms:
                messages.append("Alerts Agenda cannot represent for \(appointments) stay in Mac Calendar.")
            case .convertedAbsoluteAlarm:
                messages.append("Dated alerts for \(appointments) are represented relative to the appointment start.")
            case .convertedTimeZone:
                messages.append("Repeating times for \(appointments) are converted to the Psion time zone.")
            case .expandedRecurrence:
                messages.append("\(appointments) are copied individually to preserve Calendar's repeat schedule within 1980–2100.")
            case .roundedTimes:
                messages.append("Times for \(appointments) are rounded to the nearest minute in Agenda.")
            case .convertedText:
                messages.append("Text for \(appointments) is transliterated where possible; unsupported characters use ?. Original text stays in Mac Calendar.")
            case .placeholderText:
                messages.append("\(appointments) without text use Untitled appointment in Agenda.")
            case .reanchoredRecurrence:
                messages.append("\(appointments) whose series started before 1980 begin at their first supported occurrence. The original series date is kept in Agenda notes.")
            }
        }
        importNotice = messages.isEmpty ? nil : "Agenda import notes:\n" + messages.joined(separator: "\n")
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Reconnect.AgendaSync", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
