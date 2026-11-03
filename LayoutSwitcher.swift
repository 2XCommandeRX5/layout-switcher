import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import os.log

// ============================================================
// LayoutSwitcher
//
// Фоновая программа для macOS: запоминает раскладку клавиатуры
// для каждого приложения (и каждого окна/вкладки браузера) и
// автоматически переключает её при смене активного окна.
//
// Поведение:
//   - при смене активного окна применяет последнюю запомненную для
//     него раскладку;
//   - раскладка «запоминается» пассивно: когда в окне нет ввода
//     и текущая раскладка отличается от сохранённой, она сохраняется;
//   - окна одного приложения различаются по заголовку окна, поэтому
//     два окна браузера могут иметь разные раскладки;
//   - в браузерах раскладка помнится для каждой вкладки отдельно
//     (для Safari — по URL страницы, для остальных — по заголовку
//     вкладки, см. BrowserWindowIdentity) и переживает перезапуск
//     браузера и программы.
//
// Хранилище состояний и лимиты (защита от утечек и переполнения):
//   ~/.layout-switcher/state.json, см. StoragePolicy и LayoutStore.
//
// Сборка:  swiftc -O LayoutSwitcher.swift -o LayoutSwitcher
// Запуск:  ./LayoutSwitcher [--quit | --install | --uninstall]
// ============================================================

let log = OSLog(subsystem: "com.xcommanderx.layoutswitcher", category: "main")

// MARK: - Accessibility: активное окно

private func isAXTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Информация о переднем окне: PID приложения, заголовок окна,
/// элементы окна (для сравнения «это то же окно или новое») и
/// браузерная идентичность окна/вкладки.
struct FrontWindowInfo {
    let pid: pid_t
    let bundleID: String
    let displayName: String
    /// Заголовок активного окна (у Safari — заголовок активной вкладки).
    /// nil, если определить настоящее окно не удалось.
    let title: String?
    /// Фокусное окно — только если AX действительно отдаёт окно
    /// (Safari может вернуть вместо него элемент самого приложения).
    let focusedWindow: AXUIElement?
    /// Первое настоящее окно из списка окон (резервный источник).
    let literalWindow: AXUIElement?
    /// Браузерная идентичность для ключа раскладки: nil для приложений,
    /// не распознанных как браузер.
    let browser: BrowserTabKey?
}

private func frontmostWindowInfo() -> FrontWindowInfo? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    let bundleID = app.bundleIdentifier ?? "pid-\(pid)"
    let displayName = app.localizedName ?? bundleID

    let appElement = AXUIElementCreateApplication(pid)

    // Фокусное окно. У Safari AX-запрос может вернуть элемент самого
    // приложения — такой элемент окном не считаем.
    var focusedWindow: AXUIElement?
    var title: String?
    var focused: CFTypeRef?
    if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focused) == .success,
       let focused {
        let el = focused as! AXUIElement
        if isRealWindow(el) {
            focusedWindow = el
            title = axTitle(el)
        }
    }

    // Резерв: первое настоящее окно из списка.
    var literalWindow: AXUIElement?
    if let windows = axWindows(appElement) {
        literalWindow = windows.first(where: { isRealWindow($0) })
    }

    let browser = BrowserTabKey.identity(pid: pid, bundleID: bundleID,
                                         focusedWindow: focusedWindow,
                                         windowTitle: title)

    return FrontWindowInfo(pid: pid, bundleID: bundleID, displayName: displayName,
                           title: title, focusedWindow: focusedWindow,
                           literalWindow: literalWindow, browser: browser)
}

/// Тяжёлый AX-обход дерева окна Safari (до AXWebArea) запускаем не чаще,
/// чем раз в 1.5 с — обычный тик движка (0.3 с) берёт закэшированное.
private var safariURLCacheTime = Date.distantPast
private var safariURLCacheKey = ""
private var safariURLCacheValue: BrowserTabKey?

private func axWindows(_ app: AXUIElement) -> [AXUIElement]? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &out) == .success,
          let out else { return nil }
    return out as? [AXUIElement]
}

private func axRole(_ el: AXUIElement) -> String? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &out) == .success else { return nil }
    return out as? String
}

private func axTitle(_ el: AXUIElement) -> String? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &out) == .success else { return nil }
    return out as? String
}

/// Настоящее окно: роль AXWindow (иногда диалог или sheet).
private func isRealWindow(_ el: AXUIElement) -> Bool {
    guard let role = axRole(el) else { return false }
    return role == (kAXWindowRole as String) || role == "AXDialog" || role == "AXSheet"
}

// MARK: - Идентичность браузерных вкладок

/// Распознанные браузеры и их особенности AX-дерева (проверено
/// пробником на 05.11.2026: Safari отдаёт настоящие окна и панель
/// вкладок с AXURL активной вкладки; Firefox — только заголовок
/// окна, kAXWindows пуст).
private enum BrowserProfile {
    case safari
    case firefox
    case chrome /// Chromium-семейство (Chrome, Arc, Edge, Brave, Opera)

