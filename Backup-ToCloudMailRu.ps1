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
      - логирование через единый StreamWriter с ручным управлением буфером.

    Требования:
      - PowerShell 7+
      - rclone, настроенный remote для Cloud@mail.ru (тип mailru или webdav)
      - Конфигурация rclone зашифрована паролем
      - Модуль CredentialManager (Install-Module CredentialManager -Scope CurrentUser)
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
# 0. Логирование через StreamWriter
# ============================================================
$script:LogWriter        = $null
$script:LogWriteCount    = 0
$script:LogFlushInterval = 50

# Раздельный лог неудачных файлов
$script:FailedLogWriter  = $null
$script:FailedLogPath    = $null
$script:FailedFileCount  = 0

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

function Open-LogWriter {
    param([Parameter(Mandatory)][string]$Path)
    $script:LogWriter = [System.IO.StreamWriter]::new(
        $Path,
        $true,
        [System.Text.UTF8Encoding]::new($false)
    )
    $script:LogWriter.AutoFlush = $false
    $script:LogWriteCount = 0
}

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

# Открывает раздельный лог неудачных файлов.
# AutoFlush = $true: записи сразу на диск — неудач обычно мало,
# а потерять их при аварии не хотелось бы.
function Open-FailedLogWriter {
    param([Parameter(Mandatory)][string]$Path)
    $script:FailedLogWriter = [System.IO.StreamWriter]::new(
        $Path,
        $true,
        [System.Text.UTF8Encoding]::new($false)
    )
    $script:FailedLogWriter.AutoFlush = $true
    $script:FailedLogPath = $Path
}

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
# 1. Блокировка параллельных запусков (lock-файл)
# ============================================================
$lockFilePath = Join-Path $PSScriptRoot "rclone-backup.lock"
$lockStream   = $null

