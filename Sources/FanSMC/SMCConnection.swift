import Foundation
import IOKit

/// Thin SMC (System Management Controller) user-client.
///
/// Protocol details ported from public, battle-tested open sources:
/// - exelban/stats `SMC/smc.swift` (MIT) — Apple Silicon fan control incl. M5+ direct mode write
/// - narugit/smctemp (GPL-2.0) — M1..M5 sensor key sets
/// - beltex/SMCKit (MIT) — canonical `SMCParamStruct` layout (80 bytes)
struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct limitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = limitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

enum SMCCommand: UInt8 {
    case readBytes = 5
    case writeBytes = 6
    case readIndex = 8
    case readKeyInfo = 9
}

/// SMC-level failure (kernel call was fine, key/privilege/refresh failed).
public struct SMCError: Error, CustomStringConvertible {
    public let operation: String
    public let key: String
    public let kernelReturn: kern_return_t
    public let smcResult: UInt8?

    public var description: String {
        let mach = String(cString: mach_error_string(kernelReturn))
        return "SMC \(operation) '\(key)' failed: \(mach) (kIOReturn: 0x\(String(kernelReturn, radix: 16))\(smcResult.map { ", SMC result: 0x\(String($0, radix: 16))" } ?? ""))"
    }
}

public final class SMCConnection {
    private var conn: io_connect_t = 0
    private var keyInfoCache: [UInt32: (dataType: UInt32, dataSize: UInt32)] = [:]
    private let lock = NSLock()

