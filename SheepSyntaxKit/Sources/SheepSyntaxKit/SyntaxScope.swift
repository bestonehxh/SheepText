/// What a run of text IS, never what colour it is.
///
/// `captureName` is the dotted scope name the host resolves through its own
/// style table (SheepText: `HighlightStyleTable.styleID(forCapture:)`), the same
/// hierarchy tree-sitter captures used — so `"function.method"` falls back to
/// `"function"` if the host has no entry for the longer name.
///
/// There is deliberately no `variable` or `operator` scope: in every palette
/// SheepText has shipped they are the editor's base foreground, so emitting
/// them only costs runs. `punctuation` exists for one caller — the commas of a
/// validated VLAN list, which the network config layer has always painted.
public enum SyntaxScope: UInt8, CaseIterable, Sendable {
    case none = 0
    case comment
    case commentDoc
    case string
    case stringEscape
    case stringRegex
    case stringSpecial
    case stringSymbol
    case number
    case boolean
    case character
    case constant
    case constantBuiltin
    case keyword
    case keywordDirective
    case function
    case functionBuiltin
    case functionMacro
    case functionMethod
    case constructor
    case type
    case typeBuiltin
    case attribute
    case property
    case label
    case variableBuiltin
    case variableParameter
    case variableSpecial
    case tag
    case tagAttribute
    case tagDoctype
    case punctuation
    case punctuationSpecial
    case punctuationListMarker
    case embedded
    case title
    case emphasis
    case strong
    case literal
    case uri
    case reference
    case quote
    case logError
    case logWarning
    case logSuccess
    case diffPlus
    case diffMinus
    case diffDelta
    case diffHeader
    case error
    case warning
    // network_config: one scope per SheepTerm rule colour, so the editor paints
    // exactly what the terminal paints (see `NetworkConfigHighlighter.ruleScopes`).
    case networkVlan
    case networkInterface
    case networkAddress
    case networkMask
    case networkMac
    case networkGood
    case networkWarn
    case networkBad

    public var captureName: String {
        switch self {
        case .none: return ""
        case .comment: return "comment"
        case .commentDoc: return "comment.doc"
        case .string: return "string"
        case .stringEscape: return "string.escape"
        case .stringRegex: return "string.regex"
        case .stringSpecial: return "string.special"
        case .stringSymbol: return "string.special.symbol"
        case .number: return "number"
        case .boolean: return "boolean"
        case .character: return "character"
        case .constant: return "constant"
        case .constantBuiltin: return "constant.builtin"
        case .keyword: return "keyword"
        case .keywordDirective: return "keyword.directive"
        case .function: return "function"
        case .functionBuiltin: return "function.builtin"
        case .functionMacro: return "function.macro"
        case .functionMethod: return "function.method"
        case .constructor: return "constructor"
        case .type: return "type"
        case .typeBuiltin: return "type.builtin"
        case .attribute: return "attribute"
        case .property: return "property"
        case .label: return "label"
        case .variableBuiltin: return "variable.builtin"
        case .variableParameter: return "variable.parameter"
        case .variableSpecial: return "variable.special"
        case .tag: return "tag"
        case .tagAttribute: return "tag.attribute"
        case .tagDoctype: return "tag.doctype"
        case .punctuation: return "punctuation"
        case .punctuationSpecial: return "punctuation.special"
        case .punctuationListMarker: return "punctuation.list_marker"
        case .embedded: return "embedded"
        case .title: return "text.title"
        case .emphasis: return "text.emphasis"
        case .strong: return "text.strong"
        case .literal: return "text.literal"
        case .uri: return "text.uri"
        case .reference: return "text.reference"
        case .quote: return "markup.quote"
        case .logError: return "log.error"
        case .logWarning: return "log.warning"
        case .logSuccess: return "log.success"
        case .diffPlus: return "diff.plus"
        case .diffMinus: return "diff.minus"
        case .diffDelta: return "diff.delta"
        case .diffHeader: return "title"
        case .error: return "error"
        case .warning: return "warning"
        case .networkVlan: return "network.vlan"
        case .networkInterface: return "network.interface"
        case .networkAddress: return "network.address"
        case .networkMask: return "network.mask"
        case .networkMac: return "network.mac"
        case .networkGood: return "network.state.good"
        case .networkWarn: return "network.state.warn"
        case .networkBad: return "network.state.bad"
        }
    }
}

/// One highlighted span, in UTF-16 code units over the full text.
public struct SyntaxRun: Equatable, Hashable, Sendable {
    public var location: Int
    public var length: Int
    public var scope: SyntaxScope

    public init(location: Int, length: Int, scope: SyntaxScope) {
        self.location = location
        self.length = length
        self.scope = scope
    }

    public var end: Int { location + length }
}
