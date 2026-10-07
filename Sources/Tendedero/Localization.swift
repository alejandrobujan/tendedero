import Foundation

/// Tiny three-language helper. The app has a handful of strings, so a full
/// .strings setup would be more ceremony than content.
///
/// English and Spanish are passed at the call site; Chinese is looked up by
/// the English string, so call sites stay exactly `L(english, spanish)`.
private enum Language { case english, spanish, chinese }

private let language: Language = {
    let preferred = Locale.preferredLanguages.first ?? "en"
    if preferred.hasPrefix("zh") { return .chinese }
    if preferred.hasPrefix("es") { return .spanish }
    return .english
}()

private let chinese: [String: String] = [
    "Let Tendedero handle your screenshots?":
        "让 Tendedero 接管你的截图？",
    "Screenshots will hang on the line the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when Tendedero quits.":
        "你截图的那一瞬间，图片就会挂到晾衣绳上——没有浮动缩略图，也不会堆到桌面上。拖进文件夹即保留，点叉即丢弃。随时可以从菜单栏关掉，退出 Tendedero 后你的设置会自动还原。",
    "Turn on": "开启",
    "Not now": "以后再说",
    "Hide line": "隐藏晾衣绳",
    "Show line": "显示晾衣绳",
    "Take everything down": "全部取下",
    "Handle screenshots": "接管截图",
    "Screenshots hang instantly and skip the Desktop": "截图即刻挂上，不再经过桌面",
    "Open screenshots folder": "打开截图文件夹",
    "Sounds": "声音",
    "Open at login": "开机时打开",
    "Quit Tendedero": "退出 Tendedero",
    "Could not change the login setting": "无法修改开机启动设置",
    "Move Tendedero to the Applications folder and try again.":
        "请先把 Tendedero 移到「应用程序」文件夹，再试一次。",
    "Copy": "复制",
    "Open": "打开",
    "Markup": "标记",
    "Show in Finder": "在访达中显示",
    "Save to Desktop": "存储到桌面",
    "Discard": "丢弃",
    "Take down": "取下",
    "Move to Trash": "移到废纸篓",
    "Take a screenshot and it will hang here": "截个图，它就会挂在这里",
    "Copied": "已复制",
]

func L(_ english: String, _ spanish: String) -> String {
    switch language {
    case .chinese: return chinese[english] ?? english
    case .spanish: return spanish
    case .english: return english
    }
}