    public init() throws {
        assert(MemoryLayout<SMCKeyData_t>.stride == 80, "SMCKeyData_t must be exactly 80 bytes")
        var iterator: io_iterator_t = 0
        let r = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator)
        guard r == kIOReturnSuccess else { throw SMCError(operation: "open", key: "service", kernelReturn: r, smcResult: nil) }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else {
            throw SMCError(operation: "open", key: "service", kernelReturn: kIOReturnNotFound, smcResult: nil)
        }
        let open = IOServiceOpen(device, mach_task_self_, 0, &conn)
        IOObjectRelease(device)
        guard open == kIOReturnSuccess else {
            throw SMCError(operation: "open", key: "connection", kernelReturn: open, smcResult: nil)
        }
    }

    deinit { IOServiceClose(conn) }

    // MARK: - primitives

    private func call(input: inout SMCKeyData_t, output: inout SMCKeyData_t) throws -> SMCKeyData_t {
        var outSize = MemoryLayout<SMCKeyData_t>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData_t>.stride, &output, &outSize)
        guard r == kIOReturnSuccess else {
            throw SMCError(operation: "call", key: input.key.toKeyString(), kernelReturn: r, smcResult: nil)
        }
        guard output.result == 0 else {
            throw SMCError(operation: "call", key: input.key.toKeyString(), kernelReturn: 0, smcResult: output.result)
        }
        return output
    }

    /// `(type, size)` of a key, or nil when the key does not exist on this machine.
    func keyInfo(_ name: String) -> (type: String, size: Int)? {
        lock.lock(); defer { lock.unlock() }
        let code = FourCharCode(fromString: name)
        if let cached = keyInfoCache[code] {
            return (Self.typeString(cached.dataType), Int(cached.dataSize))
        }
        var input = SMCKeyData_t()
        var output = SMCKeyData_t()
        input.key = code
        input.data8 = SMCCommand.readKeyInfo.rawValue
        guard let out = try? call(input: &input, output: &output),
              out.keyInfo.dataSize > 0, out.keyInfo.dataSize <= 32, out.keyInfo.dataType != 0
        else { return nil }
        keyInfoCache[code] = (out.keyInfo.dataType, out.keyInfo.dataSize)
        return (Self.typeString(out.keyInfo.dataType), Int(out.keyInfo.dataSize))
    }

    private static func typeString(_ v: UInt32) -> String { FourCharCode(v).toKeyString() }

    /// Raw read: key type + bytes. nil when absent.
    public func read(_ name: String) -> (type: String, size: Int, bytes: [UInt8])? {
        guard let info = keyInfo(name) else { return nil }
        var input = SMCKeyData_t()
        input.key = FourCharCode(fromString: name)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMCCommand.readBytes.rawValue
        var output = SMCKeyData_t()
        guard let out = try? call(input: &input, output: &output) else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(input.keyInfo.dataSize))) }
        return (info.type, info.size, bytes)
    }

    /// Read a numeric value decoded per SMC data type.
    public func readValue(_ name: String) -> Double? {
        guard let r = read(name) else { return nil }
        return Self.decode(type: r.type, bytes: r.bytes)
    }

    /// Raw write. Requires root. Throws on SMC rejection.
    public func write(_ name: String, bytes: [UInt8], size: Int? = nil) throws {
        let n = size ?? bytes.count
        guard let info = keyInfo(name) else {
            throw SMCError(operation: "write", key: name, kernelReturn: kIOReturnNotFound, smcResult: nil)
        }
        guard n == info.size else {
            throw SMCError(operation: "write", key: name, kernelReturn: kIOReturnBadArgument, smcResult: nil)
        }
        var input = SMCKeyData_t()
        input.key = FourCharCode(fromString: name)
        input.keyInfo.dataSize = UInt32(info.size)
        input.data8 = SMCCommand.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            for (i, b) in bytes.enumerated() where i < n {
                dst[i] = b
            }
        }
        var output = SMCKeyData_t()
        let out = try call(input: &input, output: &output)
        _ = out // SMC result already checked inside call()
    }

    public func keyExists(_ name: String) -> Bool { keyInfo(name) != nil }

    // MARK: - decoding

    /// Decode SMC value by data type. Native (little-endian) multi-byte access,
    /// matching how Apple's own `powermetrics` and stats read `flt`/`fp*`/`sp*`.
    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        func u16() -> Double { Double(bytes[0]) * 256 + Double(bytes[1]) }
        switch type {
        case "ui8 ": return bytes.count >= 1 ? Double(bytes[0]) : nil
        case "ui16": return bytes.count >= 2 ? u16() : nil
        case "ui32": return bytes.count >= 4
            ? Double(bytes[0]) * 65536 * 256 + Double(bytes[1]) * 65536 + Double(bytes[2]) * 256 + Double(bytes[3])
            : nil
        case "flt ": return bytes.count >= 4
            ? bytes.withUnsafeBytes { $0.bindMemory(to: Float.self).first }.map { Double($0) }
            : nil
        case "fpe2": return bytes.count >= 2 ? u16() / 4 : nil
        case "fp79": return bytes.count >= 2 ? u16() / 512 : nil
        case "fp88": return bytes.count >= 2 ? u16() / 256 : nil
        case "fpc4": return bytes.count >= 2 ? u16() / 16 : nil
        case "sp1e": return bytes.count >= 2 ? Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 16384 : nil
        case "sp78": return bytes.count >= 2 ? Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 256 : nil
        case "sp87": return bytes.count >= 2 ? Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 128 : nil
        case "sp96": return bytes.count >= 2 ? Double(Int(bytes[0]) * 256 + Int(bytes[1])) / 64 : nil
        default: return nil
        }
    }

    // MARK: - key enumeration

    /// Key name at enumeration index, or nil when invalid.
    func keyName(at index: Int) -> String? {
        var input = SMCKeyData_t()
        input.data8 = SMCCommand.readIndex.rawValue
        input.data32 = UInt32(index)
        var output = SMCKeyData_t()
        guard let out = try? call(input: &input, output: &output) else { return nil }
        return out.key.toKeyString()
    }

    /// All SMC keys on this machine (a few thousand on modern laptops).
    public func allKeys() -> [String]? {
        guard let count = readValue("#KEY").map({ Int($0) }), count > 0, count < 20000 else { return nil }
        var list: [String] = []
        list.reserveCapacity(count)
        for i in 0 ..< count {
            if let name = keyName(at: i) { list.append(name) }
        }
        return list
    }
}

extension FourCharCode {
    init(fromString str: String) {
        precondition(str.utf8.count == 4, "SMC keys are exactly 4 characters")
        self = str.utf8.reduce(0) { sum, c in sum << 8 | UInt32(c) }
    }

    func toKeyString() -> String {
        String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
            String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
            String(describing: UnicodeScalar(self >> 8 & 0xff)!) +
            String(describing: UnicodeScalar(self & 0xff)!)
    }
}
