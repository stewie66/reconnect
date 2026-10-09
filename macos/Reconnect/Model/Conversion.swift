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
import Word2text
import PsionFormats

struct Conversion {

    let filename: (FileServer.DirectoryEntry) -> String
    let perform: (URL, URL) throws -> URL

}

extension Conversion {

    static let none: Self = Self { entry in
        return entry.name
    } perform: { sourceURL, destinationURL in
        return sourceURL
    }

    static let mbmConversion: Self = Self { entry in
        return entry.name.replacingPathExtension("tiff")
    } perform: { sourceURL, destinationURL in
        let outputURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent.deletingPathExtension,
                                                              conformingTo: .tiff)
        try PsiLuaEnv().convertMultiBitmap(sourceURL: sourceURL, destinationURL: outputURL)
        try FileManager.default.removeItem(at: sourceURL)
        return outputURL
    }

    static let wordConversion: Self = Self { entry in
        return entry.name.replacingPathExtension("txt")
    } perform: { sourceURL, destinationURL in
        let outputURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent.deletingPathExtension,
                                                              conformingTo: .plainText)
        let data = try Data(contentsOf: sourceURL)
        let output = try PsionWord.processFile(data).get()
        try output.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    static let textConversion: Self = Self { entry in
        return entry.name
    } perform: { sourceURL, destinationURL in
        let data = try Data(contentsOf: sourceURL)
        guard let contents = String(data: data, encoding: .ascii) else {
            throw ReconnectError.unknown
        }
        let output = contents.replacingOccurrences(of: "\r\n", with: "\n")
        try output.write(to: sourceURL, atomically: true, encoding: .utf8)
        return sourceURL
    }

    static let picConversion: Self = Self { entry in
        return entry.name.replacingPathExtension("png")
    } perform: { sourceURL, destinationURL in
        let outputURL = destinationURL.appendingPathComponent(sourceURL.lastPathComponent.deletingPathExtension,
                                                              conformingTo: .png)
        try PsiLuaEnv().convertPicToPNG(sourceURL: sourceURL, destinationURL: outputURL)
        try FileManager.default.removeItem(at: sourceURL)
        return outputURL
    }

    static let contactsConversion: Self = Self { entry in
        interchangeFilename(for: entry.name, pathExtension: "vcf")
    } perform: { sourceURL, destinationURL in
        let outputURL = destinationURL.appendingPathComponent(interchangeFilename(for: sourceURL.lastPathComponent, pathExtension: "vcf"))
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        let accessingDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            if accessingDestination { destinationURL.stopAccessingSecurityScopedResource() }
        }
        let output = try ContactsConverter.convert(Data(contentsOf: sourceURL))
        try output.write(to: outputURL, options: .atomic)
        return outputURL
    }

    static let agendaConversion: Self = Self { entry in
        interchangeFilename(for: entry.name, pathExtension: "ics")
    } perform: { sourceURL, destinationURL in
        let outputURL = destinationURL.appendingPathComponent(interchangeFilename(for: sourceURL.lastPathComponent, pathExtension: "ics"))
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        let accessingDestination = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            if accessingDestination { destinationURL.stopAccessingSecurityScopedResource() }
        }
        let output = try AgendaConverter.convert(Data(contentsOf: sourceURL))
        try output.write(to: outputURL, options: .atomic)
        return outputURL
    }

    private static func interchangeFilename(for name: String, pathExtension: String) -> String {
        let convertedName = name.replacingPathExtension(pathExtension)
        // A binary file can already have the export suffix. Preserve it on case-insensitive volumes too.
        guard convertedName.lowercased() == name.lowercased() else { return convertedName }
        return name.deletingPathExtension + " (Converted)." + pathExtension
    }

}
