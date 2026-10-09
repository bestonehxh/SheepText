/// What makes one brace language different from another, as data.
struct CFamilySpec: Sendable {
    enum Backtick: Sendable { case none, template, raw, identifier }

    let language: SyntaxLanguage
    /// keyword / type.builtin / boolean / constant.builtin / variable.builtin /
    /// function.builtin, by word.
    let words: WordTable
    /// Keywords after which the next identifier is a function being defined.
    let functionIntroducers: WordTable
    /// Keywords after which the next identifier is a type being defined.
    let typeIntroducers: WordTable
    var nestedComments = false
    var hashComments = false
    var charLiterals = true
    var singleQuoteStrings = false
    var backtick: Backtick = .none
    var tripleQuotes = false
    /// `"` and `'` strings may run across lines (Rust, PHP).
    var multilineStrings = false
    var regexLiterals = false
    var annotations = false
    var macroBang = false
    var lifetimes = false
    var dollarVariables = false
    var dollarIdentifiers = false
    var arrowIsMemberAccess = false
    var capitalizedTypes = true
    var genericCalls = false
    /// `Name(` builds a value (Swift, Rust, Scala, Java's `new`, JS). In Go,
    /// C and C#, a capitalised call is just a call.
    var constructorCalls = true
    /// `name {` after a dot is a call with a trailing closure (Swift, Scala).
    var trailingClosures = false
    /// Words that start an import path, whose segments are not properties.
    var importWords: [String] = []

    static func spec(for language: SyntaxLanguage) -> CFamilySpec {
        switch language {
        case .swift: return swift
        case .javascript: return javascript
        case .typescript: return typescript
        case .go: return go
        case .rust: return rust
        case .java: return java
        case .c: return c
        case .csharp: return csharp
        case .scala: return scala
        case .php: return php
        default: return c
        }
    }

    private static func table(_ words: [String], caseInsensitive: Bool = false) -> WordTable {
        WordTable([(.keyword, words)], caseInsensitive: caseInsensitive)
    }

    // MARK: Swift

    static let swift: CFamilySpec = {
        var spec = CFamilySpec(
            language: .swift,
            words: WordTable([
                (.keyword, [
                    "actor", "any", "as", "associatedtype", "async", "await", "borrowing", "break", "case",
                    "catch", "class", "consume", "consuming", "continue", "convenience", "copy", "default",
                    "defer", "deinit", "didSet", "discard", "do", "dynamic", "each", "else", "enum",
                    "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if",
                    "import", "in", "indirect", "infix", "init", "inout", "internal", "is", "isolated",
                    "lazy", "let", "macro", "mutating", "nonisolated", "nonmutating", "open", "operator",
                    "optional", "override", "package", "postfix", "precedencegroup", "prefix", "private",
                    "protocol", "public", "repeat", "required", "rethrows", "return", "sending", "set",
                    "some", "static", "struct", "subscript", "super", "switch", "throw", "throws", "try",
                    "typealias", "unowned", "var", "weak", "where", "while", "willSet",
                ]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["nil"]),
                (.variableBuiltin, ["self", "Self"]),
                (.typeBuiltin, [
                    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
                    "Float", "Double", "Bool", "String", "Character", "Void", "Never", "Any", "AnyObject",
                    "Optional", "Array", "Dictionary", "Set", "Substring", "Error", "Result", "CGFloat",
                ]),
            ]),
            functionIntroducers: table(["func", "macro"]),
            typeIntroducers: table([
                "class", "struct", "enum", "protocol", "extension", "typealias", "associatedtype", "actor",
                "precedencegroup",
            ])
        )
        spec.nestedComments = true
        spec.charLiterals = false
        spec.backtick = .identifier
        spec.tripleQuotes = true
        spec.annotations = true
        spec.genericCalls = true
        spec.trailingClosures = true
        spec.importWords = ["import"]
        return spec
    }()

