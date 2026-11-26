import UIKit

enum CodeLanguage: String {
    case swift, c, objc, js, ts, python, ruby, go, rust, java, kotlin, csharp, php, dart, lua, shell, sql
    case json, xml, html, css, yaml, toml, ini, markdown, smali, plain

    static func detect(_ url: URL) -> CodeLanguage {
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "c", "h", "cpp", "hpp", "cc", "cxx", "hh", "metal": return .c
        case "m", "mm": return .objc
        case "js", "mjs", "cjs", "jsx": return .js
        case "ts", "tsx": return .ts
        case "py", "pyw": return .python
        case "rb": return .ruby
        case "go": return .go
        case "rs": return .rust
        case "java", "gradle": return .java
        case "kt", "kts": return .kotlin
        case "cs": return .csharp
        case "php": return .php
        case "dart": return .dart
        case "lua": return .lua
        case "sh", "bash", "zsh", "command": return .shell
        case "sql": return .sql
        case "json", "jsonc", "geojson", "webmanifest": return .json
        case "xml", "plist", "entitlements", "svg", "storyboard", "xib", "xcscheme", "csproj": return .xml
        case "html", "htm", "xhtml", "vue": return .html
        case "css", "scss", "less": return .css
        case "yml", "yaml": return .yaml
        case "toml": return .toml
        case "ini", "conf", "cfg", "properties", "env", "xcconfig", "strings": return .ini
        case "md", "markdown": return .markdown
        case "smali": return .smali
        default:
            let n = url.lastPathComponent.lowercased()
            if ["makefile", "dockerfile", "podfile", "gemfile", "fastfile"].contains(n) { return .shell }
            return .plain
        }
    }

    var displayName: String {
        switch self {
        case .js: return "JavaScript"
        case .ts: return "TypeScript"
        case .objc: return "Objective-C"
        case .csharp: return "C#"
        case .c: return "C/C++"
        case .json: return "JSON"
        case .xml: return "XML"
        case .html: return "HTML"
        case .css: return "CSS"
        case .yaml: return "YAML"
        case .toml: return "TOML"
        case .sql: return "SQL"
        case .php: return "PHP"
        case .plain: return "Plain text"
        default: return rawValue.capitalized
        }
    }
}

/// Lightweight regex-based syntax highlighter (dark palette).
final class Highlighter {
    static let font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let text = UIColor(red: 0.84, green: 0.86, blue: 0.88, alpha: 1)
    static let keyword = UIColor(red: 0.78, green: 0.47, blue: 0.87, alpha: 1)
    static let string = UIColor(red: 0.60, green: 0.77, blue: 0.47, alpha: 1)
    static let number = UIColor(red: 0.82, green: 0.60, blue: 0.40, alpha: 1)
    static let comment = UIColor(red: 0.45, green: 0.50, blue: 0.56, alpha: 1)
    static let type = UIColor(red: 0.90, green: 0.75, blue: 0.48, alpha: 1)
    static let tag = UIColor(red: 0.88, green: 0.42, blue: 0.46, alpha: 1)
    static let attr = UIColor(red: 0.38, green: 0.69, blue: 0.94, alpha: 1)

    struct Rule {
        let regex: NSRegularExpression
        let color: UIColor
        let group: Int
    }

    private static var cache: [CodeLanguage: [Rule]] = [:]

