import Foundation

/// Справочные данные для подсказки "какие символы можно писать" — чисто
/// информационные, привязаны к формату адреса конкретной сети (не меняются
/// динамически, поэтому держим их в Swift, а не тянем из bridge.py).
struct NetworkAlphabetInfo {
    let chars: String
    private let noteKey: L?

    init(chars: String, noteKey: L?) {
        self.chars = chars
        self.noteKey = noteKey
    }

    func note(_ lang: AppLanguage) -> String? { noteKey?.s(lang) }
}

enum NetworkAlphabet {
    static let info: [String: NetworkAlphabetInfo] = [
        "eth": NetworkAlphabetInfo(chars: "0-9, a-f", noteKey: .alphabetNoteEth),
        "sol": NetworkAlphabetInfo(chars: "1-9, A-H, J-N, P-Z, a-k, m-z", noteKey: .alphabetNoteSol),
        "trx": NetworkAlphabetInfo(chars: "1-9, A-H, J-N, P-Z, a-k, m-z", noteKey: .alphabetNoteTrx),
        "ton": NetworkAlphabetInfo(chars: "A-Z, a-z, 0-9, -, _", noteKey: .alphabetNoteTon),
    ]
}
