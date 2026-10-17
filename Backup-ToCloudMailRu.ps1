<#
.SYNOPSIS
    Автоматическое резервное копирование набора локальных папок
    в облако Cloud@mail.ru через rclone.

.DESCRIPTION
    Скрипт читает конфигурацию из JSON-файла, для каждой папки вызывает rclone
    с командой copy или sync. Поддерживает:
      - блокировку параллельных запусков через lock-файл (DeleteOnClose);
      - чтение пароля конфигурации rclone из Windows Credential Manager
        и передачу его через переменную окружения RCLONE_CONFIG_PASS;
      - проверку файлов, превышающих лимит облака;
      - раздельный лог неудачных файлов (failed_YYYYMMDD.log);
      - режим -WhatIf для безопасной проверки без реальных операций;
      - логирование через единый StreamWriter с ручным управлением буфером;
      - потоковый вывод rclone: строки попадают в лог по мере поступления;
      - корректное декодирование вывода rclone в UTF-8;
      - кэш хэшей локальных файлов через hasher-remote, что ускоряет
        повторные запуски (rclone не перечитывает неизменённые файлы);
      - восстановление целостности лог-файла после аварийного завершения
        (незавершённая последняя строка не слипается с новой записью).

    СХЕМА ИСТОЧНИКОВ:
      Источник — локальный путь, переданный rclone через hasher-remote
      "local-hasher". Имя зашито в коде и должно совпадать с секцией
      [local-hasher] в rclone.conf.
      Получатель — remote из поля RemoteName (как правило, "mailru").

    Требования:
      - PowerShell 7+
      - rclone с настроенным remote mailru (тип mailru)
      - Hasher-remote в rclone.conf:
          [local-hasher] — обёртка над локальной ФС (remote =)
        Параметры: hashes = mailru, max_age = off.
        Без этого кэш хешей работать не будет, и каждый запуск будет
        пересчитывать хеши локальных файлов заново.
      - Конфигурация rclone зашифрована паролем
      - Модуль TUN.CredentialManager
        (Install-Module TUN.CredentialManager -Scope CurrentUser)
      - Пароль конфигурации rclone сохранён в Credential Manager
        под именем, указанным в поле CredentialTarget

.PARAMETER ConfigPath
    Путь к JSON-файлу конфигурации. По умолчанию: "$PSScriptRoot\backup.config.json".

.PARAMETER LogRetentionDays
    Сколько дней хранить лог-файлы. По умолчанию 30. 0 — не удалять.

.PARAMETER WhatIf
    Показать, какие операции были бы выполнены, без реального запуска rclone.

.NOTES
    ОСОБЕННОСТЬ JSON: в JSON обратный слэш — служебный символ и экранируется
    удвоением. В полях RclonePath, RcloneConfigPath, Logging.Directory и
    Folders[].LocalPath пишите двойные бэкслэши: "C:\\Folder\\Sub".
    Пути к WebDAV (Folders[].RemotePath) остаются с прямыми слэшами: "/Backup/X".

    ИМЯ HASHER-REMOTE: "local-hasher" жёстко зашито в блоке 7. Если в
    rclone.conf секция называется иначе — поправьте переменную
    $localHasherRemote в блоке 2 или переименуйте секцию в rclone.conf.

    Коды выхода:
      0 — успех;
      1 — критическая ошибка (конфиг, rclone, remote, учётные данные);
      2 — частичный сбой или превышение лимита размера файла;
      3 — скрипт уже запущен (блокировка).
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "backup.config.json"),

    [ValidateRange(0, 3650)]
    [int]$LogRetentionDays = 30
)

$ErrorActionPreference = 'Stop'

# ============================================================
# 0. Логирование
# ============================================================
$script:LogWriter        = $null
$script:LogWriteCount    = 0
$script:LogFlushInterval = 50

$script:FailedLogWriter  = $null
$script:FailedLogPath    = $null
$script:FailedFileCount  = 0

