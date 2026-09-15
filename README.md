# Valheim Druzhbodom modpack updater

Схема:

- Gale на машине администратора — источник клиентского профиля.
- `admin/publish.ps1`:
  - собирает серверный `BepInEx.zip` из `BepInEx/config` + `BepInEx/plugins`;
  - загружает его по FTP на игровой хостинг;
  - ждёт, пока администратор распакует архив через кнопку панели хостинга;
  - собирает **полный клиентский профиль**, включая BepInEx runtime/bootstrap;
  - создаёт GitHub Release с `client-profile.zip` и `manifest.json`.
- Клиенты используют `client/update.ps1` (Windows) или `client/update.sh` (Linux):
  - проверяют latest GitHub Release;
  - сравнивают версию;
  - при изменении скачивают один ZIP, проверяют SHA256 и целиком заменяют профиль;
  - запускают Valheim с BepInEx-профилем, который хранится отдельно от игры.

## Почему клиенту не надо отдельно ставить BepInEx

`client-profile.zip` содержит полный корень Gale-профиля, а не только `plugins/config`.
В том числе в нём должны быть:

- `BepInEx/core/...`;
- `winhttp.dll`;
- `doorstop_config.ini`;
- `.doorstop_version`;
- Linux launch script (`start_game_bepinex.sh` или `run_bepinex.sh`).

Поэтому первый запуск updater'а одновременно устанавливает BepInEx и модпак.

На Windows launcher копирует только минимальные Doorstop-файлы (`winhttp.dll`, `doorstop_config.ini`, `.doorstop_version`) в каталог Valheim. Сам `BepInEx`, моды и конфиги остаются во внешнем профиле. `doorstop_config.ini` в игре принудительно делается `enabled = false`, поэтому обычный запуск из Steam остаётся vanilla; updater включает Doorstop через launch arguments.

На Linux BepInEx launch script запускается прямо из внешнего профиля.

## Уже заданные параметры

```text
FTP: 185.189.255.48:21
Remote archive: /Server/BepInEx/BepInEx.zip
GitHub: idontknowhowbut/valheim-modpack-druzhbodom
Gale BepInEx:
%APPDATA%\com.kesomannen.gale\valheim\profiles\Valheim Ochen Nado\BepInEx
```

`publish.ps1` уже содержит эти значения как defaults.

---

# 1. Подготовка GitHub

Создать публичный репозиторий:

```text
idontknowhowbut/valheim-modpack-druzhbodom
```

Для admin publisher нужен GitHub token с правом создавать Releases в этом репозитории. Для fine-grained PAT достаточно выдать этому репозиторию `Contents: Read and write`.

## Локальные секреты администратора

В `admin/` есть файл `publish.local.ps1`. Заполни его один раз:

```powershell
@{
    FtpUser     = 'YOUR_FTP_LOGIN'
    FtpPassword = 'YOUR_FTP_PASSWORD'
    GitHubToken = 'github_pat_...'
}
```

Этот файл включён в `.gitignore` и **не должен попадать в публичный GitHub-репозиторий**.
В репозитории можно хранить `publish.local.example.ps1` как безопасный шаблон.

Приоритет GitHub token такой:

1. параметр `-GitHubToken`;
2. переменная окружения `GITHUB_TOKEN`;
3. `GitHubToken` из `publish.local.ps1`;
4. интерактивный запрос.

Для FTP приоритет такой:

1. параметр `-FtpCredential`;
2. `FtpUser` + `FtpPassword` из `publish.local.ps1`;
3. интерактивный `Get-Credential`.

То есть после заполнения локального файла обычный запуск `publish.ps1` больше не спрашивает ни FTP-креды, ни GitHub token.

---

# 2. Публикация новой версии

Запускать на Windows, где установлен Gale и находится профиль:

```powershell
powershell -ExecutionPolicy Bypass -File .\admin\publish.ps1
```

По умолчанию версия создаётся в формате:

```text
2026.09.14.0215
```