    // MARK: JavaScript / TypeScript

    private static let jsKeywords = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function",
        "get", "if", "import", "in", "instanceof", "let", "new", "of", "return", "set", "static",
        "switch", "throw", "try", "typeof", "var", "void", "while", "with", "yield",
    ]
    private static let jsBuiltins: [(SyntaxScope, [String])] = [
        (.boolean, ["true", "false"]),
        (.constantBuiltin, ["null", "undefined", "NaN", "Infinity"]),
        (.variableBuiltin, ["this", "super", "arguments", "globalThis"]),
        (.functionBuiltin, ["require"]),
    ]

    static let javascript: CFamilySpec = {
        var spec = CFamilySpec(
            language: .javascript,
            words: WordTable([(.keyword, jsKeywords)] + jsBuiltins),
            functionIntroducers: table(["function"]),
            typeIntroducers: table(["class", "extends"])
        )
        spec.charLiterals = false
        spec.singleQuoteStrings = true
        spec.backtick = .template
        spec.regexLiterals = true
        spec.annotations = true
        spec.dollarIdentifiers = true
        return spec
    }()

    static let typescript: CFamilySpec = {
        var spec = CFamilySpec(
            language: .typescript,
            words: WordTable([
                (.keyword, jsKeywords + [
                    "abstract", "accessor", "asserts", "declare", "enum", "global", "implements", "infer",
                    "interface", "is", "keyof", "module", "namespace", "out", "override", "private",
                    "protected", "public", "readonly", "require", "satisfies", "type", "unique", "using",
                ]),
                (.typeBuiltin, [
                    "any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown",
                ]),
            ] + jsBuiltins),
            functionIntroducers: table(["function"]),
            typeIntroducers: table(["class", "extends", "implements", "interface", "type", "enum", "namespace"])
        )
        spec.charLiterals = false
        spec.singleQuoteStrings = true
        spec.backtick = .template
        spec.regexLiterals = true
        spec.annotations = true
        spec.dollarIdentifiers = true
        spec.genericCalls = true
        return spec
    }()

    // MARK: Go

    static let go: CFamilySpec = {
        var spec = CFamilySpec(
            language: .go,
            words: WordTable([
                (.keyword, [
                    "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough",
                    "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range",
                    "return", "select", "struct", "switch", "type", "var",
                ]),
                (.typeBuiltin, [
                    "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32",
                    "float64", "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8",
                    "uint16", "uint32", "uint64", "uintptr",
                ]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["nil", "iota"]),
                (.functionBuiltin, [
                    "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make",
                    "max", "min", "new", "panic", "print", "println", "real", "recover",
                ]),
            ]),
            functionIntroducers: table(["func"]),
            typeIntroducers: table(["type"])
        )
        spec.backtick = .raw
        spec.constructorCalls = false
        spec.importWords = ["package"]
        return spec
    }()

    // MARK: Rust

    static let rust: CFamilySpec = {
        var spec = CFamilySpec(
            language: .rust,
            words: WordTable([
                (.keyword, [
                    "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
                    "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                    "pub", "ref", "return", "static", "struct", "super", "trait", "type", "union", "unsafe",
                    "use", "where", "while", "yield", "macro_rules",
                ]),
                (.typeBuiltin, [
                    "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str", "u8",
                    "u16", "u32", "u64", "u128", "usize",
                ]),
                (.boolean, ["true", "false"]),
                (.variableBuiltin, ["self", "Self"]),
            ]),
            functionIntroducers: table(["fn"]),
            typeIntroducers: table(["struct", "enum", "trait", "type", "union", "impl"])
        )
        spec.nestedComments = true
        spec.multilineStrings = true
        spec.macroBang = true
        spec.lifetimes = true
        return spec
    }()

    // MARK: Java

    static let java: CFamilySpec = {
        var spec = CFamilySpec(
            language: .java,
            words: WordTable([
                (.keyword, [
                    "abstract", "assert", "break", "case", "catch", "class", "const", "continue", "default",
                    "do", "else", "enum", "exports", "extends", "final", "finally", "for", "goto", "if",
                    "implements", "import", "instanceof", "interface", "module", "native", "new", "non-sealed",
                    "open", "opens", "package", "permits", "private", "protected", "provides", "public",
                    "record", "requires", "return", "sealed", "static", "strictfp", "super", "switch",
                    "synchronized", "throw", "throws", "to", "transient", "transitive", "try", "uses", "var",
                    "volatile", "when", "while", "with", "yield",
                ]),
                (.typeBuiltin, ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void"]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["null"]),
                (.variableBuiltin, ["this"]),
            ]),
            functionIntroducers: table([]),
            typeIntroducers: table(["class", "interface", "enum", "record", "extends", "implements"])
        )
        spec.tripleQuotes = true
        spec.annotations = true
        spec.importWords = ["import", "package"]
        return spec
    }()

    // MARK: C

    static let c: CFamilySpec = {
        var spec = CFamilySpec(
            language: .c,
            words: WordTable([
                (.keyword, [
                    "alignas", "alignof", "asm", "auto", "break", "case", "const", "constexpr", "continue",
                    "default", "do", "else", "enum", "extern", "for", "goto", "if", "inline", "register",
                    "restrict", "return", "sizeof", "static", "static_assert", "struct", "switch",
                    "thread_local", "typedef", "typeof", "union", "volatile", "while", "_Alignas",
                    "_Alignof", "_Atomic", "_Generic", "_Noreturn", "_Static_assert", "_Thread_local",
                    // Enough C++ that a header or a .cpp fence reads sensibly.
                    "class", "namespace", "template", "typename", "public", "private", "protected",
                    "virtual", "override", "new", "delete", "operator", "using", "try", "catch", "throw",
                    "noexcept", "explicit", "friend", "mutable", "concept", "requires", "co_await",
                    "co_return", "co_yield", "decltype", "final",
                    // Objective-C's words that are not `@`-prefixed.
                    "id", "instancetype",
                ]),
                (.typeBuiltin, [
                    "void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "bool",
                    "_Bool", "_Complex", "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t",
                    "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t", "uint32_t",
                    "uint64_t", "wchar_t", "char16_t", "char32_t", "char8_t", "auto_t", "BOOL",
                ]),
                (.boolean, ["true", "false", "YES", "NO"]),
                (.constantBuiltin, ["NULL", "nullptr", "nil", "Nil"]),
                (.variableBuiltin, ["this", "self", "super"]),
            ]),
            functionIntroducers: table([]),
            typeIntroducers: table(["struct", "enum", "union", "class", "namespace", "typename"])
        )
        spec.arrowIsMemberAccess = true
        spec.capitalizedTypes = false
        spec.annotations = true
        spec.constructorCalls = false
        return spec
    }()

    // MARK: C#

    static let csharp: CFamilySpec = {
        var spec = CFamilySpec(
            language: .csharp,
            words: WordTable([
                (.keyword, [
                    "abstract", "add", "alias", "and", "as", "ascending", "async", "await", "base",
                    "break", "by", "case", "catch", "checked", "class", "const", "continue", "default",
                    "delegate", "descending", "do", "else", "enum", "equals", "event", "explicit", "extern",
                    "finally", "fixed", "for", "foreach", "from", "get", "global", "goto", "group",
                    "if", "implicit", "in", "init", "interface", "internal", "into", "is", "join", "let",
                    "lock", "managed", "namespace", "new", "nint", "not", "notnull", "nuint", "on", "operator",
                    "or", "orderby", "out", "override", "params", "partial", "private", "protected",
                    "public", "readonly", "record", "ref", "remove", "required", "return", "scoped",
                    "sealed", "select", "set", "sizeof", "stackalloc", "static", "struct", "switch",
                    "throw", "try", "typeof", "unchecked", "unmanaged", "unsafe", "using", "var",
                    "virtual", "volatile", "when", "where", "while", "with", "yield",
                ]),
                (.typeBuiltin, [
                    "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long", "object",
                    "sbyte", "short", "string", "uint", "ulong", "ushort", "void",
                ]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["null"]),
                (.variableBuiltin, ["this"]),
            ]),
            functionIntroducers: table([]),
            typeIntroducers: table(["class", "struct", "interface", "enum", "record", "namespace", "delegate"])
        )
        spec.tripleQuotes = true
        spec.constructorCalls = false
        spec.importWords = ["using"]
        spec.genericCalls = true
        return spec
    }()

    // MARK: Scala

    static let scala: CFamilySpec = {
        var spec = CFamilySpec(
            language: .scala,
            words: WordTable([
                (.keyword, [
                    "abstract", "case", "catch", "class", "def", "derives", "do", "else", "end", "enum",
                    "export", "extends", "extension", "final", "finally", "for", "forSome", "given", "if",
                    "implicit", "import", "infix", "inline", "lazy", "match", "new", "object", "opaque",
                    "open", "override", "package", "private", "protected", "return", "sealed", "then",
                    "throw", "trait", "transparent", "try", "type", "using", "val", "var", "while", "with",
                    "yield",
                ]),
                (.typeBuiltin, [
                    "Any", "AnyRef", "AnyVal", "Boolean", "Byte", "Char", "Double", "Float", "Int", "Long",
                    "Nothing", "Null", "Short", "String", "Unit",
                ]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["null", "None", "Nil"]),
                (.variableBuiltin, ["this", "super"]),
            ]),
            functionIntroducers: table(["def"]),
            typeIntroducers: table(["class", "object", "trait", "type", "enum", "extends", "with"])
        )
        spec.nestedComments = true
        spec.backtick = .identifier
        spec.tripleQuotes = true
        spec.annotations = true
        spec.trailingClosures = true
        spec.importWords = ["import", "package"]
        return spec
    }()

    // MARK: PHP (code sections)

    static let php: CFamilySpec = {
        var spec = CFamilySpec(
            language: .php,
            words: WordTable([
                (.keyword, [
                    "abstract", "and", "as", "break", "callable", "case", "catch", "class", "clone", "const",
                    "continue", "declare", "default", "do", "echo", "else", "elseif", "empty", "enddeclare",
                    "endfor", "endforeach", "endif", "endswitch", "endwhile", "enum", "eval", "exit",
                    "extends", "final", "finally", "fn", "for", "foreach", "function", "global", "goto",
                    "if", "implements", "include", "include_once", "instanceof", "insteadof", "interface",
                    "isset", "list", "match", "namespace", "new", "or", "print", "private", "protected",
                    "public", "readonly", "require", "require_once", "return", "static", "switch", "throw",
                    "trait", "try", "unset", "use", "var", "while", "xor", "yield", "die",
                ]),
                (.typeBuiltin, [
                    "array", "bool", "float", "int", "iterable", "mixed", "never", "object", "string",
                    "void", "self", "parent",
                ]),
                (.boolean, ["true", "false"]),
                (.constantBuiltin, ["null"]),
            ], caseInsensitive: true),
            functionIntroducers: table(["function", "fn"], caseInsensitive: true),
            typeIntroducers: table(["class", "interface", "trait", "enum", "extends", "implements", "new"], caseInsensitive: true)
        )
        spec.hashComments = true
        spec.charLiterals = false
        spec.singleQuoteStrings = true
        spec.multilineStrings = true
        spec.dollarVariables = true
        spec.arrowIsMemberAccess = true
        spec.constructorCalls = false
        return spec
    }()
}

enum SwiftWords {
    static let directives = WordTable([(.keyword, [
        "if", "elseif", "else", "endif", "available", "unavailable", "sourceLocation", "warning", "error",
    ])])
}