    private static func re(_ p: String, _ opts: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: p, options: opts)) ?? (try! NSRegularExpression(pattern: "(?!)"))
    }

    private static func kw(_ words: String) -> NSRegularExpression {
        let list = words.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "|")
        return re("\\b(?:\(list))\\b")
    }

    static let dq = "\"(?:\\\\.|[^\"\\\\\\n])*\""
    static let sq = "'(?:\\\\.|[^'\\\\\\n])*'"
    static let bt = "`(?:\\\\.|[^`\\\\])*`"
    static let num = "\\b(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.\\d+)?(?:[eE][+-]?\\d+)?)\\b"
    static let slashComment = "//[^\\n]*"
    static let block = "/\\*[\\s\\S]*?\\*/"
    static let hashComment = "#[^\\n]*"
    static let typeName = "\\b[A-Z][A-Za-z0-9_]*\\b"

    static func rules(for lang: CodeLanguage) -> [Rule] {
        if let r = cache[lang] { return r }
        var r: [Rule] = []
        func add(_ regex: NSRegularExpression, _ c: UIColor, _ g: Int = 0) { r.append(Rule(regex: regex, color: c, group: g)) }
        func cLike(_ words: String, strings: [String] = [dq, sq], types: Bool = true, hash: Bool = false) {
            add(re(num), number)
            if types { add(re(typeName), type) }
            add(kw(words), keyword)
            for s in strings { add(re(s), string) }
            if hash { add(re(hashComment), comment) }
            add(re(slashComment), comment)
            add(re(block), comment)
        }
        switch lang {
        case .swift:
            cLike("import let var func class struct enum protocol extension return if else guard switch case default for in while repeat break continue defer do try catch throw throws rethrows async await actor init deinit self Self super nil true false public private fileprivate internal open static final override mutating inout some any where typealias associatedtype weak unowned lazy get set willSet didSet is as subscript operator convenience required @main @State @Published @MainActor @escaping", strings: [dq])
            add(re("@[A-Za-z_]+"), attr)
        case .c, .objc:
            cLike("auto break case char const continue default do double else enum extern float for goto if inline int long register return short signed sizeof static struct switch typedef union unsigned void volatile while class namespace template typename public private protected virtual override new delete this nullptr true false bool using try catch throw constexpr @interface @implementation @end @property @synthesize @protocol @selector self super nil YES NO id instancetype nonatomic strong weak assign copy readonly")
            add(re("^\\s*#\\s*\\w+[^\\n]*", [.anchorsMatchLines]), attr)
        case .js, .ts:
            cLike("var let const function return if else for while do break continue switch case default new delete typeof instanceof in of try catch finally throw class extends super this null undefined true false import export from as async await yield static get set interface type enum implements private public protected readonly declare namespace keyof void any number string boolean never unknown", strings: [dq, sq, bt])
        case .java, .kotlin, .csharp, .dart:
            cLike("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null fun val var when is in object companion data sealed override open internal lateinit suspend namespace using string bool decimal async await dynamic late required var final")
            add(re("@[A-Za-z_]+"), attr)
        case .go:
            cLike("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota string int int64 float64 bool byte error", strings: [dq, bt])
        case .rust:
            cLike("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while Some None Ok Err")
        case .php:
            cLike("abstract and array as break callable case catch class clone const continue declare default do echo else elseif empty enddeclare endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global goto if implements include instanceof insteadof interface isset list match namespace new or print private protected public require return static switch throw trait try unset use var while yield true false null", hash: true)
            add(re("\\$[A-Za-z_][A-Za-z0-9_]*"), attr)
        case .python:
            add(re(num), number)
            add(re(typeName), type)
            add(kw("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self print"), keyword)
            add(re("@[A-Za-z_.]+"), attr)
            add(re("(?:\"\"\"[\\s\\S]*?\"\"\"|'''[\\s\\S]*?''')"), string)
            add(re(dq), string); add(re(sq), string)
            add(re(hashComment), comment)
        case .ruby:
            add(re(num), number)
            add(re(typeName), type)
            add(kw("alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_accessor puts"), keyword)
            add(re(":[A-Za-z_]+"), attr)
            add(re(dq), string); add(re(sq), string)
            add(re(hashComment), comment)
        case .lua:
            add(re(num), number)
            add(kw("and break do else elseif end false for function goto if in local nil not or repeat return then true until while require self"), keyword)
            add(re(dq), string); add(re(sq), string)
            add(re("--[^\\n]*"), comment)
            add(re("--\\[\\[[\\s\\S]*?\\]\\]"), comment)
        case .shell:
            add(re(num), number)
            add(kw("if then else elif fi for while do done case esac in function return exit export local echo cd ls rm cp mv mkdir sudo source set unset read shift true false"), keyword)
            add(re("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?"), attr)
            add(re(dq), string); add(re(sq), string)
            add(re("(?:^|\\s)#[^\\n]*", [.anchorsMatchLines]), comment)
        case .sql:
            add(re(num), number)
            add(re("\\b(?i:select|from|where|insert|into|values|update|set|delete|create|table|drop|alter|add|index|join|left|right|inner|outer|on|group|by|order|having|limit|offset|and|or|not|null|is|as|distinct|primary|key|foreign|references|union|all|case|when|then|else|end|in|like|between|exists|count|sum|avg|min|max)\\b"), keyword)
            add(re(sq), string); add(re(dq), string)
            add(re("--[^\\n]*"), comment)
            add(re(block), comment)
        case .json:
            add(re(num), number)
            add(kw("true false null"), keyword)
            add(re(dq), string)
            add(re("(\"(?:\\\\.|[^\"\\\\\\n])*\")\\s*:"), attr, 1)
        case .xml, .html:
            add(re("</?[A-Za-z_][\\w:.-]*|/?>"), tag)
            add(re("\\s([A-Za-z_:][\\w:.-]*)\\s*="), attr, 1)
            add(re(dq), string)
            add(re(sq), string)
            add(re("<!\\[CDATA\\[[\\s\\S]*?\\]\\]>"), comment)
            add(re("<!--[\\s\\S]*?-->"), comment)
            add(re("<[!?][^>]*>"), comment)
        case .css:
            add(re(num + "(?:px|em|rem|%|vh|vw|s|ms|deg)?"), number)
            add(re("#[0-9a-fA-F]{3,8}\\b"), number)
            add(re("([\\w-]+)\\s*:"), attr, 1)
            add(re("@[\\w-]+"), keyword)
            add(re(dq), string); add(re(sq), string)
            add(re(block), comment)
        case .yaml:
            add(re(num), number)
            add(kw("true false null yes no on off"), keyword)
            add(re("^\\s*-?\\s*([\\w.\\-\"' ]+):", [.anchorsMatchLines]), attr, 1)
            add(re(dq), string); add(re(sq), string)
            add(re("(?:^|\\s)#[^\\n]*", [.anchorsMatchLines]), comment)
        case .toml, .ini:
            add(re(num), number)
            add(kw("true false"), keyword)
            add(re("^\\s*\\[[^\\]\\n]+\\]", [.anchorsMatchLines]), tag)
            add(re("^\\s*([\\w.\\-\"]+)\\s*=", [.anchorsMatchLines]), attr, 1)
            add(re(dq), string)
            add(re("^\\s*[#;][^\\n]*", [.anchorsMatchLines]), comment)
            add(re("^\\s*//[^\\n]*", [.anchorsMatchLines]), comment)
        case .markdown:
            add(re("^#{1,6} [^\\n]*", [.anchorsMatchLines]), keyword)
            add(re("\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__"), type)
            add(re("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"), attr)
            add(re("^\\s*(?:[-*+]|\\d+\\.) ", [.anchorsMatchLines]), tag)
            add(re("`[^`\\n]+`"), string)
            add(re("```[\\s\\S]*?```"), string)
            add(re("^>[^\\n]*", [.anchorsMatchLines]), comment)
        case .smali:
            add(re(num), number)
            add(re("^\\s*\\.[a-z]+", [.anchorsMatchLines]), keyword)
            add(re("\\b(?:invoke-[a-z/-]+|move[a-z/-]*|const[a-z/-]*|return[a-z-]*|if-[a-z]+|goto|new-instance|iget[a-z-]*|iput[a-z-]*|sget[a-z-]*|sput[a-z-]*|check-cast)\\b"), tag)
            add(re("\\b[vp]\\d+\\b"), attr)
            add(re("L[\\w/$]+;"), type)
            add(re(dq), string)
            add(re("#[^\\n]*"), comment)
        case .plain:
            break
        }
        cache[lang] = r
        return r
    }

    static func highlight(_ storage: NSTextStorage, language: CodeLanguage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: text], range: full)
        if storage.length <= 400_000 {
            let s = storage.string
            for rule in rules(for: language) {
                rule.regex.enumerateMatches(in: s, range: full) { m, _, _ in
                    guard let m else { return }
                    let range = m.range(at: rule.group)
                    if range.location != NSNotFound, range.length > 0 {
                        storage.addAttribute(.foregroundColor, value: rule.color, range: range)
                    }
                }
            }
        }
        storage.endEditing()
    }
}
