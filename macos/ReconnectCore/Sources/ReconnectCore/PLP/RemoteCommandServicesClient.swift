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

import Foundation
import PsionSession

import plptools

public class RemoteCommandServicesClient {

    public typealias MachineType = RPCS.machs
    public typealias MachineInfo = RPCS.machineInfo

    private let host: String
    private let port: Int32
    private let deviceEncoding: StringEncoding

    private let workQueue = DispatchQueue(label: "RemoteCommandServicesClient.workQueue")

    private var client = RPCSClient()
    private var agendaSession: OpaquePointer?

    deinit {
        if let agendaSession { psion_session_close(agendaSession) }
    }

    private func withAgendaSession<T>(_ action: (OpaquePointer) throws -> T) throws -> T {
        try workQueue.sync {
            if agendaSession == nil { agendaSession = psion_session_open(host, port) }
            guard let agendaSession else { throw ReconnectError.unknown }
            do { return try action(agendaSession) }
            catch {
                psion_session_close(agendaSession)
                self.agendaSession = nil
                throw error
            }
        }
    }

    public func processUsingFile(path: String) throws -> String? {
        try withAgendaSession { session in
            var buffer = [CChar](repeating: 0, count: 1024)
            let result = psion_file_owner(session, path.cString(using: deviceEncoding), &buffer, buffer.count)
            if result == Int32(PLPToolsError.E_PSI_FILE_NXIST.rawValue) { return nil }
            try checkCommand(result)
            let value = String(cString: buffer, encoding: deviceEncoding) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    public func executableForProcess(_ process: String) throws -> String {
        try withAgendaSession { session in
            var buffer = [CChar](repeating: 0, count: 1024)
            try checkCommand(psion_program_details(session, process.cString(using: deviceEncoding), &buffer, buffer.count))
            guard let value = String(cString: buffer, encoding: deviceEncoding), !value.isEmpty else { throw ReconnectError.unknown }
            return value
        }
    }

    public func requestCloseProcess(_ process: String) throws {
        try withAgendaSession { session in
            try checkCommand(psion_stop_program(session, process.cString(using: deviceEncoding)))
        }
    }

    public func isProcessRunning(_ process: String) throws -> Bool {
        try withAgendaSession { session in
            let result = psion_program_running(session, process.cString(using: deviceEncoding))
            if result == Int32(PLPToolsError.E_PSI_FILE_NXIST.rawValue) { return false }
            try checkCommand(result)
            return true
        }
    }

    private func checkCommand(_ result: Int32) throws {
        guard result == 0 else {
            throw NSError(domain: "Reconnect.PsionCommand", code: Int(result),
                          userInfo: [NSLocalizedDescriptionKey: "The Psion command failed (\(result))."])
        }
    }

    public init(host: String = "127.0.0.1", port: Int32, deviceEncoding: StringEncoding) {
        self.host = host
        self.port = port
        self.deviceEncoding = deviceEncoding
    }

    private func workQueue_connect<T>(perform: (inout RPCSClient) throws -> T) throws -> T {
        guard self.client.connect(self.host, self.port) else {
            throw ReconnectError.unknown
        }
        return try perform(&client)
    }

    private func withClient<T>(perform: (inout RPCSClient) throws -> T) throws -> T {
        dispatchPrecondition(condition: .notOnQueue(workQueue))
        return try workQueue.sync {
            return try self.workQueue_connect(perform: perform)
        }
    }

    public func getMachineType() throws -> MachineType {
        return try withClient { client in
            var machs: MachineType = .PSI_MACH_UNKNOWN
            try client.getMachineType(&machs).check()
            return machs
        }
    }

    public func getMachineInfo() throws -> MachineInfo {
        return try withClient { client in
            var machineInfo = RPCS.machineInfo()
            try client.getMachineInfo(&machineInfo).check()
            return machineInfo
        }
    }

    public func getOwnerInfo() throws -> [String] {
        return try withClient { client in
            var buf: BufferArray = BufferArray()
            try client.getOwnerInfo(&buf).check()
            var ownerInfo = [String]()
            while !buf.empty() {
                let data = Data(store: buf.pop())
                let line = data.withUnsafeBytes { bytes in
                    return String(cString: bytes.bindMemory(to: CChar.self).baseAddress!, encoding: deviceEncoding)!
                }
                ownerInfo.append(line)
            }
            return ownerInfo
        }
    }

    public func execProgram(program: String, args: String = "") throws {
        return try withClient { client in
            try client.execProgram(program, args).check()
        }
    }

    public func stopPrograms() throws {
        return try withClient { client in
            try client.stopPrograms().check()
        }
    }

}


extension Data {

    init(store: BufferStore) {
        var bytes: [UInt8] = []
        for i in 0..<store.getLen() {
            bytes.append(store.getByte(Int(i)))
        }
        self.init(bytes)
    }

}
