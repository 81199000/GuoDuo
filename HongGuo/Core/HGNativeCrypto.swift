import Foundation
import CryptoKit
import CommonCrypto
import Compression

/// JS 核心需要的底层原语：摘要、AES、gzip。与安卓版 Native 桥同名同语义。
enum HGNativeCrypto {
    static func random(_ n: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: max(0, min(n, 1024)))
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    static func digest(_ algorithm: String, _ data: Data) throws -> Data {
        switch algorithm {
        case "md5": return Data(Insecure.MD5.hash(data: data))
        case "sha256": return Data(SHA256.hash(data: data))
        case "sha512": return Data(SHA512.hash(data: data))
        default: throw HGError.message("不支持的摘要算法 \(algorithm)")
        }
    }

    static func crypt(decrypt: Bool, algorithm: String, key: Data, iv: Data, padding: Bool, data: Data) throws -> Data {
        let options: CCOptions
        switch algorithm {
        case "aes-128-ecb": options = CCOptions(kCCOptionECBMode) | (padding ? CCOptions(kCCOptionPKCS7Padding) : 0)
        case "aes-128-cbc": options = padding ? CCOptions(kCCOptionPKCS7Padding) : 0
        default: throw HGError.message("不支持的加密算法 \(algorithm)")
        }
        guard key.count == kCCKeySizeAES128 else { throw HGError.message("AES 密钥长度无效") }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let outCapacity = out.count
        let status = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { d in key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), options,
                        k.baseAddress, key.count, iv.isEmpty ? nil : v.baseAddress,
                        d.baseAddress, data.count, o.baseAddress, outCapacity, &moved)
            } } }
        }
        guard status == kCCSuccess else { throw HGError.message("AES 运算失败 \(status)") }
        return out.prefix(moved)
    }

    // MARK: gzip = 10 字节头 + raw deflate + CRC32 + ISIZE

    static func gzip(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0, 0, 0, 0, 0, 0, 0xff])
        out.append(try codec(data, operation: COMPRESSION_STREAM_ENCODE, limit: Int.max))
        var crc = crc32(data).littleEndian, size = UInt32(truncatingIfNeeded: data.count).littleEndian
        out.append(Data(bytes: &crc, count: 4)); out.append(Data(bytes: &size, count: 4))
        return out
    }

    static func gunzip(_ data: Data, limit: Int) throws -> Data {
        let b = [UInt8](data)
        guard b.count >= 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { throw HGError.message("gzip 数据无效") }
        let flags = b[3]; var p = 10
        if flags & 4 != 0 { guard p + 2 <= b.count else { throw HGError.message("gzip 头无效") }; p += 2 + Int(b[p]) + Int(b[p + 1]) << 8 }
        if flags & 8 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < b.count, b[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        guard p < b.count - 8 else { throw HGError.message("gzip 头无效") }
        return try codec(Data(b[p..<(b.count - 8)]), operation: COMPRESSION_STREAM_DECODE, limit: limit)
    }

    private static func codec(_ input: Data, operation: compression_stream_operation, limit: Int) throws -> Data {
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }
        var stream = compression_stream(dst_ptr: dst, dst_size: 0, src_ptr: dst, src_size: 0, state: nil)
        guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw HGError.message("压缩初始化失败") }
        defer { compression_stream_destroy(&stream) }
        var output = Data()
        try input.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            stream.src_ptr = src.bindMemory(to: UInt8.self).baseAddress ?? UnsafePointer(dst)
            stream.src_size = input.count
            while true {
                stream.dst_ptr = dst; stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                output.append(dst, count: chunk - stream.dst_size)
                if output.count > limit { throw HGError.message("解压数据过大") }
                if status == COMPRESSION_STATUS_END { break }
                if status == COMPRESSION_STATUS_ERROR { throw HGError.message("压缩数据损坏") }
            }
        }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffffffff
    }
}

enum HGError: LocalizedError {
    case message(String)
    case js(String, code: String)
    var errorDescription: String? {
        switch self { case .message(let m): return m; case .js(let m, _): return m }
    }
    var code: String { if case .js(_, let c) = self { return c }; return "" }
}