    init?(bundleID: String) {
        switch bundleID {
        case "com.apple.Safari", "com.apple.WebKit": self = .safari
        case "org.mozilla.firefox": self = .firefox
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser",
             "com.microsoft.edgemac", "com.microsoft.edgemac.Canary",
             "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
             "company.thebrowser.Browser": // Arc
            self = .chrome
        default: return nil
        }
    }
}

/// Ключ «места» в браузере: вкладки Safari идентифицируются по URL
/// страницы (переживает перезапуск), остальные — по заголовку вкладки
/// (AX-ограничение: у Firefox панели вкладок в дереве нет совсем,
/// у Chromium — она нестабильна между версиями).
enum BrowserTabKey: Hashable, CustomStringConvertible {
    case url(String)
    case title(String)

    /// Ключ для фокусной вкладки приложения-браузера.
    static func identity(pid: pid_t, bundleID: String,
                         focusedWindow: AXUIElement?, windowTitle: String?) -> BrowserTabKey? {
        guard let profile = BrowserProfile(bundleID: bundleID) else { return nil }

        switch profile {
        case .safari:
            // URL активной вкладки («AXWebArea» под фокусом в этом окне).
            // Пробник (05.11): AXURL у WebArea заполняется не всегда —
            // на ряде страниц (пример — example.com) он nil. Поэтому,
            // если URL получить не удалось, запасной ключ — заголовок
            // вкладки: у Safari он уникален между вкладками и переживает
            // перезапуск браузера (восстановление вкладок).
            let now = Date()
            let cacheKey = "\(focusedWindow.hashValue):\(windowTitle ?? "")"
            let cached = safariURLCacheKey == cacheKey
                && now.timeIntervalSince(safariURLCacheTime) < 1.5
            if cached {
                if case .url(let u)? = safariURLCacheValue { return .url(u) }
            } else if let pageURL = safariActiveTabURL(focusedWindow: focusedWindow,
                                                       windowTitle: windowTitle),
                      let norm = normalizePageURL(pageURL) {
                safariURLCacheValue = .url(norm)
                safariURLCacheKey = cacheKey
                safariURLCacheTime = now
                return .url(norm)
            } else {
                safariURLCacheValue = nil
                safariURLCacheKey = cacheKey
                safariURLCacheTime = now
            }
            // Страница могла не догрузиться / URL недоступен — ключ по
            // заголовку вкладки (e.g. "xcommanderx 💃", "Example Domain").
            if let t = normalizeTitleKey(windowTitle) { return .title(t) }
            return nil

        case .firefox:
            // Заголовок окна = заголовок активной вкладки. Защищённые
            // окна (пароли) и «пустые» титулы не пишем — ложная привязка.
            guard let wt = windowTitle, !isFirefoxPersonalWindow(wt),
                  let t = normalizeTitleKey(wt),
                  !fallbackWindowTitles.contains(t) else { return nil }
            return .title(t)

        case .chrome:
            guard let t = normalizeTitleKey(windowTitle) else { return nil }
            return .title(t)
        }
    }

    var description: String {
        switch self {
        case .url(let u): return "url:\(u)"
        case .title(let t): return "title:\(t)"
        }
    }
}

/// Частые «пустые» заголовки новых вкладок/окон браузеров (фолбэк-ключи
/// не делаем — они почти всегда одноразовые и только создадут мусор).
private let fallbackWindowTitles: Set<String> = [
    "Новая вкладка", "Новое окно", "Домашняя страница", "Пустая страница",
    "New Tab", "New Window", "Home", "about:blank", "Start",
]

/// Safari personal: заголовок окна может быть у паролей/icloud — их
/// по заголовку не привязываем без URL.
private func isFirefoxPersonalWindow(_ wt: String) -> Bool {
    let t = wt.lowercased()
    return t == "пароли" || t == "passwords" || t == "logins"
}

/// URL активной вкладки Safari: фокусный путь AX-дерева окна до
/// «AXWebArea» (его AXURL). Пробник: у активной вкладки WebArea лежит
/// под AXSplitGroup→AXTabGroup→AXGroup(BrowserView)→…→AXWebArea.
private func safariActiveTabURL(focusedWindow: AXUIElement?, windowTitle: String?) -> String? {
    guard let focusedWindow else { return nil }
    var url: String?
    var seen = 0
    var stack: [(AXUIElement, Int)] = [(focusedWindow, 0)]
    while let (el, depth) = stack.popLast() {
        seen += 1
        if seen > 4000 { break }
        let role = axRole(el) ?? ""
        let ident = axIdentifier(el) ?? ""
        if role == "AXWebArea", let u = axURL(el) { url = u; break }
        if ident.hasPrefix("TabBar") { continue } // панель вкладок не сканируем
        if depth >= 10 { continue }
        if let children = axChildren(el) {
            for c in children { stack.append((c, depth + 1)) }
        }
    }
    _ = windowTitle
    return url
}

private func axChildren(_ el: AXUIElement) -> [AXUIElement]? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &out) == .success,
          let out else { return nil }
    return out as? [AXUIElement]
}

private func axIdentifier(_ el: AXUIElement) -> String? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXIdentifierAttribute as CFString, &out) == .success else { return nil }
    return out as? String
}

