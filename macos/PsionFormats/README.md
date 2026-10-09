# Psion Contacts and Agenda conversion

This Swift package implements exports used by Reconnect's Download and Drag and drop conversion settings, and native imports used by **File → Convert Files for Psion…**. It needs no Python runtime, Symbian libraries, Calendar access or Contacts access. Backups and device-to-device copies retain their existing binary behavior.

| Input | Output | Supported profile |
| --- | --- | --- |
| Contacts database (`.cdb`, or `.pbk` containing the same format) | vCard 3.0 (`.vcf`) | Permanent Store UID2 `0x10000ebe`, DBMS version `0x100`, ER5 35-field template |
| Agenda (`.agn`, or an extensionless file identified by UIDs) | iCalendar 2.0 (`.ics`) | Permanent Store, Agenda models 1.1.84/1.1.144 |
| iCalendar 2.0 (`.ics`) | Native Agenda (`.agn`) | Generated ER5 model 1.1.144 or existing supported store |
| UTF-8 vCard 3.0/4.0 (`.vcf`) | Native Contacts (`.cdb`) | Generated ER5 DBMS 0x100 database or existing supported store |

Contact names, home/work phone numbers, fax and pager numbers, email addresses, postal addresses, company, job title, website, birthday and notes are exported. Templates and groups are excluded. Custom fields use their template references and validated vCard mapping UIDs. Full field headers point to separately stored values; inherited fields point directly to values. Every byte in the field storage is accounted for.

Appointments, all-day events, anniversaries and to-dos are exported. Supported recurrence kinds are daily, weekly and yearly-by-date, including intervals, end dates and exclusions. Alarms retain the ER5 `1440 - pre_time` calculation. Times remain floating local times because the source does not provide a timezone. All-day end dates are exclusive; zero-duration appointments retain an `X-PSION-ZERO-DURATION` marker. Deleted records are omitted.

Both formats use UTF-8, escaped text, CRLF and folding at 75 bytes without splitting a Unicode scalar. The original file remains available after a download. Output is written atomically only after the entire input has been validated. Unknown or corrupt profiles report an error instead of producing a partial export.

## Importing to the Psion

Choose **Create new file**, select your ICS or vCard source and convert. Reconnect generates a complete native file automatically; an empty file from the Psion is not required. Agenda files contain the ER5 1.1.144 model, application/view settings, paragraph/font defaults and empty To-do list, Notes and Personal lists. Contacts files contain all three native DBMS tables, the standard 35-field template, preferences and the identifier index. Metadata uses fresh identifiers and creation/modification times. The structures are generated in Swift from the validated native layouts; private files are not bundled with the app. The package exposes `AgendaImporter.create` and `ContactsImporter.create` for this workflow. The existing `convert(_:using:mode:)` API also supports an explicitly supplied empty template.

Choose **Merge into a copy** to add entries to a downloaded Psion file. The writer retains existing streams, record IDs, field bytes, lists, groups and application settings. It appends new clusters, updates allocation counters and, for Contacts, rebuilds the native identifier B+tree. A new compact Permanent Store preserves live stream handles and their generation bits. The UI requires a separate output file and writes atomically after validation. Upload the result using Reconnect’s existing Upload command.

Merge is add-only: matching identifiers are skipped, including repeated IDs in the input. Changed records with the same identifier do not replace existing data. Agenda imports store a 32-byte hash of the incoming UID in the native global-ID field; exported native global IDs are retained. Exporting the selected base Agenda and merging that export back also skips its matching native entry IDs. Contacts retain native exported GUIDs or hash external UIDs; cards without a UID use their content as identity. Name similarity is not used to identify duplicates.

Calendar import accepts timed and all-day VEVENTs, yearly anniversaries exported with Psion metadata, daily/weekly/yearly-by-date repeats, INTERVAL, UNTIL, date exclusions and one DISPLAY alarm relative to DTSTART. Text and LOCATION are retained; DESCRIPTION is appended to the Agenda entry text. Select the Psion’s time zone: UTC and recognized named-zone times are converted to local time, floating times remain unchanged, and all-day dates remain calendar dates. Times and alarms must have whole-minute precision. Calendar recurrence requiring time-zone conversion is rejected to avoid changing its meaning across daylight-saving transitions.

Contact import accepts structured names and formatted names, home/work telephone, cellular, fax and pager numbers, emails, postal addresses, company, job title, website, complete birthdays and notes. A formatted name that differs from the structured name is retained in the display-name field. Organization components are joined as separate lines. vCard groups are accepted; their grouping and preference metadata have no native mapping. Multiple addresses of the same type retain their components as repeated native fields. Native export combines those components with newlines.

## Limits

