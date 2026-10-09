import Foundation

// ER5 DBMS unique Uint32 index, using Symbian's inline B+tree page layout.
// Leaf records are (record ID, CM_Identifier); internal pivots are the left child's maximum key.
enum ContactImportIndex {
    struct Entry: Equatable {
        var recordID: UInt32
        var contactID: UInt32
    }

    static func validate(_ token: [UInt8], entries: [Entry], store: PermanentStore) throws {
        var reader = BinaryReader(token)
        let first = try reader.u32(), root = try reader.u32(), height = try reader.u8()
        try require((1...8).contains(height), "invalid Contacts index height")
        var visited: Set<UInt32> = [], leaves: [(UInt32, UInt32)] = []
        func walk(_ reference: UInt32, level: UInt8) throws -> [Entry] {
            try require(visited.insert(reference).inserted, "cycle in Contacts index")
            let bytes = try store.get(reference >> 4)
            let offset = reference & 15 == 0 ? 0 : 4 + (Int(reference & 15) - 1) * 512
            var page = BinaryReader(bytes, position: offset)
            let count = Int(try page.u32())
            try require(count <= 63 && offset + 512 <= bytes.count, "invalid Contacts index page")
            if level == 1 {
                leaves.append((reference, try page.u32()))
                var result: [Entry] = []
                for _ in 0..<count { result.append(Entry(recordID: try page.u32(), contactID: try page.u32())) }
                return result
            }
            var result: [Entry] = []
            for index in 0...count {
                let child = try page.u32()
                let records = try walk(child, level: level - 1)
                result += records
                if index < count { try require(try page.u32() == records.last?.contactID, "invalid Contacts index pivot") }
            }
            return result
        }
        let actual = try walk(root, level: height)
        let expected = entries.sorted { $0.contactID < $1.contactID }
        try require(actual == expected && leaves.first?.0 == first, "Contacts index does not match its records")
        for index in leaves.indices {
            try require(leaves[index].1 == (index + 1 < leaves.count ? leaves[index + 1].0 : 0), "invalid Contacts leaf chain")
        }
    }

    static func write(_ entries: [Entry], store: inout PermanentStore) throws -> [UInt8] {
        let sorted = entries.sorted { $0.contactID < $1.contactID }
        try require(!sorted.isEmpty, "empty Contacts index")
        struct Node { var reference: UInt32; var maximum: UInt32 }
        func ranges(_ count: Int, maximum: Int) -> [Range<Int>] {
            let groups = (count + maximum - 1) / maximum
            var offset = 0
            return (0..<groups).map { index in
                let size = count / groups + (index < count % groups ? 1 : 0)
                defer { offset += size }
                return offset..<offset + size
            }
        }
        let batches = ranges(sorted.count, maximum: 63)
        var nodes: [Node] = []
        for batch in batches {
            let id = try store.add([])
            nodes.append(Node(reference: id << 4, maximum: sorted[batch.upperBound - 1].contactID))
        }
        for (index, batch) in batches.enumerated() {
            var page = BinaryWriter()
            page.u32(UInt32(batch.count)); page.u32(index + 1 < nodes.count ? nodes[index + 1].reference : 0)
            for entry in sorted[batch] { page.u32(entry.recordID); page.u32(entry.contactID) }
            page.bytes += Array(repeating: 0, count: 512 - page.bytes.count)
            store.streams[nodes[index].reference >> 4] = page.bytes
        }
        let first = nodes[0].reference
        var height: UInt8 = 1
        while nodes.count > 1 {
            var parents: [Node] = []
            for batch in ranges(nodes.count, maximum: 64) {
                var page = BinaryWriter()
                page.u32(UInt32(batch.count - 1))
                for index in batch {
                    page.u32(nodes[index].reference)
                    if index + 1 < batch.upperBound { page.u32(nodes[index].maximum) }
                }
                page.bytes += Array(repeating: 0, count: 512 - page.bytes.count)
                let id = try store.add(page.bytes)
                parents.append(Node(reference: id << 4, maximum: nodes[batch.upperBound - 1].maximum))
            }
            nodes = parents; height += 1
        }
        var token = BinaryWriter()
        token.u32(first); token.u32(nodes[0].reference); token.u8(height)
        try token.cardinal(sorted.count)
        token.u32(0x41) // valid, discrete statistics; refresh after the next change
        for value in [Double(sorted.first!.contactID), Double(sorted.last!.contactID)] {
            token.u32(UInt32(truncatingIfNeeded: value.bitPattern)); token.u32(UInt32(value.bitPattern >> 32))
        }
        try validate(token.bytes, entries: sorted, store: store)
        return token.bytes
    }
}
