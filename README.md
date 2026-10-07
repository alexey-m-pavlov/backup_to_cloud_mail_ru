# Backup-ToCloudMailRu

Автоматизированное резервное копирование набора локальных папок в облако
**Cloud@mail.ru** через rclone. Реализовано на PowerShell 7, запускается
из Планировщика задач Windows 11.

## Содержание

- [Возможности](#возможности)
- [Состав проекта](#состав-проекта)
- [Требования](#требования)
- [Разовая настройка](#разовая-настройка)
- [Кэширование хэшей](#кэширование-хэшей)
- [Конфигурация](#конфигурация)
- [Особенность путей в JSON](#особенность-путей-в-json)
- [Запуск из Планировщика задач](#запуск-из-планировщика-задач)
- [Коды выхода](#коды-выхода)
- [Логи](#логи)
- [Безопасность](#безопасность)
- [Перенос между машинами](#перенос-между-машинами)
- [Известные ограничения](#известные-ограничения)

## Возможности

- Рекурсивное копирование произвольного набора локальных папок в облако.
- Режимы `copy` (безопасный, без удаления на удалённой стороне) и `sync`.
- Защита от параллельных запусков через lock-файл.
- Пароль конфигурации rclone читается из Windows Credential Manager.
- Предварительная проверка файлов, превышающих лимит облака.
- Раздельный лог неудачных файлов (`failed_YYYYMMDD.log`).
- Режим `-WhatIf` для безопасной проверки без реальных операций.
- Единый лог-файл на сутки, ротация по сроку хранения.
- Логирование через `StreamWriter` с буферизацией.
- Маски исключений для каждой папки.
- Кэширование хэшей через hasher-remote: повторные запуски проходят
  значительно быстрее, так как rclone не перечитывает неизменённые файлы.

## Состав проекта

```
Backup-ToCloudMailRu/
├── .gitignore
├── Backup-ToCloudMailRu.ps1
├── backup.config.json              локальный, в git не попадает
├── backup.config.example.json      шаблон
├── README.md
├── secrets/
│   └── rclone.conf                 зашифрованный конфиг rclone
└── logs/                           создаётся автоматически
```

| Файл | Назначение |
|---|---|
| `Backup-ToCloudMailRu.ps1` | Основной скрипт резервного копирования |
| `backup.config.json` | Конфигурация: пути, remote, папки, логирование |
| `backup.config.example.json` | Шаблон конфигурации для новых машин |
| `secrets/rclone.conf` | Зашифрованный конфиг rclone (не коммитится) |
| `README.md` | Этот файл |
| `logs/` | Папка логов (создаётся автоматически) |

## Требования

- **Windows 11** (также работает на Windows 10).
- **PowerShell 7+** (`pwsh.exe`).
- **rclone** — скачать с [rclone.org](https://rclone.org/downloads/).
- **Модуль TUN.CredentialManager**:
  ```powershell
  Install-Module -Name TUN.CredentialManager -Scope CurrentUser -Force
  ```
- Действующий аккаунт **Cloud@mail.ru** и пароль приложения Mail.ru.

## Разовая настройка

### 1. Создание структуры папок

```
Backup-ToCloudMailRu/
├── secrets/
└── logs/
```

Папки создаются автоматически при первом запуске скрипта, но `secrets/`
удобнее создать заранее — туда вы положите `rclone.conf`.

### 2. Настройка rclone для Cloud@mail.ru

Создайте пароль для внешних приложений в настройках безопасности Mail.ru.
Выберите уровень доступа **«Полный доступ к Почте, Облаку и Календарю»**
(all protocols) — вариант «Только Cloud (WebDav)» с rclone не работает.

Укажите rclone, где хранить конфиг. Два способа:

**Способ A — через переменную окружения** (действует только в текущей
сессии PowerShell):

```powershell
$env:RCLONE_CONFIG = "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf"
rclone config
```

**Способ B — через параметр `--config`** при каждом вызове:

```powershell
rclone --config "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf" config
```

В диалоге `rclone config`:

- `n` — новый remote
- Имя: `mailru`
- Тип: **`mailru`** (не `webdav`)
- Введите email и пароль приложения

Проверьте подключение:

```powershell
rclone --config "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf" lsd mailru:
```

### 3. Добавление hasher-remote

После того как remote `mailru` создан, добавьте в `rclone.conf` две секции —
hasher-обёртки для кэширования хэшей. Откройте конфиг:

```powershell
rclone --config "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf" config
```

Выберите `n` (новый remote) и создайте первый:

- Имя: `mailru-hasher`
- Тип: `hasher`
- `remote`: `mailru:`
- `hashes`: `mailru`
- `max_age`: `off`

Затем второй:

- Имя: `local-hasher`
- Тип: `hasher`
- `remote`: оставить **пустым** (Enter)
- `hashes`: `mailru`
- `max_age`: `off`

В итоге в `rclone.conf` должно получиться:

```ini
[mailru]
type = mailru
user = ваш_логин@mail.ru
pass = <обфусцированный пароль>
token = <токен>

[mailru-hasher]
type = hasher
remote = mailru:
hashes = mailru
max_age = off

[local-hasher]
type = hasher
remote =
hashes = mailru
max_age = off
```

**Зачем два hasher-remote:**

- `mailru-hasher` — кэширует хэши файлов на стороне облака. Используется
  как `RemoteName` в конфиге.
- `local-hasher` — кэширует хэши локальных файлов. Скрипт обращается
  к нему как к источнику (`local-hasher:D:\Path`). Имя `local-hasher`
  **жёстко зашито в коде** — если переименуете секцию, поправьте скрипт.

У обоих должен быть `hashes = mailru` — это модифицированный SHA1,
который использует Mail.ru. Только с этим типом хэши локальной и удалённой
стороны будут сопоставимы.

### 4. Шифрование конфигурации rclone

```powershell
rclone --config "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf" config
```

Выберите `s` (Set configuration password) и задайте пароль. Запомните его —
он понадобится на следующем шаге.

### 5. Сохранение пароля конфигурации в Credential Manager

От имени того же пользователя, под которым будет работать задача:

```powershell
Import-Module TUN.CredentialManager
$cred = Get-Credential -Message "Пароль конфигурации rclone" -UserName "rclone"
New-StoredCredential -Target "rclone-config-pass" -Credential $cred -Persist LocalMachine
```

Имя цели (`rclone-config-pass`) должно совпадать с полем `CredentialTarget`
в `backup.config.json`.

Если при выполнении `New-StoredCredential` возникает ошибка
`Could not load type 'System.Web.Security.Membership'`, в системе
установлен старый модуль `CredentialManager`. Удалите его и установите
форк:

```powershell
Uninstall-Module -Name CredentialManager -AllVersions -Force
Install-Module -Name TUN.CredentialManager -Scope CurrentUser -Force
```

### 6. Проверка связки

```powershell
$env:RCLONE_CONFIG_PASS = (Get-StoredCredential -Target "rclone-config-pass").GetNetworkCredential().Password
rclone --config "C:\Scripts\Backup-ToCloudMailRu\secrets\rclone.conf" lsd mailru-hasher:
$env:RCLONE_CONFIG_PASS = $null
```

Если команда вывела список папок — всё настроено.

### 7. Пробный запуск

```powershell
.\Backup-ToCloudMailRu.ps1 -WhatIf
```

Скрипт покажет, какие операции были бы выполнены, без реальной загрузки.

## Кэширование хэшей

Ключевая особенность текущей схемы — **кэш хэшей** в hasher-remote. Это
радикально ускоряет повторные запуски.

### Как это работает

1. Первый запуск: rclone перечитывает все локальные файлы, вычисляет хэши
   типа `mailru` и **сохраняет их в локальную базу данных**.
2. Последующие запуски: rclone берёт хэши из кэша. Перечитываются только
   файлы, у которых изменился размер или mtime. Файлы, которые не менялись,
   не читаются вообще.
3. Сравнение с облаком идёт по `--checksum` — по хэшам, а не по размеру
   и времени.

### Где хранится кэш

База данных hasher лежит в кэш-директории rclone:

```
%LOCALAPPDATA%\rclone\kv\local-hasher.bolt
%LOCALAPPDATA%\rclone\kv\mailru-hasher.bolt
```

Точный путь можно узнать командой:

```powershell
rclone config paths
```

Не удаляйте эти файлы — иначе первый запуск снова будет долгим.

### Как обновить кэш вручную

Если нужно принудительно пересчитать все хэши (например, после переноса
на новую машину или при подозрении на порчу кэша), используйте `hashsum`
с флагом `--download`:

```powershell
rclone hashsum mailru --download "local-hasher:D:\Energames"
rclone hashsum mailru --download "local-hasher:D:\Users\pavlov\Pictures\Фотографии"
```

Подставьте свои пути из `Folders[].LocalPath`. Команда перечитает каждый
файл, обновит кэш и выведет список хэшей.

### Сброс кэша

Полностью очистить кэш hasher:

```powershell
rclone backend drop local-hasher:
rclone backend drop mailru-hasher:
```

После этого следующий запуск будет таким же долгим, как первый.

## Конфигурация

### Корневые поля

| Поле | Обязательное | Описание |
|---|---|---|
| `RclonePath` | Да | Полный путь к `rclone.exe` |
| `RcloneConfigPath` | Нет | Путь к `rclone.conf`. Относительный — от папки скрипта |
| `RemoteName` | Да | Имя hasher-remote для облака (например, `mailru-hasher`) |
| `TransferMode` | Нет | `copy` (по умолчанию) или `sync` |
| `ExtraFlags` | Нет | Массив дополнительных флагов rclone |
| `MaxFileSizeBytes` | Нет | Лимит размера файла. По умолчанию 2 ГБ |
| `CredentialTarget` | Да | Имя учётной записи в Credential Manager |

### Раздел `Retry`

| Поле | Описание |
|---|---|
| `MaxRetries` | Максимальное число попыток на папку |
| `BaseDelaySeconds` | База экспоненциальной задержки между попытками |

### Раздел `Logging`

| Поле | Описание |
|---|---|
| `Directory` | Папка логов. Относительный путь — от папки скрипта |
| `RetentionDays` | Сколько дней хранить логи. `0` — не удалять |

### Раздел `Folders`

| Поле | Обязательное | Описание |
|---|---|---|
| `Enabled` | Нет | `false` — запись пропускается |
| `LocalPath` | Да | Абсолютный путь к локальной папке |
| `RemotePath` | Да | Путь на WebDAV-хранилище |
| `ExcludeMask` | Нет | Маски исключений через `;` (синтаксис rclone) |

### Режимы передачи

- **`copy`** — только добавляет новые и изменённые файлы. Удалённые локально
  файлы **остаются** в облаке. Безопасный режим, рекомендуется по умолчанию.
- **`sync`** — делает удалённую папку точной копией локальной, **удаляя**
  всё лишнее на удалённой стороне.

## Особенность путей в JSON

JSON использует обратный слэш (`\`) как служебный символ экранирования.
В полях с **локальными путями** бэкслэши нужно **удваивать**:

| Что вы хотите | Что писать в JSON |
|---|---|
| `C:\Tools\rclone\rclone.exe` | `"C:\\Tools\\rclone\\rclone.exe"` |
| `D:\ImportantData\Documents` | `"D:\\ImportantData\\Documents"` |
| `\\server\share\folder` (UNC) | `"\\\\server\\share\\folder"` |
| `logs` (относительный) | `"logs"` — без изменений |
| `secrets\rclone.conf` (относительный) | `"secrets\\rclone.conf"` |

Правило применяется к полям:

- `RclonePath`
- `RcloneConfigPath`
- `Logging.Directory`
- `Folders[].LocalPath`

**Поле `Folders[].RemotePath` — исключение.** Это путь на WebDAV-сервере,
rclone требует там **прямые слэши**: `"/Backup/Documents"`.

**Относительные пути** в `RcloneConfigPath` и `Logging.Directory`
разрешаются **от папки скрипта** (`$PSScriptRoot`), а не от рабочей папки
процесса.

## Запуск из Планировщика задач

1. Откройте **Планировщик задач** → **Создать задачу**.
2. **Общие**:
   - Имя: `Backup-ToCloudMailRu`
   - «Выполнять только при входе пользователя в систему»
   - Пользователь — тот же, что сохранил пароль в Credential Manager
   - «Выполнять с наивысшими правами» — если нужен доступ к защищённым папкам
3. **Триггеры** — добавьте расписание (например, ежедневно в 03:00).
4. **Действия** → **Создать**:
   - Программа: `pwsh.exe`
   - Аргументы:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\Backup-ToCloudMailRu\Backup-ToCloudMailRu.ps1"
     ```
   - Рабочая папка: `C:\Scripts\Backup-ToCloudMailRu`
5. **Параметры**:
   - «Не запускать новую задачу, если предыдущая ещё выполняется» —
     дополнительная страховка поверх lock-файла.
   - «Остановить задачу, если она выполняется дольше» — по желанию.

## Коды выхода

| Код | Значение |
|---|---|
| `0` | Успех — все включённые папки синхронизированы |
| `1` | Критическая ошибка: конфиг, rclone, remote, учётные данные |
| `2` | Частичный сбой или превышение лимита размера файла |
| `3` | Скрипт уже запущен (сработал lock-файл) |

## Логи

В папке `logs/` ведутся два типа логов, оба — по одному файлу на сутки.

### Основной лог `backup_YYYYMMDD.log`

- Полный ход выполнения: шапка запуска, список папок, вывод rclone,
  ошибки, итоговый статус.
- Кодировка UTF-8 без BOM.
- Уровни: `INFO`, `WARNING`, `ERROR`.
- Буферизация: сброс для `WARNING`/`ERROR` — немедленно, для `INFO` —
  каждые 50 строк и при завершении скрипта.

### Лог неудачных файлов `failed_YYYYMMDD.log`

- Только неудачные файлы.
- Формат строки:
  ```
  [YYYY-MM-DD HH:MM:SS] [LocalPath -> remote:RemotePath] file : сообщение
  ```
- `AutoFlush = $true` — записи сразу пишутся на диск.
- Служебные маркеры `<общая ошибка>`, `<папка>`, `<исключение>` — когда
  конкретный файл не назван.
- Повторные попытки могут дать дубликаты строк по одному файлу.

### Ротация

Файлы обоих типов старше `RetentionDays` (по умолчанию 30) удаляются при
следующем запуске.

## Безопасность

- Пароль конфигурации rclone хранится в **Windows Credential Manager**,
  зашифрован DPAPI и привязан к пользователю и машине.
- Через переменную окружения `RCLONE_CONFIG_PASS` пароль передаётся
  процессу rclone; переменная очищается в `finally`.
- Пароль remote (Mail.ru) хранится внутри `secrets/rclone.conf`, который
  зашифрован паролем конфигурации rclone.
- Трафик к Cloud@mail.ru идёт по HTTPS.
- Lock-файл использует `FileOptions::DeleteOnClose` — ОС удаляет его
  автоматически при завершении процесса.
- Папка `secrets/` исключена из git.

## Перенос между машинами

`secrets/rclone.conf` **можно** копировать между машинами — он защищён
паролем конфигурации.

Пароль конфигурации в Credential Manager перенести **нельзя**: он
зашифрован DPAPI и привязан к пользователю и машине. На новой машине
нужно заново выполнить шаг 5 разовой настройки:

```powershell
Import-Module TUN.CredentialManager
$cred = Get-Credential -Message "Пароль конфигурации rclone" -UserName "rclone"
New-StoredCredential -Target "rclone-config-pass" -Credential $cred -Persist LocalMachine
```

Используйте **тот же** пароль, что и на исходной машине.

Кэш хэшей (`%LOCALAPPDATA%\rclone\kv\*.bolt`) переносить **не нужно** —
на новой машине он заполнится при первом запуске автоматически.

## Известные ограничения

- **Лимит 2 ГБ на файл** на бесплатном тарифе Cloud@mail.ru. Файлы больше
  лимита логируются как `WARNING` и пропускаются.
- **Первый запуск долгий.** rclone перечитывает все локальные файлы, чтобы
  заполнить кэш хэшей. На больших папках (десятки тысяч файлов) это может
  занять часы. Последующие запуски проходят значительно быстрее.
- **Временные метки.** Флаг `--checksum` в `ExtraFlags` заставляет rclone
  сравнивать файлы по хэшу, а не по размеру и mtime. Это решает проблему
  с WebDAV, который может не сохранять mtime при загрузке.
- **Нет теневого копирования (VSS).** Файлы, открытые другими приложениями,
  могут копироваться в несогласованном состоянии.
- **Одна копия у одного провайдера.** Не соответствует правилу 3-2-1.
- **Данные в облаке не шифруются на клиенте.** HTTPS защищает канал, но не
  сервер. При необходимости используйте `crypt`-remote rclone.
- **Нет уведомлений о сбоях.** Результат доступен через логи и код выхода.
- **Дубликаты в failed-логе при повторных попытках.** Один и тот же файл
  может появляться несколько раз.

## Лицензия и авторство

Скрипт создан для личного использования. Адаптируйте под свои задачи.