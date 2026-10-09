import SwiftUI
import PsionFormats

struct PsionImportView: View {
    @State private var model = PsionImportModel()

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("Convert calendar events and contacts into ER5 Psion files.")
                        .foregroundStyle(.secondary)
                    Picker("Format", selection: $model.format) {
                        Text("Agenda from iCalendar (.ics)").tag(PsionImportModel.Format.agenda)
                        Text("Contacts from vCard (.vcf)").tag(PsionImportModel.Format.contacts)
                    }
                    PsionImportFileRow(title: "Source file", url: model.sourceURL) { model.chooseSource() }
                }
                Section {
                    Picker("Save as", selection: $model.mode) {
                        Text("Create new file").tag(PsionImportMode.createNew)
                        Text("Merge into a copy").tag(PsionImportMode.merge)
                    }
                    .pickerStyle(.segmented)
                    if model.mode == .createNew {
                        Text("Reconnect creates a new Psion file from your source, ready to upload.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text("Choose a downloaded Psion file. Import adds entries to a separate copy and skips matching identifiers. It does not update existing entries.")
                            .font(.callout).foregroundStyle(.secondary)
                        PsionImportFileRow(title: "Existing Psion file", url: model.baseURL) { model.chooseBase() }
                    }
                    if model.format == .agenda {
                        Picker("Psion time zone", selection: $model.timeZoneIdentifier) {
                            ForEach(model.timeZoneIdentifiers, id: \.self) { identifier in
                                Text(verbatim: identifier).tag(identifier)
                            }
                        }
                        Text("Set this to the Psion’s time zone. UTC and named-zone events are converted to its local time; floating times stay as supplied.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("Supported imports") {
                        Text("Agenda: timed and all-day events, yearly anniversaries, daily/weekly/yearly-by-date repeats, exclusions and one display alarm. To-dos, custom time-zone definitions, monthly repeats, attachments and attendees are not supported.")
                        Text("Contacts: UTF-8 vCard 3.0/4.0 names, home/work phone numbers, emails, addresses, company, title, website, complete birthdays and notes. Photos and custom fields are not supported.")
                        Text("Psion text must fit Windows-1252. Vendor metadata, formatting and field preferences are omitted. Unsupported standard fields report an error before a file is saved.")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    if let status = model.status {
                        Text(verbatim: status).textSelection(.enabled)
                            .accessibilityLabel("Conversion result: " + status)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isConverting)
            Divider()
            HStack {
                if model.isConverting { ProgressView().controlSize(.small); Text("Converting…").foregroundStyle(.secondary) }
                Spacer()
                Button("Convert and Save…") { Task { await model.convert() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canConvert)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 480)
        .alert("Conversion Failed", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(verbatim: model.errorMessage ?? "") }
    }
}

private struct PsionImportFileRow: View {
    var title: LocalizedStringKey
    var url: URL?
    var choose: () -> Void

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(verbatim: url?.lastPathComponent ?? "No file selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(url?.path ?? "Choose a file")
                Button("Choose…", action: choose)
                    .accessibilityLabel(Text(title))
            }
        }
    }
}
