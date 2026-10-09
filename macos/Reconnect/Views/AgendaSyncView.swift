import SwiftUI
import PsionFormats

struct AgendaSyncView: View {
    @Bindable var model: AgendaSyncModel
    private var timeZones = TimeZone.knownTimeZoneIdentifiers

    var body: some View {
        DetailsSection("Agenda Sync") {
            Form {
                Toggle("Enable Agenda sync", isOn: $model.settings.enabled)
                    .disabled(!model.hasValidPairing && !model.settings.enabled)
                TextField("Agenda file on Psion:", text: $model.settings.agendaPath,
                          prompt: Text("C:\\Documents\\Agenda"))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .disabled(model.settings.enabled)
                if model.calendars.isEmpty {
                    LabeledContent("Mac calendar:") {
                        Button("Allow Calendar Access…") {
                            Task { await model.allowCalendarAccess() }
                        }
                    }
                } else {
                    Picker("Mac calendar:", selection: $model.settings.calendarID) {
                        Text("Choose a calendar").tag("")
                        ForEach(model.calendars) { calendar in
                            Text(calendar.title + (calendar.writable ? "" : " (read-only)"))
                                .tag(calendar.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(model.settings.enabled)
                    Button(model.isCreatingCalendar ? "Creating Calendar…" : "Create Psion Calendar") {
                        Task { await model.createPsionCalendar() }
                    }
                    .disabled(model.settings.enabled || model.isCreatingCalendar)
                }
                Picker("Sync direction:", selection: $model.settings.direction) {
                    ForEach(AgendaSyncPlanner.Direction.allCases, id: \.rawValue) { direction in
                        Text(direction.title).tag(direction)
                    }
                }
                .pickerStyle(.menu)
                Picker("Psion time zone:", selection: $model.settings.timeZoneID) {
                    ForEach(timeZones, id: \.self) { zone in Text(zone).tag(zone) }
                }
                .pickerStyle(.menu)
                .disabled(model.settings.enabled)
                if model.settings.direction == .bidirectional {
                    Picker("When both sides change:", selection: $model.settings.conflicts) {
                        ForEach(AgendaSyncPlanner.ConflictPolicy.allCases, id: \.rawValue) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Toggle("Sync automatically when connected", isOn: $model.settings.automatic)
                Toggle("Close Agenda during sync and reopen afterward", isOn: $model.settings.closeAgenda)
            }
            .disabled(model.isSyncing || !model.isConnected)

            Text("Choose a dedicated Mac calendar for your Psion. Turn off sync to change the file, calendar or time zone. Automatic sync checks for saved changes every 30 seconds while Reconnect is open and your Psion is connected. Agenda may show a save dialog on the Psion.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if model.settings.direction == .macToAgenda {
                Text("Mac Calendar → Agenda copies appointment details and the earliest supported alert. Invitation details and extra alerts stay in Mac Calendar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Recurring events are converted to Psion local time. Schedules that need different local hours are copied as individual appointments within 1980–2100.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if model.isSyncing {
                    ProgressView(model.status)
                        .controlSize(.small)
                    Button("Cancel", role: .cancel) { model.cancel() }
                } else {
                    Text(model.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sync Now") { model.syncNow() }
                    .disabled(!model.canSync)
            }
            .padding(.top, 8)
            if let lastSync = model.lastSuccessfulSync {
                LabeledContent("Last successful sync:") {
                    Text(lastSync, format: .dateTime.year().month().day().hour().minute())
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let message = model.errorMessage {
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            if let message = model.importNotice {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}