Можно задать руками:

```powershell
.\admin\publish.ps1 -Version 1.4.0
```

Процесс:

```text
Gale profile
   |
   +--> server BepInEx.zip --> FTP
   |                         |
   |                         +--> руками нажать "Распаковать архив BepInEx.zip"
   |                              в панели хостинга
   |
   +--> full client profile --> GitHub draft release
                                 |
                                 +--> client-profile.zip
                                 +--> manifest.json
```

Скрипт **не публикует GitHub Release сразу после FTP upload**. Он ждёт Enter, чтобы клиенты не получили новую сборку раньше сервера.

После FTP upload:

1. Открыть панель хостинга.
2. Нажать кнопку распаковки `BepInEx.zip`.
3. Перезапустить/проверить сервер, если требуется.
4. Вернуться в PowerShell и нажать Enter.
5. Только после этого GitHub Release становится публичным/latest.

Для тестовой сборки без FTP:

```powershell
.\admin\publish.ps1 -SkipFtp
```

Без GitHub:

```powershell
.\admin\publish.ps1 -SkipGitHub
```

## Исключения из сборки

Publisher удаляет из server/client архивов:

```text
*_player_*.dat
BepInEx/cache/
LogOutput.log
LogOutput.txt
```

Это сделано, чтобы личные runtime/player-файлы из Gale-профиля не разъезжались по всем клиентам.

---

# 3. Windows client

Игрок скачивает `client/update.ps1` и запускает:

```powershell
powershell -ExecutionPolicy Bypass -File .\update.ps1
```

На первом запуске скрипт предлагает стандартный каталог профиля:

```text
%APPDATA%\DruzhbodomValheim\profile
```

Пользователь может отказаться и выбрать другое место через стандартный Windows Folder Picker.

Valheim ищется автоматически по Steam libraries. Если не найден — пользователь выбирает каталог игры вручную.

Дальше каждый запуск:

```text
latest/manifest.json
        |
        +--> version == local --> launch
        |
        +--> version changed
                |
                +--> client-profile.zip
                +--> SHA256
                +--> extract to temporary profile
                +--> old profile -> .backup
                +--> new profile -> active
                +--> launch
```

Проверить обновления, но не запускать игру:

```powershell
.\update.ps1 -NoLaunch
```

Принудительно переустановить текущий release:

```powershell
.\update.ps1 -ForceUpdate
```

Launcher хранит настройки в:

```text
%APPDATA%\DruzhbodomValheim\launcher.json
```

Чтобы заново выбрать каталоги, достаточно удалить этот файл.

---

# 4. Linux client

Сделать скрипт исполняемым:

```bash
chmod +x update.sh
```

Запустить:

```bash
./update.sh
```

Стандартный профиль:

```text
~/.local/share/valheim-druzhbodom/profile
```

На первом запуске можно указать другой путь.

Требуются обычные утилиты:

```text
curl
unzip
sha256sum
```

`python3` желательно иметь для JSON parsing, но есть простой fallback parser.

## Рекомендуемый запуск Linux через Steam

После первого запуска можно прописать в Steam -> Valheim -> Properties -> Launch Options:

```text
"/ABSOLUTE/PATH/update.sh" --steam %command%
```

Например:

```text
"/home/alex/valheim-modpack/update.sh" --steam %command%
```

Тогда кнопка Play в Steam делает:

```text
Steam
  -> update.sh
      -> check/update
      -> profile/start_game_bepinex.sh
      -> %command%
```

То есть BepInEx и моды остаются вне каталога игры.

Без Steam integration можно просто запускать `./update.sh`; скрипт попробует напрямую запустить `valheim.x86_64` через BepInEx launcher. Steam при этом лучше держать запущенным.

Проверка без запуска:

```bash
./update.sh --no-launch
```

Принудительное обновление:

```bash
./update.sh --force
```

---

# Важный момент про сервер

