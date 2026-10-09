# Reconnect

[![build](https://github.com/inseven/PsiMac/actions/workflows/build.yaml/badge.svg)](https://github.com/inseven/PsiMac/actions/workflows/build.yaml)

Psion connectivity for macOS.

<img width="1078" src="images/screenshot@2x.png">

## Contacts and Agenda conversion

With **Convert Files** enabled in Settings, Reconnect exports supported EPOC32 Contacts databases as vCard (`.vcf`) and Agenda files as iCalendar (`.ics`) when downloading or dragging files to another application. Names without extensions are recognized using their Psion file UIDs. Downloads retain the original binary file alongside the converted file.

**File → Convert Files for Psion…** converts iCalendar (`.ics`) and vCard (`.vcf`) files back into native ER5 files. Choose **Create new file** to generate an Agenda or Contacts file automatically from your source, or **Merge into a copy** with a downloaded existing file. New files need no empty Psion template. Set the Psion’s time zone for calendar imports. Save the result, then use **File → Upload** to transfer it to the Psion. This conversion window works without a daemon or device connection.

Merge adds entries and skips matching identifiers; it does not update existing entries. Both options save a separate file and preserve the inputs. Supported profiles are ER5 Contacts DBMS 0x100 and Agenda models 1.1.84/1.1.144. Calendar imports support events and a subset of repeat rules; to-dos and monthly repeats are currently rejected. See [conversion details and validation](macos/PsionFormats/README.md) for supported fields and limits.

## Connected Agenda sync

On a connected EPOC32 device, open the device details and use **Agenda Sync**. Allow Calendar access, enter the full Psion file path (for example `C:\Documents\Agenda`), choose or create a dedicated Mac calendar, and select the Psion's time zone. Choose **Agenda → Mac Calendar**, **Mac Calendar → Agenda**, or **Both directions**, then enable sync. **Device → Sync Agenda Now** and the **Sync Now** button run the same engine.

**Sync automatically when connected** runs an initial sync on connection, reacts to Mac Calendar changes, and checks the saved Agenda file's size and modification time every 30 seconds while the main Reconnect app is running. Sync stops on disconnect. The menu-bar app alone does not yet run Calendar sync. Turn off sync to change the file, calendar or time zone; selecting a previous pairing restores its saved mappings.

The default **Close Agenda during sync and reopen afterward** option requests a normal close of the exact Agenda instance holding that file. Reconnect waits up to 30 seconds for it to close; a save dialog may require attention on the Psion. It reopens the same file after the attempt, unless a replacement cannot be verified, in which case it leaves Agenda closed and reports the backup location. Without this option, an open file pauses sync. Other programs are not closed.

One-way sync treats the chosen source as authoritative for linked events; unrelated destination entries are retained. The first bidirectional sync pairs uniquely matching content and copies new entries from both sides. Later runs compare both sides with the last successful snapshot, including deletions. The default conflict policy pauses before writing; alternatives prefer Agenda or Mac Calendar. Interrupted runs retain mappings and the previous baseline for retry. Automatic sync pauses after an error; **Sync Now** retries it.

This first implementation supports the existing ER5 profiles and timed/all-day appointments, text/notes, location, a single relative alarm, and supported daily/weekly/yearly-by-date repeats. To-dos remain in Agenda and are not synced to Reminders. Monthly/count-based recurrences, individually edited recurring occurrences, incompatible time zones, attendees and other unsupported fields pause the run. Writing recurrence exclusions or non-Monday week starts to Mac Calendar, creating tentative status there, changing an existing native entry between repeating/non-repeating, and modifying embedded native content need further support. Dirty/delta stores and stores with deleted stream slots retain the converter's existing restrictions. Unicode outside Windows-1252 cannot be written to Agenda. Use a dedicated calendar rather than a calendar containing unsupported meeting data.

Before a native replacement, Reconnect archives the original privately under its Application Support `AgendaSync` directory. It stages and verifies the upload, rechecks the original, preserves a temporary remote `.bak` during replacement, and verifies the result. The remote backup is removed only after both sides and the saved baseline verify; failed replacements retain it for recovery. Opening, closing, reopening, replacement recovery and Calendar integration still need an end-to-end test on physical Psion hardware. Build and synthetic format/planner tests do not establish device compatibility.

## Contributing

We invite and welcome contributions! There's a pretty comprehensive list of [issues](https://github.com/inseven/reconnect/issues) to get you started, and our documentation is always in need of some care and attention.

Please recognize Reconnect is a labour of love, and be respectful of others in your communications. We will not accept racism, sexism, or any form of discrimination in our community.

## License

Reconnect is Copyright (C) 2024-2026 Jason Morley (see [COPYRIGHT](COPYRIGHT)) and is licensed under the GNU General Public License (GPL) version 2 (see [LICENSE](LICENSE)). It depends on the following separately licensed third-party libraries and components:

- [Diligence](https://github.com/inseven/diligence), MIT License
- [Glitter](https://github.com/inseven/glitter), MIT License
- [Interact](https://github.com/inseven/interact), MIT License
- [Licensable](https://github.com/inseven/licensable), MIT License
- [Lua](https://www.lua.org), MIT License
- [LuaSwift](https://github.com/tomsci/LuaSwift), MIT License
- [OpoLua](https://github.com/inseven/opolua), MIT License
- [plptools](https://github.com/rrthomas/plptools), GPL 2.0 License
- [PsionSoftwareIndexSwift](https://github.com/inseven/PsionSoftwareIndexSwift), MIT License
- [Sparkle](https://github.com/sparkle-project/Sparkle), Sparkle License
- [Swift Algorithms](https://github.com/apple/swift-algorithms), Apache 2.0 License
- [Swift Argument Parser](https://github.com/apple/swift-argument-parser), Apache 2.0 License
- [Swift Numerics](https://github.com/apple/swift-numerics), Apache 2.0 License
- [Word2Text](https://github.com/smittytone/Word2Text), MIT License

Reconnect includes graphics (icons and animations) from the original Psion PsiWin and PsiMac software. These remain copyright Psion PLC.