try {
    $lockStream = [System.IO.File]::Open(
        $lockFilePath,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None,
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

    try {
        $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
        $config = $rawConfig | ConvertFrom-Json -Depth 20
    } catch {
        Write-Host "Не удалось разобрать конфигурацию '$ConfigPath': $_" -ForegroundColor Red
        exit 1
    }

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

    $rclonePath = [string]$config.RclonePath
    if (-not (Test-Path -LiteralPath $rclonePath)) {
        Write-Host "rclone.exe не найден по пути: $rclonePath" -ForegroundColor Red
        exit 1
    }

    $rcloneConfigPath = [string]$config.RcloneConfigPath
    $remoteName       = [string]$config.RemoteName
    $credentialTarget = [string]$config.CredentialTarget

    $transferMode = if ($config.PSObject.Properties.Name.Contains('TransferMode')) { [string]$config.TransferMode } else { 'copy' }
    if ($transferMode -notin @('copy','sync')) {
        Write-Host "Недопустимое значение TransferMode: '$transferMode'. Допустимо: copy, sync." -ForegroundColor Red
        exit 1
    }

    $extraFlags = @()
    if ($config.PSObject.Properties.Name.Contains('ExtraFlags') -and $config.ExtraFlags) {
        $extraFlags = @($config.ExtraFlags)
    }

    $maxFileSizeBytes = 2147483648
    if ($config.PSObject.Properties.Name.Contains('MaxFileSizeBytes') -and [int]$config.MaxFileSizeBytes -gt 0) {
        $maxFileSizeBytes = [int]$config.MaxFileSizeBytes
    }

    # --------------------------------------------------------
    # 3. Инициализация лог-файлов
    # --------------------------------------------------------
    $logDir = [string]$config.Logging.Directory
    if ([string]::IsNullOrWhiteSpace($logDir)) { $logDir = 'logs' }
    if (-not [System.IO.Path]::IsPathRooted($logDir)) {
        $logDir = Join-Path $PSScriptRoot $logDir
    }

    if (-not (Test-Path -LiteralPath $logDir)) {
        try {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        } catch {
            Write-Host "Не удалось создать папку логов '$logDir': $_" -ForegroundColor Red
            exit 1
        }
    }

    $logFilePath       = Join-Path $logDir ("backup_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    $failedLogFilePath = Join-Path $logDir ("failed_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    try {
        Open-LogWriter -Path $logFilePath
        Open-FailedLogWriter -Path $failedLogFilePath
    } catch {
        Write-Host "Не удалось открыть лог-файлы: $_" -ForegroundColor Red
        exit 1
    }

    $retention = $LogRetentionDays
    if ($config.Logging.PSObject.Properties.Name.Contains('RetentionDays')) {
        $cfgRetention = $config.Logging.RetentionDays
        if ($null -ne $cfgRetention -and [int]$cfgRetention -gt 0) {
            $retention = [int]$cfgRetention
        }
    }

    # Ротация: удаляем старые backup_*.log и failed_*.log
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

    Write-Log "=== Запуск резервного копирования (rclone) ==="
    Write-Log "Конфигурация: $ConfigPath"
    Write-Log "rclone: $rclonePath"
    Write-Log "Remote: $remoteName"
    Write-Log "Режим: $transferMode"
    Write-Log "WhatIf: $($WhatIfPreference)"
    Write-Log "Лимит размера файла: $([math]::Round($maxFileSizeBytes / 1GB, 2)) ГБ"
    Write-Log "Срок хранения логов: $retention дн."
    Write-Log "Основной лог: $(Split-Path -Leaf $logFilePath)"
    Write-Log "Лог неудачных файлов: $(Split-Path -Leaf $failedLogFilePath)"

    # --------------------------------------------------------
    # 4. Пароль конфигурации rclone из Credential Manager
    # --------------------------------------------------------
    if (-not (Get-Module -ListAvailable -Name CredentialManager)) {
        Write-Log "Модуль CredentialManager не найден. Установите: Install-Module CredentialManager -Scope CurrentUser" -Level ERROR
        exit 1
    }
    Import-Module CredentialManager -ErrorAction Stop

    try {
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
    # 6. Вспомогательная функция вызова rclone
    # --------------------------------------------------------
    function Invoke-Rclone {
        param(
            [Parameter(Mandatory)][string[]]$Arguments,
            [Parameter(Mandatory)][string]$FolderDisplay
        )

        $baseArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($rcloneConfigPath)) {
            $baseArgs += @('--config', $rcloneConfigPath)
        }
        $baseArgs += @('--log-level', 'INFO', '--stats-one-line')

        $allArgs = $baseArgs + $Arguments
        $cmdLine = "rclone " + ($allArgs -join ' ')

        if (-not $PSCmdlet.ShouldProcess($cmdLine, 'Выполнить rclone')) {
            Write-Log "  [WhatIf] $cmdLine"
            return 0
        }

        Write-Log $cmdLine

        try {
            $output = & $rclonePath @allArgs 2>&1
            $exitCode = $LASTEXITCODE

            $foundErrors = 0
            foreach ($line in $output) {
                if (-not $line) { continue }
                Write-Log "  rclone: $line"

                # Строки вида: 2024/01/01 12:00:00 ERROR : path/to/file: сообщение
                if ($line -match '^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} ERROR\s*:\s*(.+?):\s*(.+)$') {
                    $failedFile = $Matches[1].Trim()
                    $failedMsg  = $Matches[2].Trim()
                    Write-FailedFile -FolderDisplay $FolderDisplay -File $failedFile -Message $failedMsg
                    $foundErrors++
                    $script:FailedFileCount++
                }
            }

            # rclone упал с ненулевым кодом, но конкретных файлов в выводе нет.
            # Записываем общую ошибку, чтобы факт сбоя не потерялся.
            if ($exitCode -ne 0 -and $foundErrors -eq 0) {
                Write-FailedFile -FolderDisplay $FolderDisplay -File '<общая ошибка>' `
                    -Message "rclone завершился с кодом $exitCode"
                $script:FailedFileCount++
            }

            return $exitCode
        } catch {
            Write-Log "Ошибка запуска rclone: $_" -Level ERROR
            Write-FailedFile -FolderDisplay $FolderDisplay -File '<исключение>' `
                -Message "Ошибка запуска процесса rclone: $_"
            $script:FailedFileCount++
            return 1
        }
    }

    # --------------------------------------------------------
    # 7. Основной цикл
    # --------------------------------------------------------
    $totalFolders   = @($config.Folders | Where-Object { $_.Enabled -ne $false }).Count
    $processed      = 0
    $failed         = @()
    $oversizedTotal = 0

    foreach ($folder in $config.Folders) {

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

        if (-not (Test-Path -LiteralPath $localPath -PathType Container)) {
            Write-Log "Локальная папка не существует или не является папкой: $localPath" -Level ERROR
            Write-FailedFile -FolderDisplay $folderDisplay -File '<папка>' `
                -Message "Локальная папка не найдена или не является каталогом"
            $script:FailedFileCount++
            $failed += $localPath
            continue
        }

        # --- Предварительная проверка файлов, превышающих лимит облака ---
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

        # --- Формируем аргументы rclone ---
        $rcloneArgs = @($transferMode, $localPath, "${remoteName}:$remotePath")

        if (-not [string]::IsNullOrWhiteSpace($excludeMask)) {
            foreach ($mask in ($excludeMask -split ';')) {
                $trimmed = $mask.Trim()
                if ($trimmed) { $rcloneArgs += @('--exclude', $trimmed) }
            }
        }

        if ($extraFlags.Count -gt 0) {
            $rcloneArgs += $extraFlags
        }

        # --- Цикл повторных попыток для текущей папки ---
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

        if (-not $folderSuccess) {
            Write-Log "Папка не синхронизирована после $maxRetries попыток: $localPath" -Level ERROR
            $failed += $localPath
        }
    }

    # --------------------------------------------------------
    # 8. Итог
    # --------------------------------------------------------
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
    $env:RCLONE_CONFIG_PASS = $null
    Close-LogWriter
    Close-FailedLogWriter

    if ($null -ne $lockStream) {
        try { $lockStream.Close(); $lockStream.Dispose() } catch { }
        $lockStream = $null
    }
}