private func axURL(_ el: AXUIElement) -> String? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &out) == .success else { return nil }
    return out as? String
}

/// Нормализация URL страницы в ключ вкладки: без протокола/«www.»/
/// query/fragment, хост в нижнем регистре, путь срезан до 160 символов.
/// Страница в другой вкладке с тем же URL — одна и та же раскладка.
private func normalizePageURL(_ raw: String?) -> String? {
    guard let raw, let url = URL(string: raw), let urlHost = url.host?.lowercased() else { return nil }
    var host = urlHost
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    var path = url.path
    if path == "/" { path = "" }
    if path.count > 160 { path = String(path.prefix(160)) }
    let key = "\(host)\(path)"
    return key.isEmpty ? nil : key
}

/// Заголовок → ключ: без пробелов по краям; длинные/одноразовые
/// заголовки (…ggregate-фрагменты) в ключ не берём.
private func normalizeTitleKey(_ t: String?) -> String? {
    guard let raw = t?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.count > 180 { return nil }
    return raw
}

// MARK: - Раскладки (Carbon TIS)

private func currentInputSourceID() -> String? {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
    guard let prop = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return nil }
    return Unmanaged<CFString>.fromOpaque(prop).takeUnretainedValue() as String
}

/// Буква текущей раскладки для бейджа: языки берём из самой раскладки
/// (первый и основной — TIS гарантирует порядок). Сопоставление по
/// известному языку, иначе — первая буква кода языка.
private func frontmostLayoutLetter() -> String {
    guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return "?" }
    guard let prop = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return "?" }
    let langs = (Unmanaged<CFTypeRef>.fromOpaque(prop).takeUnretainedValue() as? [String]) ?? []
    guard let primary = langs.first?.trimmingCharacters(in: .whitespaces),
          !primary.isEmpty else { return "?" }

    switch primary {
    case "ru", "be", "uk", "kk", "ky", "mn", "tg", "uz-Cyrl", "bg", "sr", "mk", "myv", "inh", "tyv", "sjd":
        return "Я"
    case "en", "af", "da", "de", "es", "fr", "it", "nl", "no", "pt", "sv", "fi", "is", "ga", "cy", "ro", "cs", "sk", "sl", "hr", "pl", "hu", "tr", "az", "et", "lv", "lt":
        return "A"
    default:
        let first = String(primary.prefix(1)).uppercased()
        return first.isEmpty ? "?" : first
    }
}

private func inputSource(withID id: String) -> TISInputSource? {
    let props = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(props, false)?.takeRetainedValue() as? [TISInputSource] else {
        return nil
    }
    return list.first
}

/// Переключить раскладку на переданный идентификатор.
private func selectInputSource(_ id: String) {
    guard let src = inputSource(withID: id) else {
        os_log("source not found: %{public}@", log: log, type: .error, id)
        return
    }
    TISSelectInputSource(src)
}

// MARK: - Хранилище

/// Политика хранения раскладок (защита от утечек и переполнения).
/// Каждый «слот» — это `WKey` в `AppState`. Пределы:
///   perWindow: <= 1000 «мест» на приложение, всего <= 4000 мест,
///              до 100 приложений;
///   perApp:    <= 400 приложений, до 2000 записей;
///   `at`/`browserKey`: LRU-старость места (свободное вытеснение
///   самого давнего — именно закрытые вкладки и вычищаются).
private enum StoragePolicy {
    static let maxWindowsPerApp = 1000
    static let maxPerWindowTotal = 4000
    static let maxAppsWithWindows = 100
    static let maxPerAppEntries = 400
    static let forgetAppAfterDays = 90
}

/// Значения ключа отделяем разделителем, который не встречается
/// в bundleID/заголовках/URL (двоеточие в заголовках есть, NUL — нет).
private let keyPartSeparator: Character = "\u{0}"

/// Браузерный ключ места: `b:url:<bundleID>␀<host><path>` (Safari per-tab)
/// или `b:title:<bundleID>␀<заголовок>` (остальные). Кодируется в
/// `WKey.asRaw` и читается обратно `WKey.fromRaw`.
enum BrowserKey: Hashable, CustomStringConvertible {
    case url(String)
    case title(String)

    var asRaw: String {
        switch self {
        case .url(let u): return "b:url:\(u)"
        case .title(let t): return "b:title:\(t)"
        }
    }

    static func fromRaw(_ raw: String) -> BrowserKey? {
        if raw.hasPrefix("b:url:") { return .url(String(raw.dropFirst(6))) }
        if raw.hasPrefix("b:title:") { return .title(String(raw.dropFirst(8))) }
        return nil
    }

    init(from key: BrowserTabKey) {
        switch key {
        case .url(let u): self = .url(u)
        case .title(let t): self = .title(t)
        }
    }

    var description: String {
        switch self {
        case .url(let u): return "url:\(u)"
        case .title(let t): return "title:\(t)"
        }
    }
}

/// Слот раскладки: значение + время последнего обращения (для LRU).
private struct Slot: Codable {
    var layout: String
    var at: Date
}

