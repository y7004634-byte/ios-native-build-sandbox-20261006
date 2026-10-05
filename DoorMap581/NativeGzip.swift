import Foundation
import zlib

enum NativeGzip {
    enum Failure: Error { case invalid, tooLarge }

    static func decode(_ input: Data, maximumBytes: Int = 64 * 1024 * 1024) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
        defer { inflateEnd(&stream) }
        return try input.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw Failure.invalid }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            var output = Data(), block = [UInt8](repeating: 0, count: 65536), status = Z_OK
            while status == Z_OK {
                let written = block.withUnsafeMutableBytes { buffer -> Int in
                    stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(buffer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return buffer.count - Int(stream.avail_out)
                }
                guard output.count + written <= maximumBytes else { throw Failure.tooLarge }
                output.append(contentsOf: block.prefix(written))
            }
            guard status == Z_STREAM_END else { throw Failure.invalid }
            return output
        }
    }

    /// Byte-for-byte format used by the accepted build8 compressor:
    /// gzip level6, mtime=0, XFL=0, OS=255. Raw DEFLATE is wrapped manually
    /// so Darwin/zlib platform metadata can never change the trusted hash.
    static func encodeDeterministic(_ input: Data, maximumBytes: Int = 128 * 1024 * 1024) throws -> Data {
        guard input.count <= maximumBytes, input.count <= Int(UInt32.max) else { throw Failure.tooLarge }
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw Failure.invalid }
        defer { deflateEnd(&stream) }
        var compressed = Data()
        let status: Int32 = try input.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress {
                stream.next_in = UnsafeMutablePointer<Bytef>(mutating: base.assumingMemoryBound(to: Bytef.self))
            }
            stream.avail_in = uInt(input.count)
            var block = [UInt8](repeating: 0, count: 65536), result = Z_OK
            repeat {
                let written = block.withUnsafeMutableBytes { buffer -> Int in
                    stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(buffer.count)
                    result = deflate(&stream, Z_FINISH)
                    return buffer.count - Int(stream.avail_out)
                }
                guard compressed.count + written <= maximumBytes else { throw Failure.tooLarge }
                compressed.append(contentsOf: block.prefix(written))
            } while result == Z_OK
            return result
        }
        guard status == Z_STREAM_END else { throw Failure.invalid }
        var output = Data([0x1f,0x8b,0x08,0x00,0x00,0x00,0x00,0x00,0x00,0xff])
        output.append(compressed)
        let crc: UInt32 = input.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return UInt32(0) }
            return UInt32(crc32(0, base.assumingMemoryBound(to: Bytef.self), uInt(input.count)))
        }
        func appendLE(_ value: UInt32) {
            output.append(UInt8(value & 0xff)); output.append(UInt8((value >> 8) & 0xff))
            output.append(UInt8((value >> 16) & 0xff)); output.append(UInt8((value >> 24) & 0xff))
        }
        appendLE(crc); appendLE(UInt32(truncatingIfNeeded: input.count))
        return output
    }
}
