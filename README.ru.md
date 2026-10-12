<p align="center"><img src="packaging/AppIcon-1024.png" width="128" alt="MacroSIP icon"></p>

# MacroSIP

[English](README.md) · **Русский**

[![CI](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml/badge.svg)](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml)
[![License: GPL v2](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Apple Silicon](https://img.shields.io/badge/arch-arm64-lightgrey)
![PJSIP 2.17](https://img.shields.io/badge/PJSIP-2.17-green)
![Status: release candidate](https://img.shields.io/badge/status-release%20candidate-yellow)

SIP-софтфон для macOS на Apple Silicon в духе MicroSIP. Нативный интерфейс на
Swift и SwiftUI, движок [PJSIP](https://github.com/pjsip/pjproject) 2.17, без
Electron и Qt. Одно небольшое окно, значок в строке меню и всё, что умеет
настольный телефон.

<p align="center">
  <img src="docs/screenshots/dialpad-calls.png" width="300" alt="Несколько звонков">
  <img src="docs/screenshots/call-recording.png" width="300" alt="Активный звонок с записью">
  <img src="docs/screenshots/conference.png" width="300" alt="Конференция">
</p>
<p align="center">
  <img src="docs/screenshots/contacts-presence.png" width="300" alt="Контакты со статусами">
  <img src="docs/screenshots/account-popup.png" width="300" alt="Меню аккаунтов">
  <img src="docs/screenshots/incoming-auto-answer.png" width="300" alt="Входящий звонок с автоответом">
</p>

## Возможности

- Несколько SIP-аккаунтов с одновременной регистрацией; UDP, TCP и TLS с
  проверкой сертификата; SRTP; STUN и ICE.
- До четырёх одновременных звонков: ответ, удержание, отключение микрофона,
  DTMF, слепой и сопровождаемый перевод, локальная конференция.
- Запись разговоров в M4A (AAC), вручную или автоматически.
- Автоответ: выключен, на все звонки, только контакты, с задержкой; заголовок
  `Call-Info: answer-after` принимается только от вашей АТС.
- Статусы контактов: видно, кто доступен, отошёл или говорит по телефону;
  публикация своего статуса (Доступен, Отошёл, Не беспокоить).
- История звонков и контакты; ссылки `sip:`, `sips:` и `tel:` открываются в
  приложении.
- Значок в строке меню с состоянием регистрации, быстрым набором, последними
  звонками и режимом «Не беспокоить»; приложение работает и с закрытым окном.
- Кодеки: Opus, G.722, G.711 (PCMU/PCMA). Эхоподавление (WebRTC AEC).
- Интерфейс на английском и русском. Запуск при входе в систему, выбор языка,
  файл журнала.

Статус: кандидат в релиз `26.0.0-rc.1`; финальный `26.0.0` выйдет после проверки на
рабочей АТС. Что дальше: [docs/ROADMAP.md](docs/ROADMAP.md).

## Установка

Нужен macOS 14 или новее на Apple Silicon.

### Через Homebrew

```sh
brew tap hsmm/tap
brew install --cask hsmm/tap/macrosip
```

### Из DMG

1. Скачайте `MacroSIP-<версия>.dmg` из
   [последнего релиза](https://github.com/HSMM/MacroSIP/releases/latest).
2. Откройте образ и перетащите MacroSIP в папку «Программы».
3. Первый запуск: приложение подписано ad hoc (без нотаризации), поэтому macOS
   сначала откажется его открыть. Нажмите правой кнопкой на MacroSIP в папке
   «Программы», выберите «Открыть» и подтвердите, либо один раз выполните
   `xattr -dr com.apple.quarantine /Applications/MacroSIP.app`.

Журнал пишется в `~/Library/Logs/MacroSIP/MacroSIP.log`; в Настройках › Основные
есть «Открыть папку журнала» и «Скопировать диагностику» для сообщений об
ошибках.

## Сборка

Требования: macOS 14 или новее на Apple Silicon, Xcode Command Line Tools,
Homebrew с пакетами `openssl@3`, `opus` и `pkgconf`. Полный Xcode не нужен.

```sh
git clone https://github.com/HSMM/MacroSIP.git
cd MacroSIP
scripts/build-pjsip.sh      # один раз скачивает и собирает PJSIP 2.17 (несколько минут)
swift build -c release      # собирает Swift-пакеты
scripts/make-app.sh         # собирает dist/MacroSIP.app (подпись ad hoc)
open dist/MacroSIP.app
scripts/make-dmg.sh         # по желанию: dist/MacroSIP-<версия>.dmg
```

Сборки подписаны ad hoc, поэтому при первом запуске macOS попросит подтвердить
открытие приложения от неустановленного разработчика.

### Тесты

```sh
scripts/test.sh             # наборы Swift Testing (модульные тесты и тесты движка через loopback)
scripts/selftest-call.sh    # сквозной звонок на локальный pjsua: RTP в обе стороны, удержание,
                            # DTMF, запись и конвертация в M4A, статусы, конференция из двух ног,
                            # входящие звонки, переводы
```

### Отладка

```sh
open dist/MacroSIP.app --args --log-level 5
log show --last 10m --predicate 'subsystem == "com.hsmm.macrosip"' --info
```

`--log-level` (0–6) задаёт подробность журнала PJSIP; приложение пишет в
unified log с подсистемой `com.hsmm.macrosip`.

## Выпуск релиза

Чек-лист владельца; подробности в [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md#releasing).

1. Обновить `Product.version` и поставить тег `26.0.0` (кандидаты: `26.0.0-rc.1`), отправить тег.
2. `.github/workflows/release.yml` собирает DMG и создаёт GitHub Release.
3. Тот же workflow обновляет Homebrew cask в `HSMM/homebrew-tap`. Разовая настройка:
   создать публичный репозиторий `HSMM/homebrew-tap`, затем fine-grained personal access
   token с правами Contents read/write только на него и сохранить как секрет Actions
   `TAP_TOKEN` в `HSMM/MacroSIP`. Без секрета шаг пропускается.

## Структура проекта

| Путь | Что |
|---|---|
| `Sources/CPJSUA` | C-прослойка над pjsua, единственное место с заголовками PJSIP |
| `Sources/MacroSIPCore` | Движок (аккаунты, звонки, конференция, запись, статусы), модели, хранилище |
| `Sources/MacroSIPApp` | Приложение на SwiftUI/AppKit |
| `Sources/macrosip-cli` | Телефон командной строки для самопроверки и отладки с АТС |
| `docs/` | Дорожная карта, проектная документация, ADR, спецификация UI и макеты |
| `scripts/` | Сборка PJSIP, сборка приложения, DMG, иконка, обновление cask, тесты |
| `packaging/` | Entitlements, иконка, шаблон Homebrew cask |
| `.github/workflows/` | CI и релизные workflow |

Документация: [ROADMAP](docs/ROADMAP.md), [устройство движка](docs/ENGINE.md),
[спецификация UI](docs/design/SCREENS.md), [решения](docs/adr/).

## Лицензия

GPLv2 или новее, потому что PJSIP распространяется под GPLv2+. См. [LICENSE](LICENSE).