# Пишет строку в консоль и в основной лог.
# Сбрасывает буфер на диск для WARNING/ERROR сразу, для INFO — периодически.
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARNING','ERROR')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARNING' { Write-Host $line -ForegroundColor Yellow }
        default   { Write-Host $line }
    }

    if ($null -ne $script:LogWriter) {
        try {
            $script:LogWriter.WriteLine($line)
            $script:LogWriteCount++
            if ($Level -ne 'INFO' -or ($script:LogWriteCount % $script:LogFlushInterval) -eq 0) {
                $script:LogWriter.Flush()
            }
        } catch { }
    }
}

# Проверяет, заканчивается ли файл переводом строки, и при необходимости
# дописывает его. Нужно после аварийного завершения, когда последняя
# запись могла остаться недописанной — иначе следующая запись приклеится
# к обрывку.
function Ensure-TrailingNewline {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }

    try {
        $fi = [System.IO.FileInfo]::new($Path)
        if ($fi.Length -eq 0) { return }

        $fs = [System.IO.File]::OpenRead($Path)
        try {
            [void]$fs.Seek(-1, [System.IO.SeekOrigin]::End)
            $lastByte = $fs.ReadByte()
        } finally {
            $fs.Dispose()
        }

        # 10 = LF (последний байт последовательности CR LF)
        if ($lastByte -ne 10) {
            [System.IO.File]::AppendAllText($Path, [Environment]::NewLine)
        }
    } catch {
        # Если файл нельзя прочитать — не мешаем открытию на запись.
        # StreamWriter справится или выдаст свою ошибку.
    }
}

# Открывает основной лог: append, UTF-8 без BOM, буферизация вручную.
function Open-LogWriter {
    param([Parameter(Mandatory)][string]$Path)
    Ensure-TrailingNewline -Path $Path
    $script:LogWriter = [System.IO.StreamWriter]::new(
        $Path,
        $true,
        [System.Text.UTF8Encoding]::new($false)
    )
    $script:LogWriter.AutoFlush = $false
    $script:LogWriteCount = 0
}

# Сбрасывает буфер и закрывает основной лог.
function Close-LogWriter {
    if ($null -ne $script:LogWriter) {
        try {
            $script:LogWriter.Flush()
            $script:LogWriter.Close()
            $script:LogWriter.Dispose()
        } catch { }
        $script:LogWriter = $null
    }
}

# Открывает раздельный лог неудачных файлов: append, UTF-8 без BOM, AutoFlush.
function Open-FailedLogWriter {
    param([Parameter(Mandatory)][string]$Path)
    Ensure-TrailingNewline -Path $Path
    $script:FailedLogWriter = [System.IO.StreamWriter]::new(
        $Path,
        $true,
        [System.Text.UTF8Encoding]::new($false)
    )
    $script:FailedLogWriter.AutoFlush = $true
    $script:FailedLogPath = $Path
}

# Закрывает раздельный лог неудачных файлов.
function Close-FailedLogWriter {
    if ($null -ne $script:FailedLogWriter) {
        try {
            $script:FailedLogWriter.Flush()
            $script:FailedLogWriter.Close()
            $script:FailedLogWriter.Dispose()
        } catch { }
        $script:FailedLogWriter = $null
    }
}

# Записывает одну строку в раздельный лог неудачных файлов.
# Формат: [timestamp] [FolderDisplay] File : Message
function Write-FailedFile {
    param(
        [Parameter(Mandatory)][string]$FolderDisplay,
        [Parameter(Mandatory)][string]$File,
        [Parameter(Mandatory)][string]$Message
    )
    if ($null -eq $script:FailedLogWriter) { return }
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$FolderDisplay] $File : $Message"
    try {
        $script:FailedLogWriter.WriteLine($line)
    } catch { }
}

# ============================================================
# 1. Блокировка параллельных запусков
# ============================================================
# Файл-маркер с эксклюзивным доступом. ОС удаляет его при завершении
# процесса (включая аварийное). Если файл занят — скрипт уже запущен.
$lockFilePath = Join-Path $PSScriptRoot "rclone-backup.lock"
$lockStream   = $null

try {
    $lockStream = [System.IO.FileStream]::new(
        $lockFilePath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::DeleteOnClose
    )
    Write-Host "Lock-файл захвачен: $lockFilePath"
} catch [System.IO.IOException] {
    Write-Host "Скрипт уже выполняется (lock-файл занят): $lockFilePath" -ForegroundColor Yellow
    exit 3
} catch {
    Write-Host "Не удалось создать lock-файл: $_" -ForegroundColor Red
    exit 1
}

