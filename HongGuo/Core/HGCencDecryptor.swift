import Foundation
import CommonCrypto

/// CENC (AES-CTR, 整样本加密) MP4 → 明文 MP4。
/// 逐行对照上游 src/native/hongguo.js 的 decryptMp4Buffer / rebuildMoov，输出应与之逐字节一致。
enum HGCencDecryptor {
    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "udta", "meta"]
    private static let pruned: Set<String> = ["senc", "saio", "saiz", "sgpd", "sbgp"]
    static let maxBytes = 512 * 1024 * 1024

    final class Box {
        let typ: String, off: Int, size: Int, hdr: Int
        var children: [Box]?
        init(typ: String, off: Int, size: Int, hdr: Int, children: [Box]?) {
            self.typ = typ; self.off = off; self.size = size; self.hdr = hdr; self.children = children
        }
        func clone() -> Box { Box(typ: typ, off: off, size: size, hdr: hdr, children: children?.map { $0.clone() }) }
    }

    static func decrypt(_ input: Data, keyHex: String) throws -> Data {
        guard let key = Data(hex: keyHex), key.count == 16 else { throw HGError.message("视频密钥无效") }
        guard input.count >= 16, input.count <= maxBytes else { throw HGError.message("视频大小不受支持") }
        var d = [UInt8](input)
        let total = d.count
        let top = parseBoxes(d, 0, total)
        guard let moov = top.first(where: { $0.typ == "moov" }) else { throw HGError.message("视频缺少 moov") }

        // 1. 逐样本 AES-CTR 解密（IV 8 字节 + 64 位块计数从 0 开始）
        for stbl in walk(top).filter({ $0.typ == "stbl" }) {
            let kids = stbl.children ?? []
            guard let stsz = kids.first(where: { $0.typ == "stsz" }),
                  let stco = kids.first(where: { $0.typ == "stco" }),
                  let stsc = kids.first(where: { $0.typ == "stsc" }) else { continue }
            let senc = kids.first(where: { $0.typ == "senc" })
            let ss = Int(u32(d, stsz.off + 12)), n = Int(u32(d, stsz.off + 16))
            guard n <= 1_000_000, ss != 0 || stsz.off + 20 + n * 4 <= total else { throw HGError.message("视频采样表无效") }
            let sizes: [Int] = ss == 0 ? (0..<n).map { Int(u32(d, stsz.off + 20 + $0 * 4)) } : Array(repeating: ss, count: n)
            let nc = Int(u32(d, stco.off + 12))
            guard nc <= 1_000_000, stco.off + 16 + nc * 4 <= total else { throw HGError.message("视频块表无效") }
            let chunkOffs = (0..<nc).map { Int(u32(d, stco.off + 16 + $0 * 4)) }
            let ns = Int(u32(d, stsc.off + 12))
            guard ns <= 1_000_000, stsc.off + 16 + ns * 12 <= total else { throw HGError.message("视频块映射无效") }
            let tab = (0..<ns).map { (Int(u32(d, stsc.off + 16 + $0 * 12)), Int(u32(d, stsc.off + 20 + $0 * 12))) }
            var ivs: [Int] = []
            if let senc {
                let sc = Int(u32(d, senc.off + 12))
                guard senc.off + 16 + sc * 8 <= total else { throw HGError.message("视频加密格式不受支持") }
                ivs = (0..<sc).map { senc.off + 16 + $0 * 8 }
            }
            var spc = [Int](repeating: 1, count: nc)
            for (i, entry) in tab.enumerated() {
                let next = i + 1 < tab.count ? tab[i + 1].0 : nc + 1
                var ci = entry.0 - 1
                while ci < next - 1 { if ci >= 0 && ci < nc { spc[ci] = entry.1 }; ci += 1 }
            }
            var si = 0
            for ci in 0..<nc {
                var off = chunkOffs[ci]
                for _ in 0..<spc[ci] {
                    if si >= n { break }
                    let sz = sizes[si]
                    if off >= 0, off + sz <= total, si < ivs.count {
                        try ctr(&d, off: off, count: sz, key: key, nonceAt: ivs[si])
                    }
                    off += sz; si += 1
                }
            }
        }

        // 2. 重建 moov：删加密相关盒子，encv/enca 还原为原始编码
        let newMoov = try rebuildMoov(&d, moovOff: moov.off, moovSize: moov.size, moovBox: moov)
        var out = Data(capacity: total)
        var off = 0
        while off < total {
            var size = Int(u32(d, off))
            let typ = fourcc(d, off + 4)
            if size == 1 { size = Int(u64(d, off + 8)) } else if size == 0 { size = total - off }
            guard size >= 8, off + size <= total else { throw HGError.message("视频容器长度无效") }
            if typ == "moov" { out.append(contentsOf: newMoov) } else { out.append(contentsOf: d[off..<(off + size)]) }
            off += size
        }
        return out
    }

    // MARK: - moov 重建（对应 rebuildMoov）

    private static func rebuildMoov(_ d: inout [UInt8], moovOff: Int, moovSize: Int, moovBox: Box) throws -> [UInt8] {
        func prune(_ box: Box) -> Box {
            guard let kids = box.children else { return box }
            box.children = kids.filter { !pruned.contains($0.typ) }.map(prune)
            return box
        }
        let tree = prune(moovBox.clone())
        var patches: [Int: [UInt8]] = [:]
        for b in walk([tree]) where b.typ == "stsd" {
            let content = b.off + 8
            let count = Int(u32(d, content + 4))
            var p = content + 8
            var entries: [[UInt8]] = []
            for _ in 0..<count {
                let esize = Int(u32(d, p)); let etyp = fourcc(d, p + 4)
                guard esize >= 8, p + esize <= d.count else { throw HGError.message("视频描述无效") }
                if etyp == "encv" || etyp == "enca" {
                    let hdrSize = etyp == "encv" ? 78 : 28
                    let kids = parseBoxes(d, p + 8 + hdrSize, p + esize)
                    var newType = "mp4a"
                    if etyp == "encv" {
                        var original: String?
                        if let sinf = kids.first(where: { $0.typ == "sinf" }),
                           let frma = parseBoxes(d, sinf.off + sinf.hdr, sinf.off + sinf.size).first(where: { $0.typ == "frma" }),
                           frma.size == frma.hdr + 4 { original = fourcc(d, frma.off + frma.hdr) }
                        let avc = kids.contains { $0.typ == "avcC" }, hevc = kids.contains { $0.typ == "hvcC" }
                        let t = original ?? (avc && !hevc ? "avc1" : hevc && !avc ? "hvc1" : "")
                        guard ["avc1", "avc3", "hvc1", "hev1"].contains(t), t.hasPrefix("avc") ? (avc && !hevc) : (hevc && !avc) else {
                            throw HGError.message("无法确定加密视频的原始编码")
                        }
                        newType = t
                    }
                    var entry = [UInt8](repeating: 0, count: 8)
                    entry.replaceSubrange(4..<8, with: Array(newType.utf8))
                    entry.append(contentsOf: d[(p + 8)..<(p + 8 + hdrSize)])
                    for k in kids where k.typ != "sinf" { entry.append(contentsOf: d[k.off..<(k.off + k.size)]) }
                    put32(&entry, 0, UInt32(entry.count))
                    entries.append(entry)
                } else {
                    entries.append(Array(d[p..<(p + esize)]))
                }
                p += esize
            }
            var stsd = Array(d[b.off..<(content + 8)])
            put32(&stsd, 12, UInt32(entries.count))
            for e in entries { stsd.append(contentsOf: e) }
            put32(&stsd, 0, UInt32(stsd.count))
            patches[b.off] = stsd
        }

        func serialize(_ box: Box) -> [UInt8] {
            guard let kids = box.children else { return patches[box.off] ?? Array(d[box.off..<(box.off + box.size)]) }
            var body: [UInt8] = []
            for k in kids { body.append(contentsOf: serialize(k)) }
            var h = Array(d[box.off..<(box.off + box.hdr)])
            if box.hdr == 8 { put32(&h, 0, UInt32(8 + body.count)) }
            else { put32(&h, 0, 1); put64(&h, 8, UInt64(16 + body.count)) }
            return h + body
        }
        let delta = moovSize - serialize(tree).count
        // 3. moov 变短后，位于其后的 mdat 前移，修正 stco 绝对偏移
        for b in walk([tree]) where b.typ == "stco" {
            let nc = Int(u32(d, b.off + 12))
            for i in 0..<nc {
                let at = b.off + 16 + i * 4
                let v = Int(u32(d, at))
                if v >= moovOff + moovSize { put32(&d, at, UInt32(v - delta)) }
            }
        }
        return serialize(tree)
    }

    // MARK: - 盒子解析与字节工具

    static func parseBoxes(_ d: [UInt8], _ start: Int, _ end: Int) -> [Box] {
        var boxes: [Box] = []
        var off = start
        while off + 8 <= end {
            var size = Int(u32(d, off)); let typ = fourcc(d, off + 4); var hdr = 8
            if size == 1 { guard off + 16 <= end else { break }; size = Int(u64(d, off + 8)); hdr = 16 }
            else if size == 0 { size = end - off }
            if size < hdr || off + size > end { break }
            let kids = containers.contains(typ) ? parseBoxes(d, off + hdr, off + size) : nil
            boxes.append(Box(typ: typ, off: off, size: size, hdr: hdr, children: kids))
            off += size
        }
        return boxes
    }

    private static func walk(_ boxes: [Box]) -> [Box] {
        var out: [Box] = []
        for b in boxes { out.append(contentsOf: walk(b.children ?? [])); out.append(b) }
        return out
    }

    private static func ctr(_ d: inout [UInt8], off: Int, count: Int, key: Data, nonceAt: Int) throws {
        guard count > 0 else { return }
        var iv = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { iv[i] = d[nonceAt + i] }
        var ref: CCCryptorRef?
        let created = key.withUnsafeBytes { k in
            CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                    iv, k.baseAddress, 16, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &ref)
        }
        guard created == kCCSuccess, let ref else { throw HGError.message("解密器初始化失败") }
        defer { CCCryptorRelease(ref) }
        var moved = 0
        let status = d.withUnsafeMutableBytes { buf -> CCCryptorStatus in
            let p = buf.baseAddress! + off
            return CCCryptorUpdate(ref, p, count, p, count, &moved)
        }
        guard status == kCCSuccess, moved == count else { throw HGError.message("视频样本解密失败") }
    }

    @inline(__always) static func u32(_ d: [UInt8], _ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= d.count else { return 0 }
        return UInt32(d[o]) << 24 | UInt32(d[o + 1]) << 16 | UInt32(d[o + 2]) << 8 | UInt32(d[o + 3])
    }
    @inline(__always) static func u64(_ d: [UInt8], _ o: Int) -> UInt64 { UInt64(u32(d, o)) << 32 | UInt64(u32(d, o + 4)) }
    static func fourcc(_ d: [UInt8], _ o: Int) -> String {
        guard o >= 0, o + 4 <= d.count else { return "" }
        return String(bytes: d[o..<(o + 4)], encoding: .isoLatin1) ?? ""
    }
    static func put32(_ d: inout [UInt8], _ o: Int, _ v: UInt32) {
        d[o] = UInt8(v >> 24); d[o + 1] = UInt8(v >> 16 & 0xff); d[o + 2] = UInt8(v >> 8 & 0xff); d[o + 3] = UInt8(v & 0xff)
    }
    static func put64(_ d: inout [UInt8], _ o: Int, _ v: UInt64) { put32(&d, o, UInt32(v >> 32)); put32(&d, o + 4, UInt32(v & 0xffffffff)) }
}

extension Data {
    init?(hex: String) {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(bytes: chars[i..<(i + 2)], encoding: .ascii) ?? "", radix: 16) else { return nil }
            bytes.append(b); i += 2
        }
        self.init(bytes)
    }
}
