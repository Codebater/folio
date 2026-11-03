import Testing
import FolioCore
@testable import FolioAudio

@Suite("Numbers as words")
struct NumberWordingTests {
    let rules = PronunciationRules(spellNumbers: true)

    func say(_ text: String, _ language: LanguageCode) -> String { rules.spoken(text, language: language) }

    @Test func slovakDatesTimesAndAmounts() {
        #expect(say("Rokovanie sa uskutoční 3. novembra 2026 v Bratislave.", .slovak)
                == "Rokovanie sa uskutoční tretieho novembra dvetisíc dvadsaťšesť v Bratislave.")
        #expect(say("Platí od 21. 3. 2025.", .slovak) == "Platí od dvadsiateho prvého marca dvetisíc dvadsaťpäť.")
        #expect(say("Pripravujú sa k 1. júlu.", .slovak) == "Pripravujú sa k prvému júlu.")
        #expect(say("Stretnutie začne o 14:30.", .slovak) == "Stretnutie začne o štrnástej tridsať.")
        #expect(say("Inflácia klesla na 4,5 % a potom na 2 %.", .slovak)
                == "Inflácia klesla na štyri celé päť percenta a potom na dve percentá.")
        #expect(say("Prišlo 12 500 ľudí a 0,5 % z nich zostalo.", .slovak)
                == "Prišlo dvanásťtisíc päťsto ľudí a nula celá päť percenta z nich zostalo.")
        // Ordinals before a noun and numbers glued to letters stay as written.
        #expect(say("V 21. storočí prišli COVID-19 a 5G.", .slovak) == "V 21. storočí prišli COVID-19 a 5G.")
    }

    @Test func czechDatesAndTimes() {
        #expect(say("Jednání proběhne 3. listopadu 2026 ve 14:30.", .czech)
                == "Jednání proběhne třetího listopadu dva tisíce dvacet šest ve čtrnáct třicet.")
        #expect(say("Přišlo 1 200 lidí.", .czech) == "Přišlo tisíc dvě stě lidí.")
    }

    @Test func germanDatesYearsAndCase() {
        #expect(say("Am 3. November 2026 um 14:30 Uhr beginnt es.", .german)
                == "Am dritten November zweitausendsechsundzwanzig um vierzehn Uhr dreißig beginnt es.")
        #expect(say("Der 3. Oktober ist ein Feiertag.", .german) == "Der dritte Oktober ist ein Feiertag.")
        #expect(say("Im Jahr 1989 kamen 1.500 Menschen.", .german)
                == "Im Jahr neunzehnhundertneunundachtzig kamen eintausendfünfhundert Menschen.")
        #expect(say("Nur 1 Prozent, also 4,5 % weniger.", .german) == "Nur ein Prozent, also vier Komma fünf Prozent weniger.")
        #expect(say("Der 3. Platz ging an Köln.", .german) == "Der 3. Platz ging an Köln.")
        #expect(say("Ein Umsatz von $4.5bn.", .german) == "Ein Umsatz von vier Komma fünf Milliarden Dollar.")
    }

    @Test func spanishDatesAndAgreement() {
        #expect(say("El 3 de noviembre de 2026 a las 14:30.", .spanish)
                == "El tres de noviembre de dos mil veintiséis a las catorce treinta.")
        #expect(say("El 1 de mayo cumplió 21 años.", .spanish) == "El primero de mayo cumplió veintiún años.")
        #expect(say("Subió un 4,5 % hasta 1.500 euros.", .spanish)
                == "Subió un cuatro coma cinco por ciento hasta mil quinientos euros.")
    }

    @Test func englishAndAppleVoicesKeepDigits() {
        #expect(say("On 3 November 2026 at 14:30.", .english) == "On 3 November 2026 at 14:30.")
        #expect(PronunciationRules().spoken("Dňa 3. novembra 2026.", language: .slovak) == "Dňa 3. novembra 2026.")
    }
}
