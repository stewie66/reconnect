# Psion Contacts and Agenda export

This Swift package implements the outbound conversions used by Reconnect's existing Download and Drag and drop conversion settings. It needs no Python runtime, Symbian libraries, Calendar access or Contacts access. Backups and device-to-device copies retain their existing binary behavior.

| Input | Output | Supported profile |
| --- | --- | --- |
| Contacts database (`.cdb`, or `.pbk` containing the same format) | vCard 3.0 (`.vcf`) | Permanent Store UID2 `0x10000ebe`, DBMS version `0x100`, ER5 35-field template |
| Agenda (`.agn`, or an extensionless file identified by UIDs) | iCalendar 2.0 (`.ics`) | Permanent Store, Agenda model 1.1.84 |

Contact names, home/work phone numbers, fax and pager numbers, email addresses, postal addresses, company, job title, website, birthday and notes are exported. Templates and groups are excluded. Custom fields use their template references and validated vCard mapping UIDs. Full field headers point to separately stored values; inherited fields point directly to values. Every byte in the field storage is accounted for.

Appointments, all-day events, anniversaries and to-dos are exported. Supported recurrence kinds are daily, weekly and yearly-by-date, including intervals, end dates and exclusions. Alarms retain the ER5 `1440 - pre_time` calculation. Times remain floating local times because the source does not provide a timezone. All-day end dates are exclusive; zero-duration appointments retain an `X-PSION-ZERO-DURATION` marker. Deleted records are omitted.

Both formats use UTF-8, escaped text, CRLF and folding at 75 bytes without splitting a Unicode scalar. The original file remains available after a download. Output is written atomically only after the entire input has been validated. Unknown or corrupt profiles report an error instead of producing a partial export.

## Limits

This is an outbound exporter, not synchronization or a binary writer. The `.pbk` suffix does not imply support for every Psion phonebook format; the contained format must match the supported Contacts profile. EPOC16 Agenda and Data files are not supported. Other database versions or contact templates need additional fixtures.

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
