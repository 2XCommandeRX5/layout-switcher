import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import os.log

// ============================================================
// LayoutSwitcher
//
// Фоновая программа для macOS: запоминает раскладку клавиатуры
// для каждого приложения (и каждого окна приложения) и автоматически
// переключает её при смене активного окна.
//
// Поведение:
//   - при смене активного окна применяет последнюю запомненную для
//     него раскладку;
//   - раскладка «запоминается» пассивно: когда в окне нет ввода
//     и текущая раскладка отличается от сохранённой, она сохраняется;
//   - окна одного приложения различаются по заголовку окна, поэтому
//     два окна браузера могут иметь разные раскладки.
//
// Сборка:  swiftc -O LayoutSwitcher.swift -o LayoutSwitcher
// Запуск:  ./LayoutSwitcher [--quit | --install | --uninstall]
// ============================================================

let log = OSLog(subsystem: "com.stefania.layoutswitcher", category: "main")

// MARK: - Accessibility: активное окно

private func isAXTrusted() -> Bool {
    AXIsProcessTrusted()
}

/// Информация о переднем окне: PID приложения, заголовок окна и
/// элементы окна (для сравнения «это то же окно или новое»).
private struct FrontWindowInfo {
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

    return FrontWindowInfo(pid: pid, bundleID: bundleID, displayName: displayName,
                           title: title, focusedWindow: focusedWindow,
                           literalWindow: literalWindow)
}

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

private struct AppState: Codable {
    /// bundleID -> раскладка приложения
    var perApp: [String: String] = [:]
    /// bundleID -> (заголовок окна -> раскладка окна)
    var perWindow: [String: [String: String]] = [:]

    static let empty = AppState()
}

private final class LayoutStore {
    private var state = AppState.empty
    private let fileURL: URL
    private var saveTimer: Timer?

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Раскладка для ключа: точное окно → приложение → nil.
    func lookup(bundleID: String, title: String?) -> String? {
        if let t = title, !t.isEmpty, let w = state.perWindow[bundleID]?[t] {
            return w
        }
        return state.perApp[bundleID]
    }

    /// Запомнить раскладку. Заголовок есть — пишем привязанную к окну,
    /// нет — прикладную.
    func remember(_ layout: String, bundleID: String, title: String?) {
        if let t = title, !t.isEmpty {
            var windows = state.perWindow[bundleID] ?? [:]
            if windows.count >= 30 {
                // окно могло сменить заголовок — двигаем свежее вперёд,
                // старое вытесняем
                windows.removeValue(forKey: windows.keys.first!) // arbitrary; см. ниже
            }
            windows[t] = layout
            state.perWindow[bundleID] = windows
        } else {
            state.perApp[bundleID] = layout
        }
        scheduleSave()
    }

    /// Забыть всё про приложение (при его удалении из записей).
    func forget(bundleID: String) {
        state.perApp.removeValue(forKey: bundleID)
        state.perWindow.removeValue(forKey: bundleID)
        scheduleSave()
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
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            os_log("can't save state: %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(AppState.self, from: data) else { return }
        state = decoded
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
            entered = Date()
        }
    }

    private func isSameWindow(_ info: FrontWindowInfo) -> Bool {
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
        guard let saved = store.lookup(bundleID: info.bundleID, title: info.title) else {
            return
        }
        guard currentInputSourceID() != saved else { return }
        selectInputSource(saved)
        os_log("applied %{public}@%@ -> %{public}@",
               log: log, info.displayName,
               info.title.map { " [\($0)]" } ?? "", saved)
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

        if let saved = store.lookup(bundleID: info.bundleID, title: info.title),
           saved == current {
            return
        }
        // Не учимся «фоновым» раскладкам сразу после применения авто-
        // переключения: если применение не сработало — текущая может
        // оказаться иностранной, это редкий случай, перезапишется позже.
        store.remember(current, bundleID: info.bundleID, title: info.title)
        lastLearned = now
        os_log("learned %{public}@ for %{public}@%@",
               log: log, current, info.displayName,
               info.title.map { " [\($0)]" } ?? "")
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
        .appendingPathComponent("Library/LaunchAgents/com.stefania.layoutswitcher.plist")

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
            try? FileManager.default.removeItem(at: launchAgentPath)
        } else {
            let binary = CommandLine.arguments[0]
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>com.stefania.layoutswitcher</string>
                <key>ProgramArguments</key>
                <array><string>\(binary)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
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
        NSApp.terminate(nil)
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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    p.arguments = ["-x", "LayoutSwitcher"]
    try? p.run()
    p.waitUntilExit()
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
        <key>Label</key><string>com.stefania.layoutswitcher</string>
        <key>ProgramArguments</key>
        <array><string>\(binary)</string></array>
        <key>RunAtLoad</key><true/>
        <key>KeepAlive</key><true/>
    </dict>
    </plist>
    """
    let target = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/com.stefania.layoutswitcher.plist")
    try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do {
        try content.write(to: target, atomically: true, encoding: .utf8)
        print(args.contains("--install") ? "LaunchAgent установлен: \(target.path)" : "LaunchAgent записан; удалить: rm \(target.path)")
    } catch {
        print("Ошибка записи LaunchAgent: \(error)")
        exit(1)
    }
    exit(0)
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