import Foundation

/// Deterministic cleanup of raw recognizer output: filler words and phrases, hesitation
/// sounds, stuttered repeats, phrases recognizers hallucinate on silence, and Latin letters
/// that leak into Cyrillic words. Runs before the custom dictionary on every transcription
/// path, needs no language model, and finishes in well under a millisecond.
///
/// Built-in language packs only ever match words written in their own script, so every
/// enabled pack is applied to every transcription; no language detection is needed.
nonisolated enum SpeechCleanup {
    struct Options: Hashable, Sendable {
        var isEnabled = true
        /// User-managed words and phrases, removed wherever they occur.
        var customFillers: [String] = []
        var languagePackIDs: Set<String> = Set(LanguagePack.builtIn.map(\.id))
        var removesRepeatedWords = true
        var removesHallucinations = true
        var fixesLatinInCyrillic = true
    }

    struct LanguagePack: Sendable {
        let id: String
        let displayName: String
        /// Multi-word fillers that carry no meaning; removed wherever they occur.
        let phrases: [String]
        /// Words that are fillers only when set off by punctuation or a sentence boundary
        /// ("Ну, …", "…, вот, …"). Elsewhere they are ordinary words ("типа данных").
        let guardedWords: [String]
        /// Hesitation sounds as regular-expression alternatives matched against a whole word.
        let hesitations: [String]
        /// Phrases the recognizer hallucinates on silence or music, as regular expressions.
        /// Patterns are case-sensitive unless they start with `(?i)`.
        let hallucinations: [String]
        /// Words that open a clause. A filler framed by commas takes both commas with it,
        /// unless one of these follows: "форк, вот, который" keeps the comma "который" needs.
        let clauseOpeners: [String]

        static let english = LanguagePack(
            id: "en",
            displayName: "English",
            phrases: ["you know", "i mean", "sort of like", "kind of like"],
            guardedWords: ["like", "well", "okay", "basically", "actually", "literally", "right"],
            hesitations: ["u+m+", "u+h+", "e+r+", "a+h+", "e+h+", "h+m+", "m{2,}"],
            hallucinations: [
                #"(?i)\bthanks?\s+(?:you\s+)?for\s+watching\b[.!]?"#,
                #"(?i)\bplease\s+subscribe\b[.!]?"#,
                #"(?i)\blike\s+and\s+subscribe\b[.!]?"#,
                #"(?i)\bsubscribe\s+to\s+(?:my|the|our)\s+channel\b[.!]?"#,
            ],
            clauseOpeners: [
                "which", "that", "who", "whom", "whose", "because", "but", "and", "or", "nor",
                "so", "if", "when", "while", "where", "although", "though", "unless", "until",
                "since", "as", "then", "yet",
            ]
        )

        static let russian = LanguagePack(
            id: "ru",
            displayName: "Russian",
            phrases: [
                "как бы", "это самое", "так сказать", "в общем-то", "в общем то",
                "короче говоря", "грубо говоря", "собственно говоря", "скажем так",
                "как говорится", "типа того", "ну вот", "ну это", "вот это самое",
                "как его", "как это", "не знаю", "я не знаю",
            ],
            guardedWords: [
                "ну", "вот", "типа", "короче", "значит", "собственно", "получается",
                "вообще", "в общем", "в принципе", "по сути", "слушай", "слушайте",
                "смотри", "смотрите", "понимаешь", "понимаете", "знаешь", "знаете",
                "то есть", "допустим", "например",
            ],
            hesitations: ["э+", "э(?:-э)+", "эм+", "мм+", "м-м(?:-м)*", "а(?:-а)+", "а{3,}", "эээ+"],
            hallucinations: [
                #"Субтитры\s+(?:создавал|создал|добавил|подогнал)\s+[«"]?\S+[»"]?!?"#,
                #"Редактор субтитров\s+[А-ЯЁ]\.[А-ЯЁ][а-яё]+(?:\s+Корректор\s+[А-ЯЁ]\.[А-ЯЁ][а-яё]+)?"#,
                #"Спасибо за субтитры!?"#,
                #"Продолжение следует\.{0,3}"#,
                #"ПОДПИШИСЬ(?:\s+НА\s+КАНАЛ)?!?"#,
                #"DimaTorzok"#,
                #"\b[А-ЯЁ]{2,}(?:\s+[А-ЯЁ]{2,})*\s+(?:МУЗЫКА|МЕЛОДИЯ)\b"#,
                #"\bМУЗЫКАЛЬНАЯ\s+ЗАСТАВКА\b"#,
                #"\b(?:АПЛОДИСМЕНТЫ|ВЫСТРЕЛЫ|ШУМ\s+ДОЖДЯ|ВЗРЫВ|СМЕХ)\b"#,
            ],
            clauseOpeners: [
                "который", "которая", "которое", "которые", "которого", "которой", "которых",
                "которым", "которую", "которыми", "что", "чтобы", "чем", "если", "когда", "пока",
                "потому", "поэтому", "хотя", "как", "где", "куда", "откуда", "но", "а", "и", "да",
                "то", "так", "зато", "либо", "или", "кто", "какой", "какая", "какие", "почему",
                "зачем", "сколько",
            ]
        )

        static let builtIn: [LanguagePack] = [.english, .russian]

        static func named(_ id: String) -> LanguagePack? {
            self.builtIn.first { $0.id == id }
        }
    }

    /// Recognizer artifacts that belong to no language.
    private static let commonHallucinations = [#"[♪♫♬🎵🎶]+"#]

    static func apply(_ text: String, options: Options) -> String {
        guard options.isEnabled, !text.isEmpty else { return text }
        let rules = Rules.cached(for: options)
        var result = text
        if options.fixesLatinInCyrillic {
            result = LatinIntrusionFixer.fix(result)
        }
        if options.removesHallucinations {
            for regex in rules.hallucinations {
                result = regex.stringByReplacingMatches(in: result, range: Self.fullRange(result), withTemplate: "")
            }
        }
        result = FillerRemover(rules: rules).remove(from: result)
        if options.removesRepeatedWords, let repeatedWords = rules.repeatedWords {
            result = repeatedWords.stringByReplacingMatches(in: result, range: Self.fullRange(result), withTemplate: "$1")
        }
        return Self.normalize(result)
    }

    // MARK: - Compiled rules

    private final class Rules: @unchecked Sendable {
        /// Word sequences removed wherever they occur, keyed by their first word.
        let phrasesByFirstWord: [String: [[String]]]
        let guardedWords: Set<String>
        let clauseOpeners: Set<String>
        let hesitation: NSRegularExpression?
        let hallucinations: [NSRegularExpression]
        let repeatedWords: NSRegularExpression?

        private static let lock = NSLock()
        private nonisolated(unsafe) static var cache: (options: Options, rules: Rules)?

        static func cached(for options: Options) -> Rules {
            self.lock.lock()
            defer { self.lock.unlock() }
            if let cache, cache.options == options { return cache.rules }
            let rules = Rules(options: options)
            self.cache = (options, rules)
            return rules
        }

        private init(options: Options) {
            let packs = options.languagePackIDs.compactMap(LanguagePack.named).sorted { $0.id < $1.id }
            var phrases: [String: [[String]]] = [:]
            let anywhere = options.customFillers + packs.flatMap(\.phrases)
            for phrase in anywhere {
                let words = SpeechCleanup.tokenize(phrase.lowercased()).filter { $0.kind == .word }.map(\.text)
                guard let first = words.first else { continue }
                phrases[first, default: []].append(words)
            }
            // Try longer phrases first so "вот это самое" wins over "вот".
            self.phrasesByFirstWord = phrases.mapValues { $0.sorted { $0.count > $1.count } }

            var guarded: Set<String> = []
            var guardedPhrases: [String: [[String]]] = [:]
            for word in packs.flatMap(\.guardedWords) {
                let words = SpeechCleanup.tokenize(word.lowercased()).filter { $0.kind == .word }.map(\.text)
                if words.count == 1, let only = words.first {
                    guarded.insert(only)
                } else if let first = words.first {
                    guardedPhrases[first, default: []].append(words)
                }
            }
            self.guardedWords = guarded
            self.clauseOpeners = Set(packs.flatMap(\.clauseOpeners).map { $0.lowercased() })
            self.guardedPhrasesByFirstWord = guardedPhrases.mapValues { $0.sorted { $0.count > $1.count } }

            let hesitations = packs.flatMap(\.hesitations)
            self.hesitation = hesitations.isEmpty
                ? nil
                : try? NSRegularExpression(pattern: "^(?:" + hesitations.joined(separator: "|") + ")$", options: .caseInsensitive)

            self.hallucinations = (SpeechCleanup.commonHallucinations + packs.flatMap(\.hallucinations))
                .compactMap { try? NSRegularExpression(pattern: $0) }

            // "слово слово слово" → "слово"; the backreference is case-insensitive too.
            self.repeatedWords = try? NSRegularExpression(
                pattern: #"\b(\p{L}+)(?:\s+\1\b)+"#,
                options: .caseInsensitive
            )
        }

        let guardedPhrasesByFirstWord: [String: [[String]]]
    }

    // MARK: - Tokens

    enum TokenKind { case word, space, punctuation }

    struct Token {
        var kind: TokenKind
        var text: String
    }

    /// Splits text into words, whitespace and punctuation without losing a character.
    /// Apostrophes and hyphens between letters stay inside the word ("в общем-то", "don't").
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var currentKind: TokenKind?
        let characters = Array(text)

        func flush() {
            if let kind = currentKind, !current.isEmpty {
                tokens.append(Token(kind: kind, text: current))
            }
            current = ""
            currentKind = nil
        }

        for (index, character) in characters.enumerated() {
            let kind: TokenKind
            if character.isLetter || character.isNumber {
                kind = .word
            } else if character.isWhitespace || character.isNewline {
                kind = .space
            } else if "-'’ʼ".contains(character),
                      currentKind == .word,
                      index + 1 < characters.count,
                      characters[index + 1].isLetter
            {
                kind = .word
            } else {
                kind = .punctuation
            }
            if kind != currentKind || kind == .punctuation {
                flush()
                currentKind = kind
            }
            current.append(character)
        }
        flush()
        return tokens
    }

    private static let softPunctuation: Set<String> = [",", ";", ":", "—", "–", "-"]
    private static let sentenceEndPunctuation: Set<String> = [".", "!", "?", "…"]

    // MARK: - Filler removal

    private struct FillerRemover {
        let rules: Rules

        func remove(from text: String) -> String {
            let tokens = SpeechCleanup.tokenize(text)
            var output: [Token] = []
            var capitalizeNextWord = false
            var index = 0

            while index < tokens.count {
                var token = tokens[index]
                guard token.kind == .word else {
                    output.append(token)
                    index += 1
                    continue
                }
                let lowercased = token.text.lowercased()
                let previous = output.last { $0.kind != .space }
                let atBoundary = previous == nil || previous?.kind == .punctuation || token.text.first?.isUppercase == true

                var spanEnd: Int?
                if let end = self.matchPhrase(in: tokens, at: index, table: self.rules.phrasesByFirstWord) {
                    spanEnd = end
                } else if let end = self.matchPhrase(in: tokens, at: index, table: self.rules.guardedPhrasesByFirstWord),
                          atBoundary, self.isFollowedByBoundary(tokens, after: end)
                {
                    spanEnd = end
                } else if self.rules.guardedWords.contains(lowercased), atBoundary, self.isFollowedByBoundary(tokens, after: index) {
                    spanEnd = index
                } else if let hesitation = self.rules.hesitation,
                          hesitation.firstMatch(in: token.text, range: SpeechCleanup.fullRange(token.text)) != nil
                {
                    spanEnd = index
                }

                if let spanEnd {
                    let startsSentence = previous == nil
                        || (previous?.kind == .punctuation && SpeechCleanup.sentenceEndPunctuation.contains(previous?.text ?? ""))
                    index = self.dropSpan(endingAt: spanEnd, in: tokens, output: &output)
                    if startsSentence { capitalizeNextWord = true }
                    continue
                }

                if capitalizeNextWord {
                    token.text = token.text.prefix(1).uppercased() + token.text.dropFirst()
                    capitalizeNextWord = false
                }
                output.append(token)
                index += 1
            }
            return output.map(\.text).joined()
        }

        /// Returns the index of the last token of the longest phrase starting at `index`.
        private func matchPhrase(in tokens: [Token], at index: Int, table: [String: [[String]]]) -> Int? {
            guard let candidates = table[tokens[index].text.lowercased()] else { return nil }
            for words in candidates {
                var cursor = index
                var matched = true
                for word in words.dropFirst() {
                    cursor += 1
                    while cursor < tokens.count, tokens[cursor].kind == .space { cursor += 1 }
                    guard cursor < tokens.count, tokens[cursor].kind == .word, tokens[cursor].text.lowercased() == word else {
                        matched = false
                        break
                    }
                }
                if matched { return cursor }
            }
            return nil
        }

        private func nextNonSpace(_ tokens: [Token], after index: Int) -> Int? {
            var cursor = index + 1
            while cursor < tokens.count, tokens[cursor].kind == .space { cursor += 1 }
            return cursor < tokens.count ? cursor : nil
        }

        private func isFollowedByBoundary(_ tokens: [Token], after index: Int) -> Bool {
            guard let next = self.nextNonSpace(tokens, after: index) else { return true }
            return tokens[next].kind == .punctuation
        }

        /// Removes the tokens up to `spanEnd` plus whichever comma set the filler off, and
        /// returns the index to resume from.
        private func dropSpan(endingAt spanEnd: Int, in tokens: [Token], output: inout [Token]) -> Int {
            var resume = spanEnd + 1
            let next = self.nextNonSpace(tokens, after: spanEnd)
            let nextIsSoft = next.map { SpeechCleanup.softPunctuation.contains(tokens[$0].text) } ?? false
            let previousIsSoft = output.last { $0.kind != .space }.map { SpeechCleanup.softPunctuation.contains($0.text) } ?? false

            if nextIsSoft, let next {
                // The trailing comma goes with the filler. When the filler was framed by commas
                // on both sides, the leading comma goes too ("указать, в общем-то, права" →
                // "указать права"), unless the next word opens a clause that keeps its comma
                // ("форк, вот, который" → "форк, который").
                resume = next + 1
                let following = self.nextNonSpace(tokens, after: next)
                let opensClause = following.map {
                    tokens[$0].kind == .word && self.rules.clauseOpeners.contains(tokens[$0].text.lowercased())
                } ?? false
                if previousIsSoft, !opensClause {
                    while let last = output.last, last.kind == .space { output.removeLast() }
                    output.removeLast()
                }
            } else if previousIsSoft {
                // "сделать, ммм." → "сделать.": the leading comma goes with the filler.
                while let last = output.last, last.kind == .space { output.removeLast() }
                output.removeLast()
            }
            // Keep a single separator between what came before and what follows.
            while resume < tokens.count, tokens[resume].kind == .space,
                  output.last?.kind == .space || output.isEmpty
            {
                resume += 1
            }
            return resume
        }
    }

    // MARK: - Latin letters inside Cyrillic words

    /// Recognizers sometimes emit Latin look-alikes inside Russian words ("попríятнее").
    /// A word that is at least 70 % Cyrillic gets its Latin letters mapped back; words that
    /// are mostly Latin (names, brands, code) are left alone.
    enum LatinIntrusionFixer {
        private static let latinToCyrillic: [Character: Character] = [
            "a": "а", "A": "А", "c": "с", "C": "С", "e": "е", "E": "Е", "o": "о", "O": "О",
            "p": "р", "P": "Р", "x": "х", "X": "Х", "y": "у", "Y": "У", "k": "к", "K": "К",
            "m": "м", "M": "М", "h": "н", "H": "Н", "t": "т", "T": "Т", "b": "в", "B": "В",
            "n": "н", "N": "Н", "r": "р", "R": "Р", "i": "и", "I": "И",
            "í": "и", "Í": "И", "á": "а", "Á": "А", "é": "е", "É": "Е", "ó": "о", "Ó": "О",
            "ú": "у", "Ú": "У", "ý": "у", "Ý": "У", "ñ": "н", "Ñ": "Н",
        ]

        static func fix(_ text: String) -> String {
            guard text.unicodeScalars.contains(where: Self.isCyrillic) else { return text }
            return SpeechCleanup.tokenize(text).map { token in
                token.kind == .word ? Self.fixWord(token.text) : token.text
            }.joined()
        }

        private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
            (0x0400...0x04FF).contains(scalar.value)
        }

        private static func fixWord(_ word: String) -> String {
            var cyrillic = 0
            var latin = 0
            for character in word where character.isLetter {
                if character.unicodeScalars.contains(where: Self.isCyrillic) {
                    cyrillic += 1
                } else {
                    latin += 1
                }
            }
            let letters = cyrillic + latin
            guard letters > 0, latin > 0, Double(cyrillic) / Double(letters) >= 0.7 else { return word }
            return String(word.map { Self.latinToCyrillic[$0] ?? $0 })
        }
    }

    // MARK: - Helpers

    private static let normalizers: [(NSRegularExpression, String)] = [
        (#"[ \t]{2,}"#, " "),
        (#"[ \t]+([,.!?;:…)»])"#, "$1"),
        (#"([(«])[ \t]+"#, "$1"),
        (#"([,;:])(?:[ \t]*[,;:])+"#, "$1"),
        (#"([.!?…])[ \t]*[,;:]"#, "$1"),
        (#"^[ \t,;:]+"#, ""),
    ].compactMap { pattern, template in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
    }

    private static func normalize(_ text: String) -> String {
        var result = text
        for (regex, template) in self.normalizers {
            result = regex.stringByReplacingMatches(in: result, range: self.fullRange(result), withTemplate: template)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fullRange(_ text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }
}