/// Ключ хранилища: приложение/окно/вкладка браузера.
enum WKey: Hashable, CustomStringConvertible {
    case app(String)
    case window(bundleID: String, title: String)
    case tab(bundleID: String, browserKey: BrowserKey)

    /// Конвертер из рабочего ключа (BrowserTabKey) в сериализуемый.
    static func tab(from key: BrowserTabKey, bundleID: String) -> WKey {
        .tab(bundleID: bundleID, browserKey: BrowserKey(from: key))
    }

    var asRaw: String {
        switch self {
        case .app(let b): return "a:\(b)"
        case .window(let b, let t): return "w:\(b)\(keyPartSeparator)\(t)"
        case .tab(let b, let k): return "b:\(k.asRaw)\(keyPartSeparator)\(b)"
        }
    }

    static func fromRaw(_ raw: String) -> WKey? {
        if raw.hasPrefix("a:") { return .app(String(raw.dropFirst(2))) }
        if raw.hasPrefix("w:") {
            let rest = String(raw.dropFirst(2))
            let parts = rest.split(separator: keyPartSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return .window(bundleID: String(parts[0]), title: String(parts[1]))
        }
        if raw.hasPrefix("b:") {
            let rest = String(raw.dropFirst(2))
            let parts = rest.split(separator: keyPartSeparator, maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let bk = BrowserKey.fromRaw(String(parts[0])) else { return nil }
            return .tab(bundleID: String(parts[1]), browserKey: bk)
        }
        return nil
    }

    /// Ключ для сохранённой раскладки текущего окна: вкладка браузера
    /// (если распознана) → окно по заголовку → приложение.
    static func forInfo(_ info: FrontWindowInfo, preserveWindowIdentity: Bool = true) -> WKey? {
        if let b = info.browser {
            return .tab(from: b, bundleID: info.bundleID)
        }
        // Per-window вне браузеров не разделяем: заголовки окон часто
        // одинаковые, а ключ по заголовку у не-браузера не переживает
        // перезапуск осмысленно. Остаётся раскладка по приложению.
        _ = preserveWindowIdentity
        return .app(info.bundleID)
    }

    var description: String { asRaw }
}

/// Хранилище раскладок с LRU-вытеснением и debounced-сохранением.
private final class LayoutStore {
    private var slots: [WKey: Slot] = [:]
    private var byApp: [String: [WKey: Slot]] = [:]
    private let fileURL: URL
    private var saveTimer: Timer?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    // MARK: Чтение

    /// Раскладка для ключа; касание не обновляет `at` (это делает
    /// `remember`), чтобы не «оживлять» старые записи без причины.
    func lookup(_ key: WKey) -> String? {
        slots[key]?.layout
    }

    // MARK: Запись

    /// Запомнить раскладку для ключа. Если лимит достигнут — вытеснить
    /// самую старую запись (LRU: закрытые вкладки уходят первыми).
    /// Новая запись получает свежий `at`.
    func remember(_ layout: String, for key: WKey) {
        if slots[key] == nil {
            enforceLimits(for: key)
        }
        let now = Date()
        slots[key] = Slot(layout: layout, at: now)
        var appSlots = byApp[appKey(of: key)] ?? [:]
        appSlots[key] = Slot(layout: layout, at: now)
        byApp[appKey(of: key)] = appSlots
        scheduleSave()
    }

    private func appKey(of key: WKey) -> String {
        switch key {
        case .app(let b): return b
        case .window(let b, _): return b
        case .tab(let b, _): return b
        }
    }

    /// Старые вкладки/окна (90 дней без обращений) забываем.
    /// Запускается раз в час — «тихое» обслуживание.
    func forgetStale() {
        let cutoff = Date().addingTimeInterval(-Double(StoragePolicy.forgetAppAfterDays) * 86_400)
        var changed = false
        for (key, slot) in slots where slot.at < cutoff {
            slots.removeValue(forKey: key)
            var appSlots = byApp[appKey(of: key)] ?? [:]
            appSlots.removeValue(forKey: key)
            if appSlots.isEmpty { byApp.removeValue(forKey: appKey(of: key)) }
            else { byApp[appKey(of: key)] = appSlots }
            changed = true
        }
        if changed { scheduleSave() }
    }

    // MARK: Лимиты (LRU-вытеснение)

    private func enforceLimits(for key: WKey) {
        // Лимит на приложение.
        if let appSlots = byApp[appKey(of: key)],
           appSlots.count >= StoragePolicy.maxWindowsPerApp,
           let oldest = oldestSlot(in: appSlots) {
            removeSlot(oldest.key)
        }
        // Общий лимит.
        if slots.count >= StoragePolicy.maxPerWindowTotal,
           let oldest = oldestSlot(in: slots) {
            removeSlot(oldest.key)
        }
    }

    private func oldestSlot(in bucket: [WKey: Slot]) -> (key: WKey, slot: Slot)? {
        guard let min = bucket.min(by: { $0.value.at < $1.value.at }) else { return nil }
        return (key: min.key, slot: min.value)
    }

    private func removeSlot(_ key: WKey) {
        slots.removeValue(forKey: key)
        var appSlots = byApp[appKey(of: key)] ?? [:]
        appSlots.removeValue(forKey: key)
        if appSlots.isEmpty { byApp.removeValue(forKey: appKey(of: key)) }
        else { byApp[appKey(of: key)] = appSlots }
    }

    // MARK: Save / load

    private func scheduleSave() {
        if saveTimer != nil { return }
        saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
    }

    private func saveNow() {
        saveTimer = nil
        do {
            // Ключи кодируем руками (WKey не Codable): сохраняем слоты
            // как [String: Slot] — читабельный JSON, как было всегда.
            var map: [String: Slot] = [:]
            map.reserveCapacity(slots.count)
            for (k, v) in slots { map[k.asRaw] = v }
            let data = try JSONEncoder().encode(map)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log("can't save state: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    /// Загрузка. Новый формат — словарь сырых ключей; старый формат
    /// ({perApp…}/{perWindow…}) импортируем.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let map = try? JSONDecoder().decode([String: Slot].self, from: data) {
            for (raw, slot) in map {
                guard let key = WKey.fromRaw(raw) else { continue }
                slots[key] = slot
                var appSlots = byApp[appKey(of: key)] ?? [:]
                appSlots[key] = slot
                byApp[appKey(of: key)] = appSlots
            }
            return
        }

        // Старый формат (до 05.11.2026).
        struct Legacy: Codable {
            var perApp: [String: String]
            var perWindow: [String: [String: String]]
        }
        guard let old = try? JSONDecoder().decode(Legacy.self, from: data) else { return }
        for (bundleID, layout) in old.perApp {
            slots[.app(bundleID)] = Slot(layout: layout, at: Date())
        }
        for (bundleID, windows) in old.perWindow {
            for (title, layout) in windows {
                slots[.window(bundleID: bundleID, title: title)] = Slot(layout: layout, at: Date())
            }
        }
        for (key, slot) in slots {
            var appSlots = byApp[appKey(of: key)] ?? [:]
            appSlots[key] = slot
            byApp[appKey(of: key)] = appSlots
        }
        // Старые данные импортированы — следующее сохранение перезапишет
        // файл в новом формате.
        scheduleSave()
    }
}

// MARK: - Монитор ввода (для детекции «пользователь печатает»)

private final class InputMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var lastInputEvent = Date.distantPast
    private(set) var isRunning = false

    /// Требует «Input Monitoring»; без неё tap не создаётся, но
    /// программа работает (обучение опирается на паузу в 1.5 с).
    func start() {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        let callback: CGEventTapCallBack = { _, _, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.lastInputEvent = Date()
            return Unmanaged.passUnretained(event)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback, userInfo: userInfo) else {
            os_log("event tap unavailable (нет Input Monitoring?) — работаем без него", log: log)
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            isRunning = true
        }
    }
}

// MARK: - Движок

private final class SwitcherEngine {
    private let store: LayoutStore
    private let monitor: InputMonitor

    /// «Текущее окно»: нативный AX-элемент окна, а если окно определить
    /// нельзя (Safari) — заголовок окна/вкладки. Храним оба варианта
    /// (какой есть) и сравниваем оба.
    private var lastAxis: AXUIElement?
    private var lastTitle: String?
    private var lastPid: pid_t?
    /// Для браузера «место» — активная вкладка (ключ меняется на смене
    /// вкладки даже при неизменном AX-элементе окна).
    private var lastBrowser: BrowserTabKey?
    private var consecutive = 0
    private var entered = Date.distantPast
    private var lastLearned: Date = .distantPast

    /// Пауза перед обучением после смены окна.
    private let learnDelay: TimeInterval = 1.5
    /// Если монитор ввода есть — дополнительное условие: не учиться
    /// во время печати (тишина от последнего нажатия).
    private let idleThreshold: TimeInterval = 1.0

    init(store: LayoutStore, monitor: InputMonitor) {
        self.store = store
        self.monitor = monitor
    }

    /// Вызывается таймером каждые ~0.3 c.
    func tick() {
        guard let info = frontmostWindowInfo() else { return }

        let same = isSameWindow(info)

        if same {
            consecutive += 1
            // Окно стабильно ~0.6 c (две итерации) — применяем
            // сохранённую раскладку. Пауза гасит «перетягивание»
            // раскладки при быстрых Cmd-Tab.
            if consecutive == 2 {
                applySaved(info)
            }
            tryLearn(info)
        } else {
            consecutive = 1
            lastPid = info.pid
            if let w = info.focusedWindow ?? info.literalWindow {
                lastAxis = w
            } else {
                lastAxis = nil
            }
            lastTitle = info.title
            lastBrowser = info.browser
            entered = Date()
        }
    }

    private func isSameWindow(_ info: FrontWindowInfo) -> Bool {
        // В браузере «место» — активная вкладка. AX-элемент окна при
        // смене вкладки не меняется (у Safari/Chrome это стабильный
        // объект окна) — сравнение по нему не увидело бы смену.
        // Сравнение по ключу вкладки точнее для обоих браузеров
        // (Firefox: ключ по заголовку — меняется на смене вкладки).
        if info.browser != nil || lastBrowser != nil {
            return info.browser == lastBrowser
        }

        let axis = info.focusedWindow ?? info.literalWindow
        // Нативный элемент есть с обеих сторон — сравниваем его
        // (Safari с «фейковым» AX вернёт nil, и сравнение уходит дальше).
        if let axis, let last = lastAxis {
            return CFEqual(axis, last)
        }
        // Элемент недоступен хотя бы с одной стороны — сравниваем по
        // заголовку окна/вкладки: у Safari это единственный признак.
        let titleNow = info.title ?? ""
        if !titleNow.isEmpty, let last = lastTitle, last == titleNow {
            return true
        }
        // Заголовков нет вовсе — считаем «тем же окном» внутри приложения.
        if axis == nil && lastAxis == nil && lastTitle == nil && info.title == nil {
            return info.pid == lastPid
        }
        return false
    }

    private func applySaved(_ info: FrontWindowInfo) {
        lastApplied = Date()
        guard let key = WKey.forInfo(info),
              let saved = store.lookup(key) else {
            return
        }
        guard currentInputSourceID() != saved else { return }
        selectInputSource(saved)
        os_log("applied %{public}@%@ -> %{public}@ @ %{public}@",
               log: log, info.displayName,
               info.title.map { " [\($0)]" } ?? "", saved, key.description)
    }

    var lastApplied: Date? = nil
    /// Если в этом окне уже применили сохранённое — не перезаписываем
    /// его текущей раскладкой в тот же миг (learnDelay и так не даёт).
    private func wasJustApplied() -> Bool {
        guard let lastApplied else { return false }
        return Date().timeIntervalSince(lastApplied) < 0.5
    }

    private func tryLearn(_ info: FrontWindowInfo) {
        // Условия:
        // 1. окно активно дольше learnDelay (не учимся сразу после смены);
        // 2. только что применённая раскладка не перезаписывается (а то
        //    обучение «съест» автопереключение);
        // 3. если монитор ввода работает — с последнего нажатия прошло
        //    больше idleThreshold (не учимся во время печати);
        // 4. текущая раскладка отличается от запомненной.
        let now = Date()
        guard now.timeIntervalSince(entered) > learnDelay,
              now.timeIntervalSince(lastLearned) > learnDelay,
              !wasJustApplied() else { return }

        if monitor.isRunning && now.timeIntervalSince(monitor.lastInputEvent) < idleThreshold {
            return
        }
        guard let current = currentInputSourceID() else { return }

        guard let key = WKey.forInfo(info) else { return }
        if let saved = store.lookup(key), saved == current {
            return
        }
        // Не учимся «фоновым» раскладкам сразу после применения авто-
        // переключения: если применение не сработало — текущая может
        // оказаться иностранной, это редкий случай, перезапишется позже.
        store.remember(current, for: key)
        lastLearned = now
        os_log("learned %{public}@ for %{public}@%@ @ %{public}@",
               log: log, current, info.displayName,
               info.title.map { " [\($0)]" } ?? "", key.description)
    }
}

// MARK: - Приложение (меню-бар)

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store: LayoutStore
    private let engine: SwitcherEngine
    private let monitor = InputMonitor()
    private var statusItem: NSStatusItem?
    private var layoutTimer: Timer?
    private let launchAgentPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.xcommanderx.layoutswitcher.plist")

    init(store: LayoutStore) {
        self.store = store
        self.engine = SwitcherEngine(store: store, monitor: monitor)
        super.init()
    }

    /// В меню-баре — буква текущей раскладки: «Я» — русская, «A» — латинская.
    private func updateLayoutBadge() {
        guard let button = statusItem?.button else { return }
        button.title = frontmostLayoutLetter()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // без иконки в Dock
        buildMenu()

        if !isAXTrusted() {
            NSApp.setActivationPolicy(.regular) // алерт поверх текущих окон
            let alert = NSAlert()
            alert.messageText = "Нужен доступ к Специальным возможностям"
            alert.informativeText = """
            Открой Системные настройки → Приватность и безопасность → \
            Специальные возможности и добавь LayoutSwitcher в список. \
            Программа продолжит работать, доступ подхватится автоматически.
            """
            alert.runModal()
            openAccessibilitySettings()
        } else {
            startEngine()
        }

        // Периодически перепроверяем доступ (пользователь мог его дать).
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if isAXTrusted() {
                self.startEngine()
            }
        }
    }

