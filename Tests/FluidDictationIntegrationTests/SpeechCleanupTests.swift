@testable import FluidVoice_Debug
import XCTest

final class SpeechCleanupTests: XCTestCase {
    private let options = SpeechCleanup.Options(customFillers: ["um", "uh", "hmm"])

    private func clean(_ text: String, _ options: SpeechCleanup.Options? = nil) -> String {
        SpeechCleanup.apply(text, options: options ?? self.options)
    }

    // MARK: - Russian fillers

    func testSentenceInitialFillerIsDroppedWithItsCommaAndNextWordCapitalized() {
        XCTAssertEqual(self.clean("Ну, в смысле, доступ универсальный добавился, все работает."),
                       "В смысле, доступ универсальный добавился, все работает.")
    }

    func testCapitalizedFillerAfterAWordIsDroppedWithoutRecapitalizing() {
        XCTAssertEqual(self.clean("Данные Ну, в смысле, доступ добавился."), "Данные в смысле, доступ добавился.")
    }

    func testMultiWordPhrasesAreDroppedAnywhereWithTheirCommas() {
        XCTAssertEqual(self.clean("указать, в общем-то, оригинальные права"), "указать оригинальные права")
        XCTAssertEqual(self.clean("Ну, короче говоря, грубо говоря, этот форк, который я делаю, опубликовать."),
                       "Этот форк, который я делаю, опубликовать.")
        XCTAssertEqual(self.clean("отличается только лишь на в общем то на этот шаг"), "отличается только лишь на этот шаг")
    }

    func testGuardedWordsSurviveInsideASentence() {
        XCTAssertEqual(self.clean("типа данных не совпадают"), "типа данных не совпадают")
        XCTAssertEqual(self.clean("вот этот файл"), "вот этот файл")
        XCTAssertEqual(self.clean("это значит, что тест прошёл"), "это значит, что тест прошёл")
        XCTAssertEqual(self.clean("а мы получается делаем форк"), "а мы получается делаем форк")
    }

    func testGuardedWordsAreDroppedWhenSetOffByPunctuation() {
        XCTAssertEqual(self.clean("делаем форк, вот, который отличается"), "делаем форк, который отличается")
        XCTAssertEqual(self.clean("Вот, смотри, этот файл."), "Этот файл.")
        XCTAssertEqual(self.clean("Это работает, в принципе."), "Это работает.")
    }

    func testHesitationSoundsAreDroppedEverywhere() {
        XCTAssertEqual(self.clean("Это, э-э, нужно сделать, ммм, завтра."), "Это нужно сделать завтра.")
        XCTAssertEqual(self.clean("Эм, я думаю, что да."), "Я думаю, что да.")
    }

    func testRepeatedWordsCollapse() {
        XCTAssertEqual(self.clean("мы мы сделали это это сегодня"), "мы сделали это сегодня")
        XCTAssertEqual(self.clean("Это Это важно"), "Это важно")
    }

    func testLatinLookAlikesInsideCyrillicWordsAreRestored() {
        XCTAssertEqual(self.clean("стало попríятнее"), "стало поприятнее")
        XCTAssertEqual(self.clean("Outmap работает с API"), "Outmap работает с API")
    }

    func testWhisperHallucinationsAreDropped() {
        XCTAssertEqual(self.clean("Текст готов. Субтитры создавал DimaTorzok"), "Текст готов.")
        XCTAssertEqual(self.clean("Пока. Продолжение следует..."), "Пока.")
        XCTAssertEqual(self.clean("ВЕСЁЛАЯ МУЗЫКА Привет"), "Привет")
        XCTAssertEqual(self.clean("смех в зале"), "смех в зале")
    }

    // MARK: - English

    func testEnglishFillersAndHesitations() {
        XCTAssertEqual(self.clean("So, um, I think, you know, it works, like, fine."), "So I think it works fine.")
        XCTAssertEqual(self.clean("We tried, like, everything, but it failed."), "We tried everything, but it failed.")
        XCTAssertEqual(self.clean("I like this plan."), "I like this plan.")
        XCTAssertEqual(self.clean("Thanks for watching! Bye."), "Bye.")
    }

    // MARK: - Options

    func testDisabledCleanupLeavesTextAlone() {
        var options = self.options
        options.isEnabled = false
        XCTAssertEqual(self.clean("Ну, э-э, мы мы идём", options), "Ну, э-э, мы мы идём")
    }

    func testCustomFillersAreRemovedAnywhere() {
        var options = self.options
        options.customFillers = ["получается"]
        XCTAssertEqual(self.clean("а мы получается делаем форк", options), "а мы делаем форк")
    }

    func testDisabledLanguagePackKeepsItsFillers() {
        var options = self.options
        options.languagePackIDs = ["en"]
        XCTAssertEqual(self.clean("Ну, короче говоря, работает.", options), "Ну, короче говоря, работает.")
    }

    func testIndividualRulesCanBeTurnedOff() {
        var options = self.options
        options.removesRepeatedWords = false
        options.fixesLatinInCyrillic = false
        options.removesHallucinations = false
        XCTAssertEqual(self.clean("мы мы попríятнее. Продолжение следует...", options),
                       "мы мы попríятнее. Продолжение следует...")
    }

    func testPlainTextPassesThroughUnchanged() {
        let text = "В целом мы можем такую функцию тоже добавить в этот же fork, и fork уже будет отличаться не на одну функцию, а на две."
        XCTAssertEqual(self.clean(text), text)
        XCTAssertEqual(self.clean(""), "")
    }

    func testTokenizerKeepsHyphensAndApostrophesInsideWords() {
        let words = SpeechCleanup.tokenize("в общем-то don't — ok").filter { $0.kind == .word }.map(\.text)
        XCTAssertEqual(words, ["в", "общем-то", "don't", "ok"])
    }
}