FTP upload сам по себе **не распаковывает** `/Server/BepInEx/BepInEx.zip`.
Сейчас это остаётся ручным шагом через кнопку панели хостинга, потому что доступа к самой машине или API этой панели нет.

Это единственный ручной шаг в публикации.

---

# 5. Optional low-spec addon

Для слабых клиентских машин поддерживается отдельный клиентский слой `low-spec`.
Он **не попадает на FTP и игровой сервер**.

## Подготовка в Gale

Создай второй профиль Gale, например:

```text
Valheim Low Spec
```

В нём держи только моды, которые должны добавляться поверх основной сборки для слабого ПК:

```text
Valheim Low Spec/BepInEx/
├── plugins/   <- optimization mod + необходимые зависимости
└── config/    <- его конфиги
```

Полный BepInEx из этого профиля publisher не использует. Для addon берутся только
`BepInEx/plugins` и `BepInEx/config`.

Важно: не надо копировать в low-spec профиль всю основную сборку. Всё, что лежит
в его `plugins/config`, считается addon-слоем и при совпадении пути перезапишет
соответствующий файл базового профиля.

## Настройка publisher

В локальный `admin/publish.local.ps1` добавь путь к BepInEx второго Gale-профиля:

```powershell
@{
    FtpUser     = '...'
    FtpPassword = '...'
    GitHubToken = '...'

    LowSpecGaleBepInExPath = 'C:\Users\username\AppData\Roaming\com.kesomannen.gale\valheim\profiles\Valheim Low Spec\BepInEx'
}
```

Если `LowSpecGaleBepInExPath` пустой, publisher просто пропускает addon.

При публикации с настроенным low-spec профилем GitHub Release содержит:

```text
client-profile.zip     <- основная клиентская сборка
addon-low-spec.zip     <- только BepInEx/plugins + BepInEx/config из low-spec Gale profile
manifest.json
```

`manifest.json` содержит SHA256 и размер addon-а. Клиент проверяет его так же,
как основной архив.

## Как addon устанавливается у игрока

На первом запуске Windows/Linux updater спрашивает:

```text
Enable low-spec optimization addon? [y/N]
```

Обычный игрок отвечает `N`, игрок со слабым ПК — `Y`.

Установка происходит так:

```text
client-profile.zip
        |
        v
profile.__new
        |
        +-- addon-low-spec.zip распаковывается ПОВЕРХ
        |
        v
готовый profile -> active
```

То есть итоговый профиль остаётся одним. Addon не хранится как отдельная папка
во время игры — он является дополнительным слоем при сборке локального профиля.

При каждом новом Release updater сначала строит чистый базовый профиль, затем
снова накладывает выбранные addons. Поэтому strict sync сохраняется:

- удалённый из low-spec Gale-профиля мод исчезнет у игрока при следующем update;
- выключение low-spec приводит к переустановке чистого base profile, поэтому
  старые optimizer DLL не остаются;
- локально вручную добавленные файлы в управляемом `profile` не сохраняются.

### Windows

Выбор сохраняется в:

```text
%APPDATA%\DruzhbodomValheim\launcher.json
```

Включить addon вручную и запустить/обновить:

```powershell
.\update.ps1 -EnableLowSpec
```

Отключить:

```powershell
.\update.ps1 -DisableLowSpec
```

Можно использовать те же параметры через CMD wrapper:

```text
Druzhbodom-Valheim.cmd -EnableLowSpec
Druzhbodom-Valheim.cmd -DisableLowSpec
```

Обычный пользователь просто запускает:

```text
Druzhbodom-Valheim.cmd
```

### Linux

Включить:

```bash
./update.sh --enable-low-spec
```

Отключить:

```bash
./update.sh --disable-low-spec
```

Выбор сохраняется в `launcher.conf`.

## Обновление старых клиентов

Если у пользователя уже есть `launcher.json`/`launcher.conf`, созданный старой
версией updater-а, новая версия увидит отсутствие настройки addons, один раз
спросит про low-spec и сохранит ответ. Повторно спрашивать не будет.
