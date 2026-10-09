// Reconnect -- Psion connectivity for macOS
//
// Copyright (C) 2024-2026 Jason Morley
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 2 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

import SwiftUI

import OpoLuaCore

import ReconnectCore

enum FileType: String, Identifiable {

    var id: Self {
        return self
    }

    case mbm
    case word
    case text
    case markdown
    case pic
    case contacts
    case agenda

}

extension FileType {

    var localizedDescription: LocalizedStringKey {
        switch self {
        case .mbm:
            return "Multiple Bitmap Image (.mbm)"
        case .word:
            return "EPOC16 Word (.wrd)"
        case .text:
            return "Text (.txt)"
        case .markdown:
            return "Markdown (.md)"
        case .pic:
            return "EPOC16 Image (.pic)"
        case .contacts:
            return "EPOC32 Contacts (.cdb, .pbk)"
        case .agenda:
            return "EPOC32 Agenda (.agn)"
        }
    }

}

extension FileType {

    func matches(directoryEntry: FileServer.DirectoryEntry) -> Bool {
        guard !directoryEntry.isDirectory else { return false }
        switch self {
        case .mbm:
            return directoryEntry.fileType == .mbm || directoryEntry.pathExtension.lowercased() == "mbm"
        case .word:
            return directoryEntry.pathExtension.lowercased() == "wrd"
        case .text:
            return directoryEntry.pathExtension.lowercased() == "txt"
        case .markdown:
            return directoryEntry.pathExtension.lowercased() == "md"
        case .pic:
            return directoryEntry.pathExtension.lowercased() == "pic"
        case .contacts:
            return directoryEntry.fileType == .contacts || ["cdb", "pbk"].contains(directoryEntry.pathExtension.lowercased())
        case .agenda:
            return directoryEntry.fileType == .agenda || directoryEntry.pathExtension.lowercased() == "agn"
        }
    }

}

enum ConversionIdentifier: String {

    case none
    case mbmToTiff
    case wordToText
    case windowsAsciiToUnixUnicode
    case picToPng
    case contactsToVCard
    case agendaToICalendar

}

extension ConversionIdentifier {

    fileprivate var conversion: Conversion {
        switch self {
        case .none:
            return .none
        case .mbmToTiff:
            return .mbmConversion
        case .wordToText:
            return .wordConversion
        case .windowsAsciiToUnixUnicode:
            return .textConversion
        case .picToPng:
            return .picConversion
        case .contactsToVCard:
            return .contactsConversion
        case .agendaToICalendar:
            return .agendaConversion
        }
    }

    // TODO: Move this into the conversion?
    var localizedDescription: LocalizedStringKey {
        switch self {
        case .none:
            return "None"
        case .mbmToTiff:
            return "TIFF"
        case .wordToText:
            return "Text"
        case .windowsAsciiToUnixUnicode:
            return "UTF8 with Unix Line Endings"
        case .picToPng:
            return "PNG"
        case .contactsToVCard:
            return "vCard (.vcf)"
        case .agendaToICalendar:
            return "iCalendar (.ics)"
        }
    }

}

// This is expected to grow into some kind of engine / model for managing file conversions and giving in the moment
// answers about conversions based on the users choices and enabled conversions.
class FileConverter {

    static let convertFiles: (FileServer.DirectoryEntry, URL) throws -> URL = { entry, url in
        guard let converter = converter(for: entry) else {
            return url
        }
        return try converter.perform(url, url.deletingLastPathComponent())
    }

    static let identity: (FileServer.DirectoryEntry, URL) throws -> URL = { entry, url in
        return url
    }

    static let converters: [FileType: ConversionIdentifier] = [
        .mbm: .mbmToTiff,
        .word: .wordToText,
        .text: .windowsAsciiToUnixUnicode,
        .markdown: .windowsAsciiToUnixUnicode,
        .pic: .picToPng,
        .contacts: .contactsToVCard,
        .agenda: .agendaToICalendar,
    ]

    private static func converter(for directoryEntry: FileServer.DirectoryEntry) -> Conversion? {
        // Psion UIDs identify extensionless files and take precedence over an arbitrary filename suffix.
        switch directoryEntry.fileType {
        case .contacts: return .contactsConversion
        case .agenda: return .agendaConversion
        default: break
        }
        return converters.first {
            $0.key.matches(directoryEntry: directoryEntry)
        }?.value.conversion
    }

    static func targetFilename(for directoryEntry: FileServer.DirectoryEntry) -> String {
        return converter(for: directoryEntry)?.filename(directoryEntry) ?? directoryEntry.name
    }

}
