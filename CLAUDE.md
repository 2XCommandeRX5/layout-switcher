# keyboard-layout-switcher — авто-переключение раскладки по активному окну

Фоновая macOS-программа (Swift, AppKit): запоминает раскладку для каждого
приложения/окна (окна различаются по заголовку, у браузера — по заголовку
вкладки) и применяет её при смене активного окна. Пассивное обучение: активная
раскладка при отсутствии ввода сохраняется как выбор пользователя.

- Код: `LayoutSwitcher.swift` (один файл), сборка — `build_app.sh` (swiftc + `.app`).
- Бандл: `LayoutSwitcher.app`, bundle id `com.stefania.layoutswitcher`, ad-hoc подпись.
- Данные: `~/.layout-switcher/state.json`; лог: `log show --predicate 'subsystem == "com.stefania.layoutswitcher"'`.
- Подробное пользовательское описание — `README.md`. Здесь — технические грабли агента.

## Сборка и запуск (важно)

```sh
cd ~/Stefania/keyboard-layout-switcher
./build_app.sh
open LayoutSwitcher.app            # или ./LayoutSwitcher
```

**Запуск только из `.app`** (через `open` или автозапуск): macOS 26 выдаёт
TCC-доступ субъекту через процесс-ответственного — при прямом запуске бинаря из
терминала запрос идёт от имени Terminal, и Специальные возможности не выдаются.
`./LayoutSwitcher` сам открывает себя как `.app` и возвращает терминал
(процесс не привязан к нему).

## Грабли (не ломать)

- **Клик «Запускать при входе» не должен трогать статус-бар.** `NSStatusBar.system`
  не держит items: `buildMenu()` каждый раз создаёт новый `NSStatusItem`, старые
  уходят под ARC — иконка исчезает при живом процессе. Фикс (03.11):
  `toggleLaunchAtLogin()` только обновляет `state` существующего пункта меню
  (+ `updateLayoutBadge()`); `buildMenu()` вызывается один раз в
  `applicationDidFinishLaunching` (LayoutSwitcher.swift:419, 498).
- **Пересборка отзывает TCC-доступ**: ad-hoc подпись меняет CDHash → запись
  Специальных возможностей перестаёт действовать (`AUTHREQ_RESULT authValue=2`
  в tccd), движок не стартует («engine started» в логах нет). После каждой
  пересборки нужно снова подтвердить доступ по диалогу macOS.
  Проверка: `codesign -dv --verbose=4 <app>`; RN/TCC лог:
  `log show --last 3m --predicate 'process == "tccd" AND (eventMessage CONTAINS[c] "layoutswitcher")'`.
- **На локскрине движок не стартует**: `AXIsProcessTrusted()` → false, TCC-запись
  отсутствует. Пробник из шелла trusted=true. Это ожидаемо, не «чинить».
- **Safari не отдаёт реальные AX-окна** (`kAXWindows` возвращает сам AXApplication):
  детекция смены окна/вкладки идёт через `title` в `FrontWindowInfo`
  (Safari: title = заголовок вкладки). Не менять детекцию на чистый AX-элемент.
- У Safari/браузера смена вкладки = смена окна (по заголовку) — по дизайну.
- Пауза стабилизации в `tick()` (сейчас 0.3 с / 2 итерации): при «перетягивании»
  раскладки на быстрых Cmd-Tab слегка увеличивать — и точечно, движок живой.

## Управление

`./LayoutSwitcher --install` — автозапуск при входе (LaunchAgent на бинарь внутри
.app); `--quit` — завершить инстанс; `--uninstall` — записать LaunchAgent-файл
для ручного `rm`. В меню-баре — буква раскладки («Я»/«A»), обновляется раз в 0.3 с.