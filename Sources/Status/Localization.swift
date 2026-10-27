import Foundation

/// 界面语言：跟随系统（系统首选语言是中文时用中文，否则英文），或手动指定
enum AppLanguage: String, CaseIterable {
    case system, chinese, english

    var title: String {
        switch self {
        case .system: L("跟随系统", "System")
        case .chinese: "中文"
        case .english: "English"
        }
    }
}

enum Lang {
    nonisolated(unsafe) static var setting: AppLanguage = .system

    static var isChinese: Bool {
        switch setting {
        case .chinese: true
        case .english: false
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
        }
    }
}

/// 中英文写在同一处，按当前界面语言取用。
/// 比 Localizable.strings 更适合这里：很多文字是拼出来的 String（提示、通知、格式化数值），不只是 Text
func L(_ chinese: String, _ english: String) -> String {
    Lang.isChinese ? chinese : english
}
