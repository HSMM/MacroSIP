<p align="center"><img src="packaging/AppIcon-1024.png" width="128" alt="MacroSIP icon"></p>

# MacroSIP

[English](README.md) · **Русский**

[![CI](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml/badge.svg)](https://github.com/HSMM/MacroSIP/actions/workflows/ci.yml)
[![License: GPL v2](https://img.shields.io/badge/license-GPLv2%2B-blue.svg)](LICENSE)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-lightgrey)
![Universal: Apple Silicon and Intel](https://img.shields.io/badge/arch-universal-lightgrey)
![PJSIP 2.17](https://img.shields.io/badge/PJSIP-2.17-green)
![Release 26.0.0 in preparation](https://img.shields.io/badge/release-26.0.0_%D0%B3%D0%BE%D1%82%D0%BE%D0%B2%D0%B8%D1%82%D1%81%D1%8F-orange)

SIP-софтфон для macOS на Apple Silicon и Intel в духе MicroSIP. Нативный интерфейс на
Swift и SwiftUI, движок [PJSIP](https://github.com/pjsip/pjproject) 2.17, без
Electron и Qt. Одно небольшое окно, значок в строке меню и всё, что умеет
настольный телефон.

## Возможности

- Несколько SIP-аккаунтов с одновременной регистрацией; UDP, TCP и TLS с проверкой сертификата; SRTP; STUN и ICE; аккаунты «только исходящие»; включение и выключение аккаунтов в меню.
- До четырёх звонков: ответ, удержание, отключение микрофона, DTMF (RFC 2833, SIP INFO или in-band), слепой и сопровождаемый перевод, локальная конференция (объединение включает удержанные звонки); индикатор качества с предупреждением о плохой связи; громкость динамика, микрофона и рингтона.
- Запись разговоров в M4A (AAC), моно или стерео (ваш голос слева, собеседник справа); воспроизведение из журнала.
- Автоответ (выключен, на все звонки, только контакты, с задержкой); режим одного звонка или ожидание вызова; правила отклонения входящих (все, номера не из контактов, анонимные); «Не беспокоить», в том числе по таймеру.
- Карточка контакта с фото, организацией, несколькими номерами с подписями, e-mail и заметками; избранное; статусы отслеживаемых контактов и публикация своего статуса.
- Справочник пользователей: LDAP, URL (CSV или JSON), Google Контакты или программа «Контакты» macOS; подсказки в поле номера, поиск входящих по номеру, только поиск или импорт в контакты.
- Быстрые клавиши: до 12 клавиш быстрого набора с BLF рядом с главным окном или под ним; типы «Звонок», DTMF, перевод и конференция; перехват звонка по мигающей клавише.
- Журнал звонков; ссылки `sip:`, `sips:` и `tel:` открываются в приложении.
- Значок в строке меню с состоянием регистрации, быстрым набором, последними звонками и «Не беспокоить»; приложение работает и с закрытым окном.
- Восстановление связи после обрыва сети, смены IP или сна; разговор при этом не прерывается. Раздел «Сеть»: диапазон портов RTP, rport, DNS SRV с собственным сервером имён.
- Кодеки: Opus (с FEC и DTX), G.722, G.711 и, выключенные по умолчанию, G.722.1, GSM, iLBC и Speex. Эхоподавление и подавление шума.
- Интерфейс на английском и русском, светлая и тёмная темы, запуск при входе, файл журнала, обновление из приложения.
- Музыка на удержании для собеседника (встроенная или свой файл), тон уведомления о записи, индикатор голосовой почты (MWI) со звонком в один клик, кнопки USB-гарнитуры, звуковые события и проверка звука.
- Универсальное приложение для Apple Silicon и Intel.

## Скриншоты

<p align="center">
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ru/dark/dialpad-calls.png?v=1"><img src="docs/screenshots/ru/light/dialpad-calls.png?v=1" width="260" alt="Несколько звонков"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ru/dark/contacts-presence.png?v=1"><img src="docs/screenshots/ru/light/contacts-presence.png?v=1" width="260" alt="Контакты со статусами"></picture>
  <picture><source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/ru/dark/call-recording.png?v=1"><img src="docs/screenshots/ru/light/call-recording.png?v=1" width="260" alt="Активный звонок с записью"></picture>
</p>

Приложение следует оформлению macOS. Слева светлая тема, справа тёмная:

<p align="center">
  <img src="docs/screenshots/ru/light/account-popup.png?v=1" width="260" alt="Меню аккаунтов, светлая тема">
  <img src="docs/screenshots/ru/dark/account-popup.png?v=1" width="260" alt="Меню аккаунтов, тёмная тема">
</p>

Больше скриншотов на двух языках и в обеих темах: [docs/screenshots](docs/screenshots).

Статус: готовится первый релиз, 26.0.0; до него собирайте из исходников (см. ниже). Что дальше: [docs/ROADMAP.md](docs/ROADMAP.md).

## Установка

Нужен macOS 14 или новее на Apple Silicon или Intel. Приложение и DMG универсальные
(одна загрузка для обеих архитектур). Оба способа ниже станут доступны с выходом 26.0.0.

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

### Обновления

MacroSIP раз в день проверяет обновления и спрашивает перед установкой; MacroSIP › Проверить
наличие обновлений… проверяет сразу. В Настройках › Основные › Обновления можно выключить
ежедневную проверку или включить предварительные версии. Обновления подписаны и проверяются перед
установкой, а обновлённое приложение открывается без запроса первого запуска. Установка через
Homebrew обновляется так же. Приложение подписано ad hoc, поэтому после каждого обновления macOS
снова спрашивает доступ к микрофону; разрешите его ещё раз.

Журнал пишется в `~/Library/Logs/MacroSIP/MacroSIP.log`; в Настройках › Основные
есть «Открыть папку журнала» и «Скопировать диагностику» для сообщений об
ошибках.

## Сборка

Требования: macOS 14 или новее на Mac с Apple Silicon и Xcode Command Line Tools.
Полный Xcode и пакеты Homebrew не нужны: OpenSSL и Opus собираются из закреплённых
исходников вместе с PJSIP. Intel-часть (x86_64) универсальной сборки собирается
кросс-компиляцией на том же Mac.

```sh
git clone https://github.com/HSMM/MacroSIP.git
cd MacroSIP
scripts/build-pjsip.sh      # один раз собирает OpenSSL, Opus и PJSIP 2.17 для arm64 и x86_64 (около 5 минут)
swift build -c release      # собирает Swift-пакеты (родная архитектура)
scripts/make-app.sh         # собирает универсальное dist/MacroSIP.app (подпись ad hoc)
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

1. Поставить тег `26.0.0` (кандидаты: `26.0.0-rc.1`) и отправить его; версию приложение берёт из тега. Для финального релиза также обновить `Product.fallbackVersion`.
2. `.github/workflows/release.yml` собирает DMG, создаёт GitHub Release и добавляет его в ленту
   обновлений (`appcast.xml` в ветке `gh-pages`, подпись секретом Actions `SPARKLE_PRIVATE_KEY`;
   ADR 0013). Каждый релиз ставится на новый коммит, финальный после кандидата тоже.
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