The conversion APIs perform file conversion. The separate `AgendaSyncDocument` API exposes stable, file-scoped event identities and explicit native upserts/deletions; `AgendaSyncPlanner` performs three-way reconciliation without Calendar or device access. The connected application's EventKit and transport services coordinate actual synchronization; see the [connected sync workflow and limits](../../README.md#connected-agenda-sync). The `.pbk` suffix does not imply support for every Psion phonebook format; the contained format must match the supported Contacts profile. EPOC16 Agenda and Data files are not supported. Other database versions or contact templates need additional fixtures.

Imports reject VTODO, VTIMEZONE definitions, monthly/yearly-by-day repeats, COUNT/RDATE, scheduling messages, attendees, attachments, photos, binary fields, unsupported standard properties and text outside Windows-1252. Vendor X-properties without a native mapping are metadata and are ignored. Unsupported standard fields stop the entire conversion before saving. Contacts imports require the validated `cnt_id_index` schema. Native writing currently requires contiguous live stream slots; files with deleted stream slots need to be compacted on the Psion first. Inputs are limited to 16 MiB of interchange data and 64 MiB of native data. Agenda dates must fall within 1980–2100.

Agenda rich text is reduced to readable text. Formatting, embedded Word/sketch objects, attendee lists, and some Psion display/replication metadata have no export mapping. Embedded-text entries carry an `X-PSION-EMBEDDED-TEXT` marker; the original database preserves their complete content. Monthly and yearly-by-day recurrence, recurring to-dos, other Agenda model versions, unsupported inline rich text, dirty/relocating stores, and delta tables of contents are rejected. Only the validated 8-bit CP1252 text descriptors are supported.

## Evidence and validation

The Agenda implementation ports the validated decoder and report in the user's `Documents/ChatGPT/Psion_Converter_Handoff-2`. That report supersedes the earlier generic Direct Store description: both supplied samples are Permanent Stores. Store framing and DBMS structure were also checked against the original Symbian [Permanent Store sources](https://github.com/SymbianSource/oss.FCL.sf.os.persistentdata/tree/master/persistentstorage/store) and [DBMS sources](https://github.com/SymbianSource/oss.FCL.sf.os.persistentdata/tree/master/persistentstorage/dbms/ustor). Contacts field/value boundaries and mappings were checked against the supplied `Contacts.cdb`, rather than using the approximate field UID list in the earlier notes.

The private samples produce 526 vCards and 239 calendar entries (236 VEVENTs, 3 VTODOs), with five alarms. Apple's vCard parser validates the contact export. Independent `icalendar` parsing confirms that every event, to-do and alarm matches the previous validated export; `python-dateutil` confirms the recurrence exclusions. Synthetic tests exercise a recurring Tuesday meeting at 14:00 with a 15-minute alarm, Unicode contact names, escaping, field mappings, deleted entries and unsupported profiles. Additional checks cover checksums, truncation and UTF-8 folding. The private source files and exported personal data are never committed.

Run the public tests from the repository root:

```sh
swift test --package-path macos/PsionFormats
```

To include the two private fixture checks, explicitly supply the directory containing `Contacts.cdb` and `Agenda.agn`:

```sh
PSION_FIXTURE_DIRECTORY=/path/to/private/DataFiles swift test --package-path macos/PsionFormats
```

The optional `PSION_EXPORT_DIRECTORY` test variable saves fixture exports to an existing directory for independent validation. Keep that directory outside the repository.

Native import tests use invented public data plus optional private empty/single-entry files:

```sh
PSION_IMPORT_FIXTURE_DIRECTORY=/path/to/templates \
PSION_FIXTURE_DIRECTORY=/path/to/private/DataFiles \
swift test --package-path macos/PsionFormats
```

The templates directory contains `emptyagenda`, `singleagenda`, `NoContacts.cdb` and `1Contacts 2.cdb`. `PSION_IMPORT_EXPORT_DIRECTORY` optionally writes two small native test files outside the repository. Tests cover create/merge, preserved existing streams, duplicate identifiers, byte framing at 16 KiB boundaries, UTC conversion, repeats/exclusions/alarms, malformed or unsupported input, Apple vCard parsing and a 4,200-contact index with multiple tree levels. The native writers were checked against the supplied ER5 files and the original Symbian DBMS/B+tree/page-pool sources. Opening and editing the generated files on physical Psion hardware remains a separate validation step.

Automatic creation also runs without private fixtures. Tests validate generated defaults, fresh template GUIDs, creation times, source-to-native-to-export round trips and subsequent merges. When private fixtures are supplied, the generated schema, complete Contacts field template/index and unchanged Agenda settings are compared byte-for-byte with the native empty files. `PSION_IMPORT_EXPORT_DIRECTORY` additionally saves `Reconnect-auto-agenda.agn` and `Reconnect-auto-contacts.cdb` for device checks.

Independent Python validation of the generated test files checks the Agenda event’s date, times, location and global ID with the supplied handoff decoder (allowing the native 1.1.144 profile). It also checks the Contacts index page and its references to the template and imported record.