    private var engineStarted = false
    private func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        monitor.start()
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.engine.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        // Бейдж буквы раскладки в меню-баре обновляется одновременно с движком.
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.updateLayoutBadge()
        }
        // Поддержание чистоты хранилища: забыть вкладки/окна, к которым
        // не возвращались 90+ дней. Раз в час — дёшево.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.store.forgetStale()
        }
        os_log("engine started", log: log)
    }

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.title = frontmostLayoutLetter()

        let menu = NSMenu()

        let status = NSMenuItem(title: "Layout Switcher", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        let layout = NSMenuItem(title: layoutText(), action: nil, keyEquivalent: "")
        layout.isEnabled = false
        menu.addItem(layout)
        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Запускать при входе",
                                   action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.state = launchAgentExists() ? .on : .off
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    private func layoutText() -> String {
        let cur = currentInputSourceID() ?? "?"
        return "Раскладка: \(cur)"
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAgentExists() {
            // Выключение автозапуска = снять агента и остановить процесс
            // (без KeepAlive он сам не воскреснет; см. quit()).
            let plist = launchAgentPath
            try? FileManager.default.removeItem(at: plist)
            stopViaLaunchd()
        } else {
            let binary = CommandLine.arguments[0]
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.xcommanderx.layoutswitcher</string>
                <key>ProgramArguments</key>
                <array><string>\(binary)</string></array>
                <key>RunAtLoad</key><true/>
            </dict>
            </plist>
            """
            do {
                try plist.write(to: launchAgentPath, atomically: true, encoding: .utf8)
            } catch {
                os_log("can't write launch agent: %{public}@", log: log, type: .error, error.localizedDescription)
            }
        }
        // Обновить пункт меню на месте (не пересоздавать status item —
        // NSStatusBar.system не держит items, старый ушёл бы под ARC,
        // и иконка из меню-бара исчезла бы при рабочем процессе).
        if let menu = statusItem?.menu {
            for item in menu.items {
                if item.title == "Запускать при входе" {
                    item.state = launchAgentExists() ? .on : .off
                }
            }
        }
        updateLayoutBadge()
    }

    private func launchAgentExists() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath.path)
    }

    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        // Снять автозапуск и погасить процесс через launchd: иначе "Выход"
        // из меню ничего не решает — агент с RunAtLoad поднимет процесс заново.
        try? FileManager.default.removeItem(at: launchAgentPath)
        stopViaLaunchd()
    }

    /// Остановить службу launchd (если агент установлен и загружен) и,
    /// как запасной вариант, убить процесс. Наш собственный процесс при
    /// этом завершится (NSApp.terminate во второй ветке) — это ожидаемо.
    private func stopViaLaunchd() {
        let label = "com.xcommanderx.layoutswitcher"
        for args in [["bootout", "gui/\(getuid())/\(label)"],
                     ["kill", "\(label)"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = args
            try? p.run()
            p.waitUntilExit()
        }
        NSApp.terminate(nil) // сам shutdown: pkill по имени мог задеть и нас
    }
}

// MARK: - Запуск

/// Одиночный инстанс: flock на файл, иначе два процесса будут
/// «перетягивать» раскладку друг у друга.
private func acquireSingleInstanceLock() -> Bool {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".layout-switcher")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lockURL = dir.appendingPathComponent("lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return true } // не смогли открыть — не мешаем
    let ok = flock(fd, LOCK_EX | LOCK_NB) == 0
    if !ok { close(fd) }
    return ok
}

/// Предупреждение о повторном запуске. Из GUI-приложения stdout не
/// виден, поэтому, кроме print, показываем системное уведомление —
/// фоновой программе оно не требует активации окна.
func warnAlreadyRunning() {
    os_log("another instance already running", log: log, type: .error)
    print("LayoutSwitcher уже запущен")
    let script = "display notification \"LayoutSwitcher уже запущен — новый экземпляр не создаётся.\" with title \"LayoutSwitcher\""
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", script]
    try? p.run()
    p.waitUntilExit()
}

let args = CommandLine.arguments
private let stateDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".layout-switcher")
try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
private let stateFile = stateDir.appendingPathComponent("state.json")

/// Абсолютный путь к LayoutSwitcher.app рядом с бинарём (если он есть).
/// Из .app (Contents/MacOS/) рядом бандла нет — вернётся nil.
private func appBundlePath() -> String? {
    let bin = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let appURL = bin.deletingLastPathComponent().appendingPathComponent("LayoutSwitcher.app")
    guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
    return appURL.path
}

/// Запуск из терминала нежелателен: процесс привязан к терминалу (закроешь —
/// умрёт) и на macOS 26 TCC-доступ не выдаётся (субъект — Terminal, а не
/// приложение). Поэтому бинарь, запущенный вне .app, переоткрывает себя как
/// приложение через `open` и завершается — терминал освобождается сразу.
private func relaunchThroughApp() -> Bool {
    if Bundle.main.bundleURL.pathExtension == "app" { return false } // уже из .app
    guard let app = appBundlePath() else { return false } // .app рядом нет — обычный запуск
    os_log("relaunching through app: %{public}@", log: log, type: .info, app)
    print("LayoutSwitcher запускается из приложения: \(app)")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = [app]
    try? p.run()
    p.waitUntilExit()
    return true
}

if args.contains("--quit") {
    // Остановка через launchd во всех случаях: если агент установлен и
    // загружен — bootout/kill гасит процесс; если агента нет — процесс
    // умирает только от TERM по имени (см. ниже).
    let label = "com.xcommanderx.layoutswitcher"
    let stop = Process()
    stop.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    stop.arguments = ["bootout", "gui/\(getuid())/\(label)"]
    try? stop.run()
    stop.waitUntilExit()
    let kill = Process()
    kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    kill.arguments = ["-x", "LayoutSwitcher"]
    try? kill.run()
    kill.waitUntilExit()
    exit(0)
}

if args.contains("--install") || args.contains("--uninstall") {
    // Путь в LaunchAgent всегда на бинарь внутри .app (запуск из терминала
    // не работает с TCC-доступом; при автозапуске важна атрибуция приложения).
    // Если .app рядом — используем его; иначе текущий бинарь.
    let binary: String
    if let app = appBundlePath() {
        binary = app + "/Contents/MacOS/LayoutSwitcher"
    } else {
        binary = CommandLine.arguments[0]
    }
    let content = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key><string>com.xcommanderx.layoutswitcher</string>
        <key>ProgramArguments</key>
        <array><string>\(binary)</string></array>
        <key>RunAtLoad</key><true/>
    </dict>
    </plist>
    """
    let target = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.xcommanderx.layoutswitcher.plist")
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try content.write(to: target, atomically: true, encoding: .utf8)
        if args.contains("--uninstall") {
            // --uninstall: агента сняли. Остановить LaunchAgent через launchd,
            // иначе служба останется загруженной вплоть до перезагрузки.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(target.deletingPathExtension().lastPathComponent)"]
            try? p.run()
            p.waitUntilExit()
        }
        print(args.contains("--install") ? "LaunchAgent установлен: \(target.path)" : "LaunchAgent удалён: \(target.path)")
    } catch {
        print("Ошибка записи LaunchAgent: \(error)")
        exit(1)
    }
    exit(0)
}

/// Самопроверка: ключи, LRU, импорт старого формата. Без GUI.
/// Запуск: ./LayoutSwitcher --selftest
private func runSelfTest() -> Int32 {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("  ok: \(name)") } else { failures += 1; print("  FAIL: \(name)") }
    }

    // Ключи: round-trip.
    let keys: [WKey] = [
        .app("com.apple.Safari"),
        .window(bundleID: "com.apple.Safari", title: "Сайт: раздел — с двоеточием"),
        .tab(bundleID: "com.apple.Safari", browserKey: .url("example.com/docs")),
        .tab(bundleID: "org.mozilla.firefox", browserKey: .title("Страница : вкладка")),
    ]
    for k in keys {
        check(WKey.fromRaw(k.asRaw) == k, "round-trip: \(k.asRaw)")
    }

    // Нормализация URL.
    check(normalizePageURL("https://www.Yandex.Ru/search?q=x#frag") == "yandex.ru/search",
          "normalizePageURL www+query")
    check(normalizePageURL("http://example.com/") == "example.com", "normalizePageURL root")
    check(normalizePageURL("not a url") == nil, "normalizePageURL garbage")

    // LRU-вытеснение: при переполнении уходит самая старая вкладка.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ls-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let store = LayoutStore(fileURL: dir.appendingPathComponent("state.json"))
    for i in 0..<(StoragePolicy.maxWindowsPerApp + 40) {
        store.remember("ru", for: .window(bundleID: "com.apple.Safari", title: "tab-\(i)"))
    }
    check(store.lookup(.window(bundleID: "com.apple.Safari", title: "tab-0")) == nil,
          "LRU: tab-0 (самая старая) вытеснена")
    check(store.lookup(.window(bundleID: "com.apple.Safari", title: "tab-\(StoragePolicy.maxWindowsPerApp + 39)")) == "ru",
          "LRU: свежая запись на месте")

    // Импорт старого формата.
    let old = """
    {"perApp":{"com.apple.Terminal":"com.apple.keylayout.US"},"perWindow":{"com.apple.Safari":{"Вики":"com.apple.keylayout.Russian"}}}
    """
    let oldFile = dir.appendingPathComponent("old.json")
    try? old.write(to: oldFile, atomically: true, encoding: .utf8)
    let store2 = LayoutStore(fileURL: oldFile)
    check(store2.lookup(.app("com.apple.Terminal")) == "com.apple.keylayout.US",
          "import: perApp")
    check(store2.lookup(.window(bundleID: "com.apple.Safari", title: "Вики")) == "com.apple.keylayout.Russian",
          "import: perWindow")

    try? FileManager.default.removeItem(at: dir)

    // Живой пробник (если AX-доступ есть): что видим для переднего окна.
    if isAXTrusted(), let info = frontmostWindowInfo() {
        print("  live: pid=\(info.pid) bundle=\(info.bundleID) title=\(info.title ?? "nil") browser=\(info.browser.map(\.description) ?? "nil")")
        let key = WKey.forInfo(info)
        print("  live key: \(key?.asRaw ?? "nil")")
    } else {
        print("  live: AX-доступа нет — пропускаю")
    }

    return failures == 0 ? 0 : 1
}

if args.contains("--selftest") {
    exit(runSelfTest())
}

guard acquireSingleInstanceLock() else {
    warnAlreadyRunning()
    exit(0)
}

// Терминальный запуск: переоткрываем себя как .app и возвращаем терминал.
// (guard до open, чтобы повторный ./LayoutSwitcher не плодил процессы.)
if relaunchThroughApp() { exit(0) }

let app = NSApplication.shared
private let delegate = AppDelegate(store: LayoutStore(fileURL: stateFile))
app.delegate = delegate
app.run()