import Foundation

// Default ER5 model 1.1.144 store. The native empty-file fixture supplies the
// application settings layout; records and dated list metadata are generated here.
enum EmptyAgendaStore {
    static func create(timeZone: TimeZone, timestamp: Date) throws -> Data {
        let modified = try CalendarImportDate.from(timestamp, timeZone: timeZone)
        var streams: [UInt32: [UInt8]] = [
            2: [0], 3: [0], 5: BinaryWriter.integer(4), 6: [0],
            7: [0, 0, 0, 0, 0, 0, 0, 128], 8: Array(repeating: 0, count: 12),
        ]
        var lists = BinaryWriter()
        try lists.cardinal(3)
        for id: UInt32 in [10, 11, 12] { lists.u32(id) }
        streams[1] = lists.bytes
        var model = BinaryWriter()
        model.append([1, 1, 144, 0])
        for reference: UInt32 in 1...8 { model.u32(reference) }
        streams[9] = model.bytes
        let defaults: [(UInt32, UInt32, String, String)] = [
            (10, 2, "To-do list", "0201680100010000000020000000000d021a4368696d65730000000000"),
            (11, 3, "Notes", "0001680100000000000054000000000d021a4368696d65730000000000"),
            (12, 4, "Personal", "0001680100000000000054000000000d021a4368696d65730000000000"),
        ]
        for (streamID, uniqueID, name, settings) in defaults {
            var list = BinaryWriter()
            list.u8(0); list.u32(streamID); list.u32(uniqueID)
            try list.descriptor(name)
            list.append(try bytes(settings))
            list.u16(UInt16(modified.day)); list.u16(UInt16(modified.minute ?? 0))
            streams[streamID] = list.bytes
        }
        // Native paragraph/font defaults, view preferences, alarm preferences,
        // print setup and colours. These contain no event text or file identities.
        let settings: [UInt32: String] = [
            4: "0900000001ffffff075000000011000000190000001cb40000002206417269616c00",
            13: "0165040000bf01000000000000010101680148033c000101480364053c000101",
            14: "01e8030000bf01000000000000",
            15: "0330a0e3a1010000001c02fc03a401ec040101",
            16: "af0100000002000000",
            17: "01e8030000a8010000000201a8010000",
            18: "0165040000b0010000",
            19: "014500000000000000000d021a4368696d65736801000000000000114100000000000000000d021a4368696d65736801000000104400000000000000000f001a4368696d65730000000d021a4368696d65731c0200003c00000068010000001a4368696d6573000000a5c3acfcdd0000c06f5a748deb00e8030000ff010000004500010132000500c020a316eedf0000005e2272f0df00ff0100000041",
            20: "140000000100000000000000010000000000000001000000d0020000d0020000a0050000a0050000a0050000a0050000010000000000000000000000005c000010630000100400000065000010000000006600001000000000640000100206010000000000000000000000005c000010630000100c00000065000010000000006600001000000000640000100206fd000010822e0000c641000000",
            21: "000000ffffff000000ff0000",
        ]
        for (id, value) in settings { streams[id] = try bytes(value) }
        var identifier = BinaryWriter()
        identifier.u32(0x10000084); try identifier.descriptor("Agenda.app")
        streams[22] = identifier.bytes
        let dictionary: [(UInt32, UInt32)] = [
            (0x100000f1, 9), (0x10000230, 13), (0x10000231, 14), (0x10000c5f, 15),
            (0x10000232, 16), (0x10000234, 17), (0x10000233, 18), (0x10000235, 19),
            (0x1000010d, 20), (0x10004d24, 21), (0x10000089, 22),
        ]
        var root = BinaryWriter()
        try root.cardinal(dictionary.count)
        for (key, reference) in dictionary { root.u32(key); root.u32(reference) }
        streams[23] = root.bytes
        let data = try PermanentStore(uids: [0x10000050, 0x1000006d, 0x10000084], root: 23, streams: streams).encoded()
        _ = try AgendaConverter.convert(data, timestamp: timestamp)
        return data
    }

    private static func bytes(_ text: String) throws -> [UInt8] {
        try require(text.utf8.count % 2 == 0, "invalid default Agenda settings")
        var result: [UInt8] = []
        var position = text.startIndex
        while position < text.endIndex {
            let end = text.index(position, offsetBy: 2)
            guard let byte = UInt8(text[position..<end], radix: 16) else {
                throw PsionConversionError.invalid("invalid default Agenda settings")
            }
            result.append(byte); position = end
        }
        return result
    }
}
