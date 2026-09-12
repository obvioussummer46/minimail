import Foundation

/// IANA charset names mapped to `String.Encoding`, as a plain table so `MailCore` stays free of CoreFoundation.
public enum Charsets {

    /// Raw values follow Foundation's documented `NSStringEncoding = 0x80000000 | CFStringEncoding` convention
    /// for encodings without a named constant. UNVERIFIED in this session; a wrong value only costs a fallthrough
    /// to UTF-8 or Latin-1 in `decode`.
    private static let isoLatin9 = String.Encoding(rawValue: 0x8000_020F)
    private static let koi8R = String.Encoding(rawValue: 0x8000_0A02)
    private static let gb2312 = String.Encoding(rawValue: 0x8000_0630)
    private static let gbk = String.Encoding(rawValue: 0x8000_0631)
    private static let gb18030 = String.Encoding(rawValue: 0x8000_0632)
    private static let big5 = String.Encoding(rawValue: 0x8000_0A03)
    private static let eucKR = String.Encoding(rawValue: 0x8000_0940)

    private static let table: [String: String.Encoding] = [
        "utf-8": .utf8, "utf8": .utf8,
        "us-ascii": .ascii, "ascii": .ascii, "ansi_x3.4-1968": .ascii, "iso646-us": .ascii, "us": .ascii,
        "iso-8859-1": .isoLatin1, "iso8859-1": .isoLatin1, "iso_8859-1": .isoLatin1,
        "latin1": .isoLatin1, "l1": .isoLatin1, "cp819": .isoLatin1, "ibm819": .isoLatin1,
        "iso-8859-2": .isoLatin2, "iso8859-2": .isoLatin2, "iso_8859-2": .isoLatin2,
        "latin2": .isoLatin2, "l2": .isoLatin2,
        "iso-8859-15": isoLatin9, "iso8859-15": isoLatin9, "iso_8859-15": isoLatin9,
        "latin9": isoLatin9, "latin-9": isoLatin9, "l9": isoLatin9,
        "windows-1250": .windowsCP1250, "cp1250": .windowsCP1250,
        "windows-1251": .windowsCP1251, "cp1251": .windowsCP1251,
        "windows-1252": .windowsCP1252, "cp1252": .windowsCP1252, "x-cp1252": .windowsCP1252,
        "windows-1253": .windowsCP1253, "cp1253": .windowsCP1253,
        "windows-1254": .windowsCP1254, "cp1254": .windowsCP1254,
        "koi8-r": koi8R, "koi8r": koi8R,
        "shift_jis": .shiftJIS, "shift-jis": .shiftJIS, "sjis": .shiftJIS, "x-sjis": .shiftJIS,
        "ms_kanji": .shiftJIS, "cp932": .shiftJIS, "windows-31j": .shiftJIS,
        "euc-jp": .japaneseEUC, "eucjp": .japaneseEUC, "x-euc-jp": .japaneseEUC,
        "iso-2022-jp": .iso2022JP, "csiso2022jp": .iso2022JP,
        "gb2312": gb2312, "gb_2312-80": gb2312, "csgb2312": gb2312, "euc-cn": gb2312, "x-euc-cn": gb2312,
        "gbk": gbk, "cp936": gbk, "ms936": gbk, "windows-936": gbk,
        "gb18030": gb18030,
        "big5": big5, "big-5": big5, "csbig5": big5, "cp950": big5, "big5-hkscs": big5,
        "euc-kr": eucKR, "ks_c_5601-1987": eucKR, "cp949": eucKR,
        "utf-16": .utf16, "utf16": .utf16,
        "utf-16be": .utf16BigEndian,
        "utf-16le": .utf16LittleEndian,
        "macintosh": .macOSRoman, "x-mac-roman": .macOSRoman,
    ]

    /// Trims, strips surrounding quotes and an RFC 2231 `*lang` suffix, lowercases, then looks the name up.
    public static func encoding(forIANA name: String) -> String.Encoding? {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") { trimmed.removeFirst() }
        if trimmed.hasSuffix("\"") { trimmed.removeLast() }
        if let star = trimmed.firstIndex(of: "*") { trimmed = String(trimmed[..<star]) }
        return table[trimmed.lowercased()]
    }

    /// Decode chain: the named charset, then UTF-8, then Latin-1, which accepts any byte sequence. A leading
    /// byte-order mark is removed.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let charset, let encoding = encoding(forIANA: charset),
            let decoded = String(data: data, encoding: encoding)
        {
            return strippingBOM(decoded)
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return strippingBOM(decoded)
        }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    private static func strippingBOM(_ string: String) -> String {
        string.hasPrefix("\u{FEFF}") ? String(string.dropFirst()) : string
    }
}
