//
//  TextEncoding.swift
//  Encoding detection, reading, and writing for text files.
//
//  The menu mirrors CotEditor's default encoding list: UTF, Japanese,
//  Western, Chinese, Korean, Thai, Arabic/Greek/Hebrew/Cyrillic,
//  ISO Latin variants, DOS/NextStep/ASCII, and UTF-16/32 variants.
//
//  Detection strategy on read:
//    1. BOM sniff — handles UTF-8/16/32 unambiguously when a BOM is present
//    2. UTF-8 validity check — if bytes decode cleanly as UTF-8, use that
//    3. Fall back through a configured chain, trying each encoding and
//       picking the first that produces a valid string with plausible
//       character distribution (no long runs of control chars)
//
//  Write: always honors Document.encoding. UTF-8 is written without a BOM
//  by default — matches modern conventions. Other encodings preserve their
//  native behaviour.
//

import Foundation
import CoreFoundation

/// A supported text encoding, wrapping Foundation's raw identifier and
/// a human-friendly display name. We keep our own enum (instead of just
/// using String.Encoding) because we want:
///   - Stable identifiers for settings persistence
///   - Display names for the status bar menu
///   - A canonical ordering for the fallback chain
nonisolated enum TextEncoding: String, CaseIterable, Identifiable, Codable, Sendable {
    case utf8                = "utf-8"
    case utf8WithBOM         = "utf-8-bom"

    case shiftJIS            = "shift_jis"
    case eucJP               = "euc-jp"
    case dosJapanese         = "dos-japanese"
    case shiftJISX0213       = "shift_jis-x0213"
    case macJapanese         = "mac-japanese"
    case iso2022JP           = "iso-2022-jp"

    case macRoman            = "mac-roman"
    case windows1252         = "windows-1252"

    case gb18030             = "gb18030"
    case big5HKSCS           = "big5-hkscs"
    case big5E               = "big5-e"
    case big5                = "big5"
    case macChineseTrad      = "mac-chinese-trad"
    case macChineseSimp      = "mac-chinese-simp"
    case eucTW               = "euc-tw"
    case eucCN               = "euc-cn"
    case dosChineseTrad      = "dos-chinese-trad"
    case dosChineseSimplif   = "dos-chinese-simplif"

    case macKorean           = "mac-korean"
    case eucKR               = "euc-kr"
    case dosKorean           = "dos-korean"

    case windows874          = "windows-874"
    case tis620              = "tis-620"

    case macArabic           = "mac-arabic"
    case isoLatinArabic      = "iso-8859-6"
    case windowsArabic       = "windows-arabic"
    case macGreek            = "mac-greek"
    case isoLatinGreek       = "iso-8859-7"
    case windowsGreek        = "windows-greek"
    case macHebrew           = "mac-hebrew"
    case isoLatinHebrew      = "iso-8859-8"
    case windowsHebrew       = "windows-hebrew"
    case macCyrillic         = "mac-cyrillic"
    case isoLatinCyrillic    = "iso-8859-5"
    case windowsCyrillic     = "windows-cyrillic"
    case dosRussian          = "dos-russian"
    case macCentralEurRoman  = "mac-central-eur-roman"
    case macTurkish          = "mac-turkish"
    case macIcelandic        = "mac-icelandic"

    case iso8859_1           = "iso-8859-1"
    case isoLatin2           = "iso-8859-2"
    case isoLatin3           = "iso-8859-3"
    case isoLatin4           = "iso-8859-4"
    case isoLatin5           = "iso-8859-9"
    case isoLatin6           = "iso-8859-10"
    case isoLatin7           = "iso-8859-13"
    case isoLatin8           = "iso-8859-14"
    case isoLatin9           = "iso-8859-15"
    case isoLatin10          = "iso-8859-16"

    case dosLatinUS          = "dos-latin-us"
    case windowsLatin2       = "windows-1250"
    case nextStepLatin       = "nextstep-latin"
    case ascii               = "ascii"

    case utf16               = "utf-16"
    case utf16BE             = "utf-16-be"
    case utf16LE             = "utf-16-le"
    case utf32               = "utf-32"
    case utf32BE             = "utf-32-be"
    case utf32LE             = "utf-32-le"

    var id: String { rawValue }

    /// UTF-16/32 encode every ASCII character with at least one NUL byte, so the
    /// "contains a NUL" binary heuristic is meaningless for them.
    var usesWideCodeUnits: Bool {
        switch self {
        case .utf16, .utf16BE, .utf16LE, .utf32, .utf32BE, .utf32LE: return true
        default: return false
        }
    }

    var startsMenuSection: Bool {
        switch self {
        case .shiftJIS, .macRoman, .gb18030, .macKorean, .windows874,
             .macArabic, .iso8859_1, .dosLatinUS, .utf16:
            return true
        default:
            return false
        }
    }

    /// Name shown in the status bar and menus.
    var displayName: String {
        if self == .utf8WithBOM {
            return "\(String.localizedName(of: .utf8)) with BOM"
        }
        return String.localizedName(of: foundationEncoding)
    }

    /// Foundation String.Encoding for this entry.
    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8WithBOM: return .utf8

        case .shiftJIS:           return .shiftJIS
        case .eucJP:              return .japaneseEUC
        case .dosJapanese:        return Self.fromCF(.dosJapanese)
        case .shiftJISX0213:      return Self.fromCF(.shiftJIS_X0213)
        case .macJapanese:        return Self.fromCF(.macJapanese)
        case .iso2022JP:          return Self.fromCF(.ISO_2022_JP)

        case .macRoman:           return Self.fromCF(.macRoman)
        case .windows1252:        return .windowsCP1252

        case .gb18030:            return Self.fromCF(.GB_18030_2000)
        case .big5HKSCS:          return Self.fromCF(.big5_HKSCS_1999)
        case .big5E:              return Self.fromCF(.big5_E)
        case .big5:               return Self.fromCF(.big5)
        case .macChineseTrad:     return Self.fromCF(.macChineseTrad)
        case .macChineseSimp:     return Self.fromCF(.macChineseSimp)
        case .eucTW:              return Self.fromCF(.EUC_TW)
        case .eucCN:              return Self.fromCF(.EUC_CN)
        case .dosChineseTrad:     return Self.fromCF(.dosChineseTrad)
        case .dosChineseSimplif:  return Self.fromCF(.dosChineseSimplif)

        case .macKorean:          return Self.fromCF(.macKorean)
        case .eucKR:              return Self.fromCF(.EUC_KR)
        case .dosKorean:          return Self.fromCF(.dosKorean)

        case .windows874:         return Self.fromCF(.dosThai)
        case .tis620:             return Self.fromCF(.isoLatinThai)

        case .macArabic:          return Self.fromCF(.macArabic)
        case .isoLatinArabic:     return Self.fromCF(.isoLatinArabic)
        case .windowsArabic:      return Self.fromCF(.windowsArabic)
        case .macGreek:           return Self.fromCF(.macGreek)
        case .isoLatinGreek:      return Self.fromCF(.isoLatinGreek)
        case .windowsGreek:       return Self.fromCF(.windowsGreek)
        case .macHebrew:          return Self.fromCF(.macHebrew)
        case .isoLatinHebrew:     return Self.fromCF(.isoLatinHebrew)
        case .windowsHebrew:      return Self.fromCF(.windowsHebrew)
        case .macCyrillic:        return Self.fromCF(.macCyrillic)
        case .isoLatinCyrillic:   return Self.fromCF(.isoLatinCyrillic)
        case .windowsCyrillic:    return Self.fromCF(.windowsCyrillic)
        case .dosRussian:         return Self.fromCF(.dosRussian)
        case .macCentralEurRoman: return Self.fromCF(.macCentralEurRoman)
        case .macTurkish:         return Self.fromCF(.macTurkish)
        case .macIcelandic:       return Self.fromCF(.macIcelandic)

        case .iso8859_1:          return .isoLatin1
        case .isoLatin2:          return Self.fromCF(.isoLatin2)
        case .isoLatin3:          return Self.fromCF(.isoLatin3)
        case .isoLatin4:          return Self.fromCF(.isoLatin4)
        case .isoLatin5:          return Self.fromCF(.isoLatin5)
        case .isoLatin6:          return Self.fromCF(.isoLatin6)
        case .isoLatin7:          return Self.fromCF(.isoLatin7)
        case .isoLatin8:          return Self.fromCF(.isoLatin8)
        case .isoLatin9:          return Self.fromCF(.isoLatin9)
        case .isoLatin10:         return Self.fromCF(.isoLatin10)

        case .dosLatinUS:         return Self.fromCF(.dosLatinUS)
        case .windowsLatin2:      return Self.fromCF(.windowsLatin2)
        case .nextStepLatin:      return Self.fromCF(.nextStepLatin)
        case .ascii:              return .ascii

        case .utf16:              return .utf16
        case .utf16BE:            return .utf16BigEndian
        case .utf16LE:            return .utf16LittleEndian
        case .utf32:              return .utf32
        case .utf32BE:            return .utf32BigEndian
        case .utf32LE:            return .utf32LittleEndian
        }
    }

    /// Whether a newly selected save encoding should write a BOM.
    var writesBOMByDefault: Bool {
        switch self {
        case .utf8WithBOM, .utf16, .utf16LE, .utf16BE, .utf32, .utf32LE, .utf32BE:
            return true
        default:
            return false
        }
    }

    /// Fallback chain tried when no BOM is present and UTF-8 decoding fails.
    /// Order reflects global prevalence biased toward the user's likely
    /// files (Japanese/Chinese/Thai/Western-European).
    static let detectionChain: [TextEncoding] = [
        .utf8, .utf16, .utf16LE, .utf16BE, .utf32, .utf32LE, .utf32BE,
        .shiftJIS, .eucJP, .dosJapanese, .shiftJISX0213, .macJapanese, .iso2022JP,
        .macRoman, .windows1252,
        .gb18030, .big5HKSCS, .big5E, .big5, .macChineseTrad, .macChineseSimp,
        .eucTW, .eucCN, .dosChineseTrad, .dosChineseSimplif,
        .macKorean, .eucKR, .dosKorean,
        .windows874, .tis620,
        .macArabic, .isoLatinArabic, .windowsArabic,
        .macGreek, .isoLatinGreek, .windowsGreek,
        .macHebrew, .isoLatinHebrew, .windowsHebrew,
        .macCyrillic, .isoLatinCyrillic, .windowsCyrillic, .dosRussian,
        .macCentralEurRoman, .macTurkish, .macIcelandic,
        .iso8859_1, .isoLatin2, .isoLatin3, .isoLatin4, .isoLatin5,
        .isoLatin6, .isoLatin7, .isoLatin8, .isoLatin9, .isoLatin10,
        .dosLatinUS, .windowsLatin2, .nextStepLatin, .ascii
    ]

    private static func fromCF(_ encoding: CFStringBuiltInEncodings) -> String.Encoding {
        fromCF(CFStringEncoding(encoding.rawValue))
    }

    private static func fromCF(_ encoding: CFStringEncodings) -> String.Encoding {
        fromCF(CFStringEncoding(encoding.rawValue))
    }

    private static func fromCF(_ encoding: CFStringEncoding) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}

