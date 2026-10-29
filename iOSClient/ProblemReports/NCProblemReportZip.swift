// SPDX-FileCopyrightText: 2026 Nourax
// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import Foundation

/// A small ZIP writer for the problem report. The entries sit at the root of the archive (`report.json`,
/// `crash.txt`, `logs/...`); `NSFileCoordinator`'s zipping puts everything under a top-level folder, which the
/// contract does not want. Each entry is raw DEFLATE (Apple's Compression, `COMPRESSION_ZLIB` = RFC 1951) or
/// stored when deflate does not make it smaller. Sizes stay far below 4 GB (a report is at most 5 MB), so no ZIP64.
enum NCProblemReportZip {
    struct Entry {
        let name: String
        let data: Data
    }

    /// The CRC-32 of the ZIP format (the polynomial 0xEDB88320).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// Raw DEFLATE of `data`, or nil when it does not become smaller.
    static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + data.count / 8 + 1024
        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { destination.deallocate() }
        let written = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0, written < data.count else { return nil }
        return Data(bytes: destination, count: written)
    }

    /// The ZIP archive of `entries`, with `date` (UTC) as the time of every entry.
    static func archive(_ entries: [Entry], date: Date = Date()) -> Data {
        let (dosTime, dosDate) = dosDateTime(date)
        var output = Data()
        var central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let packed = deflate(entry.data)
            let payload = packed ?? entry.data
            let method: UInt16 = packed == nil ? 0 : 8
            let offset = UInt32(output.count)

            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))              // version needed
            output.appendLE(UInt16(0x0800))          // flags: UTF-8 names
            output.appendLE(method)
            output.appendLE(dosTime)
            output.appendLE(dosDate)
            output.appendLE(crc)
            output.appendLE(UInt32(payload.count))
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))               // extra field length
            output.append(name)
            output.append(payload)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(UInt16(0x031E))         // made by: Unix, ZIP 3.0
            central.appendLE(UInt16(20))
            central.appendLE(UInt16(0x0800))
            central.appendLE(method)
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(UInt32(payload.count))
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))              // extra
            central.appendLE(UInt16(0))              // comment
            central.appendLE(UInt16(0))              // disk
            central.appendLE(UInt16(0))              // internal attributes
            central.appendLE(UInt32(0o100644 << 16)) // external attributes: a regular file, rw-r--r--
            central.appendLE(offset)
            central.append(name)
        }
        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(centralOffset)
        output.appendLE(UInt16(0))                   // comment length
        return output
    }

    /// MS-DOS time and date of `date` in UTC (the format has a 2-second step and starts in 1980).
    static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max((parts.year ?? 1980) - 1980, 0)
        let time = ((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2)
        let day = (year << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1)
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: day))
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
