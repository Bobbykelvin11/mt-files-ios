import Foundation

/// Reads Mach-O load commands to report whether a binary is FairPlay-encrypted
/// (LC_ENCRYPTION_INFO / LC_ENCRYPTION_INFO_64 with cryptid != 0).
/// Read-only: IPA Studio never decrypts anything.
enum MachOInspector {
    static func isEncrypted(executableURL: URL) -> Bool? {
        guard let data = try? Data(contentsOf: executableURL, options: .alwaysMapped), data.count > 32 else { return nil }
        let magicBE = data.u32BE(0)
        if magicBE == 0xCAFEBABE || magicBE == 0xCAFEBABF {
            let is64 = magicBE == 0xCAFEBABF
            let count = Int(data.u32BE(4))
            guard count > 0, count < 32 else { return nil }
            var found = false
            var anyEncrypted = false
            for i in 0..<count {
                let entry = 8 + i * (is64 ? 32 : 20)
                guard entry + 20 <= data.count else { break }
                let offset: Int = is64 ? Int(truncatingIfNeeded: data.u64BE(entry + 8)) : Int(data.u32BE(entry + 8))
                if let r = thin(data, base: offset) {
                    found = true
                    if r { anyEncrypted = true }
                }
            }
            return found ? anyEncrypted : nil
        }
        return thin(data, base: 0)
    }

    private static func thin(_ d: Data, base: Int) -> Bool? {
        guard base >= 0, base + 32 <= d.count else { return nil }
        let magic = d.u32LE(base)
        let is64: Bool
        switch magic {
        case 0xFEEDFACF: is64 = true
        case 0xFEEDFACE: is64 = false
        default: return nil
        }
        let ncmds = Int(d.u32LE(base + 16))
        var off = base + (is64 ? 32 : 28)
        for _ in 0..<ncmds {
            guard off + 8 <= d.count else { break }
            let cmd = d.u32LE(off)
            let size = Int(d.u32LE(off + 4))
            if cmd == 0x21 || cmd == 0x2C {
                guard off + 20 <= d.count else { return nil }
                return d.u32LE(off + 16) != 0
            }
            if size <= 0 { break }
            off += size
        }
        return false
    }
}

extension Data {
    func byte(_ o: Int) -> UInt8 { self[self.startIndex + o] }

    func u32LE(_ o: Int) -> UInt32 {
        UInt32(byte(o)) | UInt32(byte(o + 1)) << 8 | UInt32(byte(o + 2)) << 16 | UInt32(byte(o + 3)) << 24
    }

    func u32BE(_ o: Int) -> UInt32 {
        UInt32(byte(o)) << 24 | UInt32(byte(o + 1)) << 16 | UInt32(byte(o + 2)) << 8 | UInt32(byte(o + 3))
    }

    func u64BE(_ o: Int) -> UInt64 {
        UInt64(u32BE(o)) << 32 | UInt64(u32BE(o + 4))
    }
}