// MARK: - BOM sniffing

nonisolated private enum BOM {
    static let utf8:    [UInt8] = [0xEF, 0xBB, 0xBF]
    static let utf16BE: [UInt8] = [0xFE, 0xFF]
    static let utf16LE: [UInt8] = [0xFF, 0xFE]
    static let utf32BE: [UInt8] = [0x00, 0x00, 0xFE, 0xFF]
    static let utf32LE: [UInt8] = [0xFF, 0xFE, 0x00, 0x00]
}

/// Result of a file read: decoded text plus the encoding we ended up using.
nonisolated struct DecodedFile: Sendable {
    let text: String
    let encoding: TextEncoding
    /// Whether a BOM was present at the start (so we can preserve it on save).
    let hadBOM: Bool
    /// Original byte count on disk. Used by Large File Mode before any edits.
    let byteCount: Int?
    /// The bytes contain a NUL in the first 4 KB, so this is almost certainly
    /// not a text file. Decoding still produces *something* — the last resort in
    /// `decode` is Windows-1252, which never fails — so callers that can write
    /// the file back have to check this themselves.
    let looksBinary: Bool

    init(
        text: String,
        encoding: TextEncoding,
        hadBOM: Bool,
        byteCount: Int? = nil,
        looksBinary: Bool = false
    ) {
        self.text = text
        self.encoding = encoding
        self.hadBOM = hadBOM
        self.byteCount = byteCount
        self.looksBinary = looksBinary
    }
}