# ============================================================
# Основной блок
# ============================================================
try {

    # --------------------------------------------------------
    # 2. Загрузка и валидация конфигурации
    # --------------------------------------------------------
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host "Файл конфигурации не найден: $ConfigPath" -ForegroundColor Red
        exit 1
    }

    # Читаем JSON и превращаем в объект
    try {
        $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $config = $rawConfig | ConvertFrom-Json -Depth 20
    } catch {
        Write-Host "Не удалось разобрать конфигурацию '$ConfigPath': $_" -ForegroundColor Red
        exit 1
    }

    # Проверяем наличие обязательных разделов и хотя бы одной папки
    foreach ($required in 'RclonePath','RemoteName','Folders','Retry','Logging','CredentialTarget') {
        if (-not $config.PSObject.Properties.Name.Contains($required)) {
            Write-Host "В конфигурации отсутствует обязательный раздел: $required" -ForegroundColor Red
            exit 1
        }
    }
    if (-not $config.Folders -or @($config.Folders).Count -eq 0) {
        Write-Host "В конфигурации не описано ни одной папки." -ForegroundColor Red
        exit 1
    }

    # Путь к rclone.exe
    $rclonePath = [string]$config.RclonePath
    if (-not (Test-Path -LiteralPath $rclonePath)) {
        Write-Host "rclone.exe не найден по пути: $rclonePath" -ForegroundColor Red
        exit 1
    }

    # Путь к rclone.conf; относительный разрешаем от папки скрипта
    $rcloneConfigPath = [string]$config.RcloneConfigPath
    if (-not [string]::IsNullOrWhiteSpace($rcloneConfigPath) -and
        -not [System.IO.Path]::IsPathRooted($rcloneConfigPath)) {
        $rcloneConfigPath = Join-Path $PSScriptRoot $rcloneConfigPath
    }

    # Имя remote для облака из конфигурации (обычно "mailru").
    $remoteName       = [string]$config.RemoteName
    $credentialTarget = [string]$config.CredentialTarget

    # Имя hasher-remote для локальной стороны. Жёстко зашито — должно
    # совпадать с секцией [local-hasher] в rclone.conf.
    $localHasherRemote = 'local-hasher'

    # Режим передачи: copy или sync
    $transferMode = if ($config.PSObject.Properties.Name.Contains('TransferMode')) { [string]$config.TransferMode } else { 'copy' }
    if ($transferMode -notin @('copy','sync')) {
        Write-Host "Недопустимое значение TransferMode: '$transferMode'. Допустимо: copy, sync." -ForegroundColor Red
        exit 1
    }

    # Дополнительные флаги rclone из конфига
    $extraFlags = @()
    if ($config.PSObject.Properties.Name.Contains('ExtraFlags') -and $config.ExtraFlags) {
        $extraFlags = @($config.ExtraFlags)
    }

    # Лимит размера файла. Int64, потому что 2 ГБ не помещается в Int32.
    [int64]$maxFileSizeBytes = 2147483648
    if ($config.PSObject.Properties.Name.Contains('MaxFileSizeBytes') -and [int64]$config.MaxFileSizeBytes -gt 0) {
        $maxFileSizeBytes = [int64]$config.MaxFileSizeBytes
    }

    # --------------------------------------------------------
    # 3. Инициализация лог-файлов
    # --------------------------------------------------------
    $logDir = [string]$config.Logging.Directory
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = 'logs' }
    if (-not [System.IO.Path]::IsPathRooted($logDir)) {
        $logDir = Join-Path $PSScriptRoot $logDir
    }

    # Создаём папку логов через .NET API — New-Item учитывает -WhatIf
    # и не создаст папку, из-за чего логирование не сможет открыть файл.
    try {
        [void][System.IO.Directory]::CreateDirectory($logDir)
    } catch {
        Write-Host "Не удалось создать папку логов '$logDir': $_" -ForegroundColor Red
        exit 1
    }

    # Имена логов на текущие сутки
    $logFilePath       = Join-Path $logDir ("backup_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $failedLogFilePath = Join-Path $logDir ("failed_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    try {
        Open-LogWriter -Path $logFilePath
        Open-FailedLogWriter -Path $failedLogFilePath
    } catch {
        Write-Host "Не удалось открыть лог-файлы: $_" -ForegroundColor Red
        exit 1
    }

    # Срок хранения логов: параметр скрипта или значение из конфига
    $retention = $LogRetentionDays
    if ($config.Logging.PSObject.Properties.Name.Contains('RetentionDays')) {
        $cfgRetention = $config.Logging.RetentionDays
        if ($null -ne $cfgRetention -and [int]$cfgRetention -gt 0) {
            $retention = [int]$cfgRetention
        }
    }

    # Удаляем старые логи обоих типов
    if ($retention -gt 0) {
        try {
            $threshold = (Get-Date).Date.AddDays(-$retention)
            Get-ChildItem -LiteralPath $logDir -File |
                Where-Object { $_.Name -like 'backup_*.log' -or $_.Name -like 'failed_*.log' } |
                Where-Object { $_.LastWriteTime -lt $threshold } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        } catch {
            Write-Log "Не удалось удалить старые логи: $_" -Level WARNING
        }
    }

    # Шапка запуска
    Write-Log "=== Запуск резервного копирования (rclone) ==="
    Write-Log "Конфигурация: $ConfigPath"
    Write-Log "rclone: $rclonePath"
    Write-Log "rclone.conf: $rcloneConfigPath"
    Write-Log "Remote (целевой): $remoteName"
    Write-Log "Remote (источник): $localHasherRemote"
    Write-Log "Режим: $transferMode"
    Write-Log "WhatIf: $($WhatIfPreference)"
    Write-Log "Лимит размера файла: $([math]::Round($maxFileSizeBytes / 1GB, 2)) ГБ"
    Write-Log "Срок хранения логов: $retention дн."
    Write-Log "Основной лог: $(Split-Path -Leaf $logFilePath)"
    Write-Log "Лог неудачных файлов: $(Split-Path -Leaf $failedLogFilePath)"

    # --------------------------------------------------------
    # 4. Пароль конфигурации rclone из Credential Manager
    # --------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name TUN.CredentialManager)) {
        Write-Log "Модуль TUN.CredentialManager не найден. Установите: Install-Module TUN.CredentialManager -Scope CurrentUser" -Level ERROR
        exit 1
    }
    Import-Module TUN.CredentialManager -ErrorAction Stop

    try {
        # Забираем пароль конфигурации и кладём в переменную окружения —
        # её унаследует процесс rclone
        $cred = Get-StoredCredential -Target $credentialTarget
        if (-not $cred) {
            throw "Учётные данные с именем '$credentialTarget' не найдены в Windows Credential Manager."
        }
        $env:RCLONE_CONFIG_PASS = $cred.GetNetworkCredential().Password
        Write-Log "Пароль конфигурации rclone загружен из Credential Manager (цель: $credentialTarget)."
    } catch {
        Write-Log "Ошибка получения пароля из Credential Manager: $_" -Level ERROR
        exit 1
    }

    # --------------------------------------------------------
    # 5. Параметры повторных попыток
    # --------------------------------------------------------
    $maxRetries = [int]$config.Retry.MaxRetries
    if ($maxRetries -lt 1) { $maxRetries = 1 }
    $baseDelay  = [int]$config.Retry.BaseDelaySeconds
    if ($baseDelay -lt 1) { $baseDelay = 1 }

    # --------------------------------------------------------
    # 6. Вызов rclone
    # --------------------------------------------------------
    # Запускает rclone и обрабатывает его вывод построчно по мере поступления:
    # строки сразу попадают в лог и консоль, а не собираются в буфер до
    # завершения процесса. Строки ERROR парсятся в failed-лог.
    # На время вызова кодировка консоли переключается в UTF-8.
    function Invoke-Rclone {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [Parameter(Mandatory)][string]$FolderDisplay
        )

        # Базовые аргументы: путь к конфигу и формат лога rclone
        $baseArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($rcloneConfigPath)) {
            $baseArgs += @('--config', $rcloneConfigPath)
        }
        $baseArgs += @('--log-level', 'INFO', '--stats-one-line')

        $allArgs = $baseArgs + $Arguments
        $cmdLine = "rclone " + ($allArgs -join ' ')

        # Режим -WhatIf: не запускаем, только логируем команду
        if (-not $PSCmdlet.ShouldProcess($cmdLine, 'Выполнить rclone')) {
            Write-Log "  [WhatIf] $cmdLine"
            return 0
        }

        Write-Log $cmdLine

        # Аккумулятор в хеш-таблице: изменения внутри ForEach-Object
        # сохраняются между итерациями и доступны после конвейера.
        $state = @{ FoundErrors = 0 }

        # Запоминаем кодировки и переключаемся на UTF-8 на время вызова
        $prevConsoleEncoding = [Console]::OutputEncoding
        $prevOutputEncoding  = $OutputEncoding

        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

            # Потоковая обработка вывода rclone: каждая строка — сразу в лог
            & $rclonePath @allArgs 2>&1 | ForEach-Object {
                $line = $_.ToString()
                if (-not $line) { return }

                Write-Log "  rclone: $line"

                # Строки вида: 2024/01/01 12:00:00 ERROR : path/to/file: сообщение
                if ($line -match '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ERROR\s*:\s*(.+?):\s*(.+)$') {
                    $failedFile = $Matches[1].Trim()
                    $failedMsg  = $Matches[2].Trim()
                    Write-FailedFile -FolderDisplay $FolderDisplay -File $failedFile -Message $failedMsg
                    $state.FoundErrors++
                    $script:FailedFileCount++
                }
            }

            $exitCode = $LASTEXITCODE
        } catch {
            Write-Log "Ошибка запуска rclone: $_" -Level ERROR
            Write-FailedFile -FolderDisplay $FolderDisplay -File '<исключение>' `
                -Message "Ошибка запуска процесса rclone: $_"
            $script:FailedFileCount++
            return 1
        } finally {
            [Console]::OutputEncoding = $prevConsoleEncoding
            $OutputEncoding           = $prevOutputEncoding
        }

        # Ненулевой код без конкретных ошибок в выводе — общая запись
        if ($exitCode -ne 0 -and $state.FoundErrors -eq 0) {
            Write-FailedFile -FolderDisplay $FolderDisplay -File '<общая ошибка>' `
                -Message "rclone завершился с кодом $exitCode"
            $script:FailedFileCount++
        }

        return $exitCode
    }

    # --------------------------------------------------------
    # 7. Основной цикл по папкам
    # --------------------------------------------------------
    $totalFolders   = @($config.Folders | Where-Object { $_.Enabled -ne $false }).Count
    $processed      = 0
    $failed         = @()
    $oversizedTotal = 0

    foreach ($folder in $config.Folders) {

        # Папки с Enabled=false пропускаем
        if ($folder.Enabled -eq $false) {
            Write-Log "Пропущено (Enabled=false): $($folder.LocalPath)"
            continue
        }
        $processed++

        $localPath  = [string]$folder.LocalPath
        $remotePath = [string]$folder.RemotePath

        $excludeMask = ''
        if ($folder.PSObject.Properties.Name.Contains('ExcludeMask')) {
            $excludeMask = [string]$folder.ExcludeMask
        }

        $folderDisplay = "$localPath -> $remoteName`:$remotePath"
        Write-Log "--- Папка $processed/$totalFolders : $folderDisplay ---"

        # Локальной папки нет — фиксируем и идём дальше
        if (-not (Test-Path -LiteralPath $localPath -PathType Container)) {
            Write-Log "Локальная папка не существует или не является папкой: $localPath" -Level ERROR
            Write-FailedFile -FolderDisplay $folderDisplay -File '<папка>' `
                -Message "Локальная папка не найдена или не является каталогом"
            $script:FailedFileCount++
            $failed += $localPath
            continue
        }

        # Проверка файлов, превышающих лимит облака
        try {
            $oversized = Get-ChildItem -LiteralPath $localPath -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt $maxFileSizeBytes }

            if ($oversized) {
                foreach ($f in $oversized) {
                    Write-Log ("  Файл превышает лимит {0:N2} ГБ: {1} ({2:N2} ГБ)" -f `
                        ($maxFileSizeBytes / 1GB), $f.FullName, ($f.Length / 1GB)) -Level WARNING
                }
                $oversizedTotal += @($oversized).Count
            }
        } catch {
            Write-Log "Ошибка при сканировании размеров файлов: $_" -Level WARNING
        }

        # Аргументы rclone: режим, источник, получатель.
        # Источник — локальный путь через hasher-remote (кэш хэшей).
        # Получатель — remote для облака из конфига.
        $localSource = "$localHasherRemote`:$localPath"
        $rcloneArgs = @($transferMode, $localSource, "${remoteName}:$remotePath")

        # Исключения
        if (-not [string]::IsNullOrWhiteSpace($excludeMask)) {
            foreach ($mask in ($excludeMask -split ';')) {
                $trimmed = $mask.Trim()
                if ($trimmed) { $rcloneArgs += @('--exclude', $trimmed) }
            }
        }

        # Дополнительные флаги из конфига
        if ($extraFlags.Count -gt 0) {
            $rcloneArgs += $extraFlags
        }

        # Повторные попытки для текущей папки с экспоненциальной задержкой
        $attempt = 0
        $folderSuccess = $false

        while (-not $folderSuccess -and $attempt -lt $maxRetries) {
            $attempt++
            Write-Log "Попытка $attempt из $maxRetries..."

            $exitCode = Invoke-Rclone -Arguments $rcloneArgs -FolderDisplay $folderDisplay

            if ($exitCode -eq 0) {
                Write-Log "Синхронизация выполнена успешно."
                $folderSuccess = $true
            } else {
                Write-Log "rclone завершился с кодом $exitCode." -Level ERROR
                if ($attempt -lt $maxRetries) {
                    $delay = [Math]::Pow($baseDelay, $attempt)
                    Write-Log "Ожидание $delay с перед следующей попыткой..."
                    Start-Sleep -Seconds $delay
                }
            }
        }

        # Папка не синхронизирована после всех попыток
        if (-not $folderSuccess) {
            Write-Log "Папка не синхронизирована после $maxRetries попыток: $localPath" -Level ERROR
            $failed += $localPath
        }
    }

    # --------------------------------------------------------
    # 8. Итог
    # --------------------------------------------------------
    # Сообщаем про failed-лог, если туда что-то попало
    $failedLogHasData = $false
    if ($script:FailedLogPath -and (Test-Path -LiteralPath $script:FailedLogPath)) {
        try {
            $failedLogHasData = (Get-Item -LiteralPath $script:FailedLogPath).Length -gt 0
        } catch { }
    }

    if ($script:FailedFileCount -gt 0) {
        Write-Log ("Записей в раздельном логе неудачных файлов: {0}. Файл: {1}" -f `
            $script:FailedFileCount, $script:FailedLogPath) -Level WARNING
    }
    elseif ($failedLogHasData) {
        Write-Log "Раздельный лог неудачных файлов: $script:FailedLogPath"
    }

    # Определяем код выхода
    if ($failed.Count -gt 0) {
        Write-Log ("Резервное копирование завершено с ошибками. Не синхронизировано папок: {0}:`n  - {1}" -f `
            $failed.Count, ($failed -join "`n  - ")) -Level ERROR
        exit 2
    }

    if ($oversizedTotal -gt 0) {
        Write-Log ("Обнаружено файлов, превышающих лимит облака: {0}. Они пропущены при загрузке." -f $oversizedTotal) -Level WARNING
        exit 2
    }

    Write-Log "Резервное копирование успешно завершено."
    exit 0

} finally {
    # ============================================================
    # 9. Очистка
    # ============================================================
    # Стираем пароль из переменной окружения, закрываем логи, освобождаем lock
    $env:RCLONE_CONFIG_PASS = $null
    Close-LogWriter
    Close-FailedLogWriter

    if ($null -ne $lockStream) {
        try { $lockStream.Close(); $lockStream.Dispose() } catch { }
        $lockStream = $null
    }
}