nonisolated enum EncodingError: Error {
    case cannotDecode
    case cannotEncode(TextEncoding)
}

nonisolated enum TextFileIO {

    /// Read a file, detecting encoding.
    static func read(url: URL) throws -> DecodedFile {
        let data = try Data(contentsOf: url)
        return decode(data: data)
    }

    /// Decode raw bytes, trying BOM → UTF-8 → fallback chain.
    static func decode(data: Data) -> DecodedFile {
        let binary = looksBinary(data)

        // 1. BOM
        if let decoded = decodeByBOM(data: data) { return decoded }

        // 2. UTF-8 without BOM
        if let str = String(data: data, encoding: .utf8), isPlausibleText(str) {
            return DecodedFile(text: str, encoding: .utf8, hadBOM: false,
                               byteCount: data.count, looksBinary: binary)
        }

        // 3. Fallback chain
        for enc in TextEncoding.detectionChain where enc != .utf8 {
            if let str = String(data: data, encoding: enc.foundationEncoding),
               isPlausibleText(str) {
                // A BOM-less UTF-16/32 file is full of NUL bytes by design —
                // every ASCII character carries one — so the NUL test says
                // "binary" about a perfectly ordinary text file. The BOM path
                // above never reaches here, but a BOM-less one does.
                return DecodedFile(text: str, encoding: enc, hadBOM: false,
                                   byteCount: data.count,
                                   looksBinary: binary && !enc.usesWideCodeUnits)
            }
        }

        // 4. Last resort — treat as Windows-1252; it never fails to decode.
        //    This is exactly the path a binary file lands on, which is why
        //    `looksBinary` travels with the result.
        let lossy = String(data: data, encoding: .windowsCP1252) ?? ""
        return DecodedFile(text: lossy, encoding: .windows1252, hadBOM: false,
                           byteCount: data.count, looksBinary: binary)
    }

    /// A NUL byte near the start is the standard cheap test for "not text".
    /// Shared with Find in Files, which skips such files outright.
    static func looksBinary(_ data: Data) -> Bool {
        data.prefix(4096).contains(0)
    }

    /// Encode a string to Data for the given encoding, prepending a BOM
    /// when requested.
    static func encode(text: String, as encoding: TextEncoding, writeBOM: Bool) throws -> Data {
        guard var data = text.data(using: encoding.foundationEncoding, allowLossyConversion: false) else {
            throw EncodingError.cannotEncode(encoding)
        }
        if writeBOM {
            switch encoding {
            case .utf8, .utf8WithBOM:
                data = Data(BOM.utf8) + data
            case .utf16BE: data = Data(BOM.utf16BE) + data
            case .utf16LE: data = Data(BOM.utf16LE) + data
            case .utf32BE: data = Data(BOM.utf32BE) + data
            case .utf32LE: data = Data(BOM.utf32LE) + data
            default: break   // non-Unicode encodings don't take a BOM
            }
        }
        return data
    }

    /// Write a file atomically with the given encoding.
    static func write(text: String, to url: URL, encoding: TextEncoding, writeBOM: Bool) throws {
        try writeData(encode(text: text, as: encoding, writeBOM: writeBOM), to: url)
    }

    /// The I/O half of `write`, split out so auto save can encode on the main
    /// actor (cheap, and it has to read the document anyway) and do the atomic
    /// replace off it.
    static func writeData(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Private

    private static func decodeByBOM(data: Data) -> DecodedFile? {
        if data.starts(with: BOM.utf8) {
            let rest = data.dropFirst(BOM.utf8.count)
            if let s = String(data: rest, encoding: .utf8) {
                return DecodedFile(text: s, encoding: .utf8WithBOM, hadBOM: true, byteCount: data.count)
            }
        }
        if data.starts(with: BOM.utf32LE) {   // must precede utf16LE test (shares first 2 bytes)
            let rest = data.dropFirst(BOM.utf32LE.count)
            if let s = String(data: rest, encoding: .utf32LittleEndian) {
                return DecodedFile(text: s, encoding: .utf32LE, hadBOM: true, byteCount: data.count)
            }
        }
        if data.starts(with: BOM.utf32BE) {
            let rest = data.dropFirst(BOM.utf32BE.count)
            if let s = String(data: rest, encoding: .utf32BigEndian) {
                return DecodedFile(text: s, encoding: .utf32BE, hadBOM: true, byteCount: data.count)
            }
        }
        if data.starts(with: BOM.utf16LE) {
            let rest = data.dropFirst(BOM.utf16LE.count)
            if let s = String(data: rest, encoding: .utf16LittleEndian) {
                return DecodedFile(text: s, encoding: .utf16LE, hadBOM: true, byteCount: data.count)
            }
        }
        if data.starts(with: BOM.utf16BE) {
            let rest = data.dropFirst(BOM.utf16BE.count)
            if let s = String(data: rest, encoding: .utf16BigEndian) {
                return DecodedFile(text: s, encoding: .utf16BE, hadBOM: true, byteCount: data.count)
            }
        }
        return nil
    }

    /// A cheap sanity check: text shouldn't contain long runs of NUL or
    /// other C0 control codes (except \t \n \r). A wrong encoding typically
    /// decodes to garbage with lots of these.
    private static func isPlausibleText(_ s: String) -> Bool {
        guard !s.isEmpty else { return true }
        var badCount = 0
        var totalCount = 0
        for scalar in s.unicodeScalars.prefix(4096) {
            totalCount += 1
            let v = scalar.value
            if v == 0x09 || v == 0x0A || v == 0x0D { continue }
            if v < 0x20 || v == 0x7F { badCount += 1 }
        }
        guard totalCount > 0 else { return true }
        // Allow up to 1% control chars — real files occasionally have form
        // feeds, vertical tabs, etc., so we don't reject outright.
        return Double(badCount) / Double(totalCount) < 0.01
    }
}
