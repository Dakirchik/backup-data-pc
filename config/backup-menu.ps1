<#
  Консольное меню резервного копирования. Лежит на самом HDD в папке config и работает с любой буквой диска.
  Что где хранится (на HDD):
    config\backup-menu.ps1 - этот скрипт (запускается через Start.cmd в корне)
    config\devices.json    - список устройств и их настройки
    data\<устройство>\<папка-источник>\ - копии файлов (у устройства может быть несколько источников)
    logs\         - логи запусков robocopy
  Копирование одностороннее: robocopy без /MIR, удалённые в источнике файлы в копии остаются.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = ''
)

$ErrorActionPreference = 'Stop'

# Папка со скриптом. $PSScriptRoot в значении параметра по умолчанию бывает пустым,
# поэтому считаем здесь, с запасными вариантами.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir -and $MyInvocation.MyCommand.Path) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ScriptDir -and $PSCommandPath) { $ScriptDir = Split-Path -Parent $PSCommandPath }
if (-not $ScriptDir) {
    Write-Host 'Не удалось определить папку скрипта. Запускайте его через Start.cmd.' -ForegroundColor Red
    exit 1
}
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'devices.json' }

# Скрипт лежит в <корень>\config, поэтому корень бэкапа - папка выше.
$script:Root    = Split-Path -Parent $ScriptDir
$script:DataDir = Join-Path $script:Root 'data'
$script:LogDir  = Join-Path $script:Root 'logs'
$script:MachineId = ''

# ---------------------------------------------------------------- вспомогательное

function Ask([string]$Prompt) {
    $v = Read-Host $Prompt
    if ($null -eq $v) { return '' }
    return $v.Trim()
}

function Confirm-Action([string]$Question) {
    return ((Ask "$Question (y/n)") -match '^(y|yes|д|да)$')
}

function Pause-Menu {
    Write-Host ''
    [void](Read-Host 'Enter - продолжить')
}

function Write-Title([string]$Text) {
    Clear-Host
    Write-Host "=== $Text ===" -ForegroundColor Cyan
    Write-Host "HDD: $script:Root   |   Компьютер: $env:COMPUTERNAME" -ForegroundColor DarkGray
    Write-Host ''
}

function Get-Devices {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return @() }
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    if (-not $raw -or -not $raw.Trim()) { return @() }
    $cfg = $raw | ConvertFrom-Json
    if ($null -eq $cfg.devices) { return @() }
    return @($cfg.devices)
}

function Save-Devices($Devices) {
    $obj  = [ordered]@{ devices = @($Devices) }
    $json = $obj | ConvertTo-Json -Depth 5
    $cfgDir = Split-Path -Parent $ConfigPath
    if ($cfgDir) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
    $tmp  = "$ConfigPath.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $ConfigPath -Force
}

function Find-Device([string]$Folder) {
    return @(Get-Devices) | Where-Object { $_.folder -eq $Folder } | Select-Object -First 1
}

# Идентификатор Windows (MachineGuid): не меняется при переименовании компьютера.
function Get-MachineId {
    try {
        return [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid).MachineGuid
    } catch {
        return ''
    }
}

# Устройство принадлежит этому компьютеру?
# Сначала сравнивается идентификатор Windows, и только если его нет в записи, имя компьютера.
function Test-ThisPc($Dev) {
    if ($Dev.machineId -and $script:MachineId) {
        return ($Dev.machineId -eq $script:MachineId)
    }
    return ($Dev.computerName -eq $env:COMPUTERNAME)
}

# При запуске: для устройств этого компьютера обновляем имя (если его сменили)
# и дописываем идентификатор (для записей, сделанных раньше).
function Update-PcRecords {
    $list = @(Get-Devices)
    $changed = $false
    foreach ($d in $list) {
        # Старый формат (одно поле source) переводим в список sources.
        if (-not $d.PSObject.Properties['sources'] -and $d.PSObject.Properties['source']) {
            Set-Sources $d @(Get-Sources $d)
            $changed = $true
        }
        if (-not (Test-ThisPc $d)) { continue }
        if ($d.computerName -ne $env:COMPUTERNAME) {
            $d.computerName = $env:COMPUTERNAME
            $changed = $true
        }
        if ($script:MachineId -and -not $d.machineId) {
            $d | Add-Member -NotePropertyName machineId -NotePropertyValue $script:MachineId -Force
            $changed = $true
        }
    }
    if ($changed) { Save-Devices $list }
}

function New-FolderName([string]$Name, $Devices) {
    $base = ($Name -replace '[^\w\-]+', '_').Trim('_')
    if (-not $base) { $base = 'device' }
    $used   = @($Devices | ForEach-Object { $_.folder })
    $folder = $base
    $i = 2
    while (($used -contains $folder) -or (Test-Path -LiteralPath (Join-Path $script:DataDir $folder))) {
        $folder = '{0}_{1}' -f $base, $i
        $i++
    }
    return $folder
}

function Read-ExcludeDirs([string]$Raw) {
    return @($Raw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- папки-источники: у устройства их может быть несколько ----
# В конфиге: sources = [ { path, name } ], где name - имя подпапки копии внутри data\<устройство>\.
# Старый формат (одно поле source) читается и при запуске переводится в новый.

function Get-LeafName([string]$Path) {
    $leaf = Split-Path -Leaf ($Path.TrimEnd('\'))
    $leaf = ($leaf -replace '[\\/:*?"<>|]', '_').Trim()
    if (-not $leaf) { $leaf = 'source' }
    return $leaf
}

function Get-Sources($Dev) {
    $res = @()
    if ($Dev.PSObject.Properties['sources'] -and $Dev.sources) {
        foreach ($s in @($Dev.sources)) {
            if ($s -is [string]) { $res += [pscustomobject]@{ path = $s; name = (Get-LeafName $s) } }
            else { $res += $s }
        }
    } elseif ($Dev.PSObject.Properties['source'] -and $Dev.source) {
        $res += [pscustomobject]@{ path = [string]$Dev.source; name = (Get-LeafName ([string]$Dev.source)) }
    }
    return $res
}

function Set-Sources($Dev, $Sources) {
    $Dev | Add-Member -NotePropertyName sources -NotePropertyValue @($Sources) -Force
    if ($Dev.PSObject.Properties['source']) { $Dev.PSObject.Properties.Remove('source') }
}

function New-SourceName([string]$Path, $Existing) {
    $base = Get-LeafName $Path
    $used = @($Existing | ForEach-Object { $_.name })
    $name = $base
    $i = 2
    while ($used -contains $name) { $name = '{0}_{1}' -f $base, $i; $i++ }
    return $name
}

# Возвращает текст проблемы или $null, если папку можно добавить.
function Test-SourceProblem([string]$Path, $Existing) {
    if (-not $Path) { return 'Путь не указан.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return 'Такой папки нет.' }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full.Length -le 2) { return 'Корень диска использовать нельзя: укажите вложенную папку.' }
    $hdd = $script:Root.TrimEnd('\')
    $cmp = [StringComparison]::OrdinalIgnoreCase
    if ($full -eq $hdd -or $full.StartsWith($hdd + '\', $cmp)) { return 'Эта папка находится на самом HDD с бэкапом.' }
    if ($hdd.StartsWith($full + '\', $cmp)) { return 'Эта папка содержит папку бэкапа на HDD.' }
    foreach ($e in @($Existing)) {
        $ef = [IO.Path]::GetFullPath($e.path).TrimEnd('\')
        if ($full -eq $ef) { return 'Эта папка уже добавлена.' }
        if ($full.StartsWith($ef + '\', $cmp)) { return "Эта папка лежит внутри уже добавленной: $($e.path)." }
        if ($ef.StartsWith($full + '\', $cmp)) { return "Эта папка содержит уже добавленную: $($e.path)." }
    }
    return $null
}

function Show-DeviceList($Devices) {
    for ($i = 0; $i -lt $Devices.Count; $i++) {
        $d = $Devices[$i]
        $note = ''
        if (-not (Test-ThisPc $d)) { $note = "  (другой компьютер: $($d.computerName))" }
        Write-Host ('{0}. {1}{2}' -f ($i + 1), $d.name, $note)
        foreach ($s in @(Get-Sources $d)) { Write-Host ('      источник: {0}' -f $s.path) -ForegroundColor DarkGray }
    }
}

# Возвращает выбранное устройство или $null, если пользователь вернулся назад
function Select-Device($Devices, [string]$Prompt) {
    if ($Devices.Count -eq 0) {
        Write-Host 'Устройств пока нет. Добавьте через пункт "Добавить устройство".' -ForegroundColor Yellow
        Pause-Menu
        return $null
    }
    Show-DeviceList $Devices
    Write-Host '0. Назад'
    Write-Host ''
    $n = 0
    if (-not [int]::TryParse((Ask $Prompt), [ref]$n) -or $n -lt 1 -or $n -gt $Devices.Count) { return $null }
    return $Devices[$n - 1]
}

# ---------------------------------------------------------------- синхронизация

function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N1} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} КБ' -f ($Bytes / 1KB)) }
    return ('{0:N0} Б' -f $Bytes)
}

# Строка файла из вывода robocopy (запуск с /BYTES): поля разделены табуляцией, имя - последнее,
# размер в байтах - предпоследнее. Папки (путь заканчивается на \) и прочие строки возвращают $null.
function Read-RobocopyFileLine([string]$Line) {
    $parts = $Line -split "`t"
    if ($parts.Count -lt 3) { return $null }
    $name = $parts[$parts.Count - 1].Trim()
    if (-not $name -or $name.EndsWith('\')) { return $null }
    $size = [double]0
    $prev = $parts[$parts.Count - 2].Trim()
    if ($prev -match '^\d+$') { $size = [double]$prev }
    return [pscustomobject]@{ Name = $name; Size = $size }
}

function Start-Robocopy([string[]]$RoboArgs) {
    $quoted = @($RoboArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_ + '"' } else { $_ } })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'robocopy.exe'
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.CreateNoWindow = $true
    # Дочерний процесс запускается с собственной скрытой консолью, где вывод идёт в OEM-кодировке
    # (для русской Windows это CP866), а не в UTF-8 из Start.cmd. Читаем в той же кодировке.
    try {
        $oem = [Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage
        $psi.StandardOutputEncoding = [System.Text.Encoding]::GetEncoding($oem)
    } catch { }
    return [System.Diagnostics.Process]::Start($psi)
}

# Строка папки из вывода robocopy: путь заканчивается на \. Возвращает путь или $null.
function Read-RobocopyDirLine([string]$Line) {
    $parts = $Line -split "`t"
    if ($parts.Count -lt 3) { return $null }
    $last = $parts[$parts.Count - 1].Trim()
    if ($last -and $last.EndsWith('\')) { return $last }
    return $null
}

# Полные пути файла: откуда (в источнике) и куда (в копии).
function Get-CopyPaths([string]$Src, [string]$Dst, [string]$CurDir, [string]$Name) {
    $rel = ''
    if ($CurDir -and $CurDir.StartsWith($Src, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $CurDir.Substring($Src.Length).Trim('\')
    }
    if ($CurDir) { $from = Join-Path $CurDir $Name } else { $from = Join-Path $Src $Name }
    if ($rel) { $toDir = Join-Path $Dst $rel } else { $toDir = $Dst }
    return [pscustomobject]@{ From = $from; To = (Join-Path $toDir $Name) }
}

# Пробный проход (/L): robocopy ничего не копирует, а только перечисляет файлы, которые были бы скопированы.
# Нужен, чтобы заранее знать общий объём и отличать новые файлы от обновляемых (до начала копирования).
function Get-RobocopyPlan([string[]]$RoboArgs, [string]$Src, [string]$Dst) {
    $files  = 0
    $bytes  = [double]0
    $status = @{}
    $curDir = ''
    $p = Start-Robocopy (@($RoboArgs) + @('/L', '/BYTES', '/NJH', '/NJS', '/NP'))
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        $dir = Read-RobocopyDirLine $line
        if ($dir) { $curDir = $dir; continue }
        $f = Read-RobocopyFileLine $line
        if ($f) {
            # robocopy может перечислять и файлы, которые не копирует (одинаковые, более новые в копии).
            # Поэтому по-настоящему к копированию относим только отличающиеся: так не зависим от языка вывода.
            $paths = Get-CopyPaths $Src $Dst $curDir $f.Name
            $kind = 'новый'
            try {
                if (Test-Path -LiteralPath $paths.To) {
                    $srcItem = Get-Item -LiteralPath $paths.From -Force
                    $dstItem = Get-Item -LiteralPath $paths.To -Force
                    $diff = ($srcItem.LastWriteTimeUtc - $dstItem.LastWriteTimeUtc).TotalSeconds
                    if (($srcItem.Length -eq $dstItem.Length) -and ([Math]::Abs($diff) -le 2)) { continue }
                    if ($diff -le -2) { continue }
                    $kind = 'обновлён'
                }
            } catch { }
            $files++
            $bytes += $f.Size
            $status[$paths.From.ToLowerInvariant()] = $kind
        }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Files = $files; Bytes = $bytes; Status = $status }
}

function Get-OverallText([double]$DoneBytes, [double]$TotalBytes) {
    $done = [Math]::Min($TotalBytes, $DoneBytes)
    $rem  = [Math]::Max([double]0, $TotalBytes - $done)
    $pct  = 0
    if ($TotalBytes -gt 0) { $pct = [Math]::Floor(100 * $done / $TotalBytes) }
    return ('Скопировано {0} из {1} ({2}%), осталось {3}' -f (Format-Size $done), (Format-Size $TotalBytes), $pct, (Format-Size $rem))
}

function Format-ProgressText([string]$Overall, [string]$Name, [string]$Pct, [int]$Width) {
    $prefix = "$Overall | "
    $suffix = "  $Pct%"
    $avail  = $Width - $prefix.Length - $suffix.Length
    if ($avail -lt 5) { $avail = 5 }
    if ($Name.Length -gt $avail) { $Name = '…' + $Name.Substring($Name.Length - $avail + 1) }
    return $prefix + $Name + $suffix
}

function Show-ProgressLine([string]$Text, [int]$Width) {
    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
    Write-Host -NoNewline ("`r" + $Text.PadRight($Width))
}

function Clear-ProgressLine([int]$Width) {
    Write-Host -NoNewline ("`r" + (' ' * $Width) + "`r")
}

# Файл закончен: фиксируем время. Если по нему была ошибка, но в копии файл оказался целым
# (robocopy повторил попытку удачно), считаем его скопированным.
function Complete-Record($Rec) {
    $Rec.Time = Get-Date
    if ($Rec.Status -eq 'ошибка') {
        try {
            if ((Get-Item -LiteralPath $Rec.To -Force).Length -eq [int64]$Rec.Size) {
                $Rec.Status = 'скопирован со 2-й попытки'
                $Rec.Note = ''
            }
        } catch { }
    }
}

# Запускает robocopy и показывает ОДНУ обновляемую строку: сколько объёма скопировано и сколько осталось,
# имя текущего файла и его процент. Закончившиеся файлы с экрана исчезают.
# В технический лог пишется весь вывод robocopy, кроме строк с процентами.
# Возвращает объект: Code (код robocopy), Records (по записи на файл), Notes (ошибки без привязки к файлу).
# Аргументы должны содержать /BYTES: тогда размеры файлов приходят числом.
function Invoke-RobocopyWithProgress([string[]]$RoboArgs, [string]$LogFile, $Plan, [string]$Src, [string]$Dst) {
    $TotalBytes = [double]$Plan.Bytes
    $w = 79
    try { $w = [Math]::Max(20, [Console]::WindowWidth - 1) } catch { }

    $logWriter = New-Object System.IO.StreamWriter($LogFile, $true, (New-Object System.Text.UTF8Encoding($true)))
    $logWriter.AutoFlush = $true
    $logWriter.WriteLine('=== ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' robocopy ' + ($RoboArgs -join ' '))

    $sw        = [System.Diagnostics.Stopwatch]::StartNew()
    $doneBytes = [double]0
    $curSize   = [double]0
    $name      = ''
    $pct       = '0'
    $dashes    = 0
    $curDir    = ''
    $cur       = $null
    $records   = New-Object System.Collections.Generic.List[object]
    $notes     = New-Object System.Collections.Generic.List[string]
    $summary   = New-Object System.Collections.Generic.List[string]
    $code      = 16

    $p = Start-Robocopy $RoboArgs
    try {
        while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
            # Строка с процентом: только обновляем экран, в лог не пишем.
            if ($line -match '^\s*(\d{1,3})(?:[.,]\d+)?\s*%\s*$') {
                $pct = $Matches[1]
                if ($name -and $sw.ElapsedMilliseconds -ge 100) {
                    $bytesNow = $doneBytes + ($curSize * [double]$pct / 100)
                    $overall  = Get-OverallText $bytesNow $TotalBytes
                    Show-ProgressLine (Format-ProgressText $overall $name $pct $w) $w
                    $sw.Restart()
                }
                continue
            }

            $logWriter.WriteLine($line)

            if ($line -match '^-{20,}\s*$') { $dashes++; continue }
            # После 4-й разделительной линии идёт итоговая таблица robocopy.
            if ($dashes -ge 4) { if ($line.Trim()) { $summary.Add($line) }; continue }

            # Ошибки показываем сразу, красным, отдельной строкой, и привязываем к текущему файлу.
            if ($line -match '(ERROR|Ошибка)\s+\d+\s+\(0x') {
                Clear-ProgressLine $w
                Write-Host $line.Trim() -ForegroundColor Red
                if ($cur) { $cur.Status = 'ошибка'; $cur.Note = $line.Trim() } else { $notes.Add($line.Trim()) }
                continue
            }

            $dir = Read-RobocopyDirLine $line
            if ($dir) { $curDir = $dir; continue }

            $f = Read-RobocopyFileLine $line
            if ($f) {
                # Файлы, которых нет в плане (одинаковые и т.п.), не копируются: пропускаем строку.
                $paths = Get-CopyPaths $Src $Dst $curDir $f.Name
                $kind  = $Plan.Status[$paths.From.ToLowerInvariant()]
                if (-not $kind) { continue }
                # Предыдущий файл закончился.
                if ($cur) { Complete-Record $cur; $doneBytes += $curSize }
                $cur = [pscustomobject]@{
                    Name = $f.Name; From = $paths.From; To = $paths.To; Size = $f.Size
                    Status = $kind; Note = ''; Time = $null
                }
                $records.Add($cur)
                $name    = $f.Name
                $curSize = $f.Size
                $pct     = '0'
                $overall = Get-OverallText $doneBytes $TotalBytes
                Show-ProgressLine (Format-ProgressText $overall $name $pct $w) $w
                $sw.Restart()
            }
        }
        if ($cur) { Complete-Record $cur }
        $p.WaitForExit()
        $code = $p.ExitCode
    } finally {
        Clear-ProgressLine $w
        $logWriter.Dispose()
    }

    # Короткий итог robocopy: заголовок таблицы и строки Dirs / Files / Bytes.
    $n = [Math]::Min(4, $summary.Count)
    for ($i = 0; $i -lt $n; $i++) { Write-Host $summary[$i] -ForegroundColor DarkGray }

    return [pscustomobject]@{ Code = $code; Records = $records.ToArray(); Notes = $notes.ToArray() }
}

# Ищет лишнее в копии: файлы и папки, которые есть на HDD, но которых уже нет в источнике.
# Робокопи в режиме /L перечисляет их вместе с остальным; нужное отбираем сами по наличию файла
# в источнике и в копии, поэтому не зависим от языка вывода. Ничего не удаляется.
function Get-ExtraItems([string[]]$RoboArgs, [string]$Src, [string]$Dst) {
    $dirs   = New-Object System.Collections.Generic.List[string]
    $files  = New-Object System.Collections.Generic.List[object]
    $curDir = ''
    $cmp    = [StringComparison]::OrdinalIgnoreCase
    $dstTrim = $Dst.TrimEnd('\')
    $p = Start-Robocopy $RoboArgs
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        $dir = Read-RobocopyDirLine $line
        if ($dir) {
            if ($dir.StartsWith($dstTrim + '\', $cmp) -and $dir.TrimEnd('\') -ne $dstTrim) {
                # Папка, которая есть только в копии. Вложенные в уже найденную пропускаем.
                $inside = $false
                foreach ($d in $dirs) { if ($dir.StartsWith($d, $cmp)) { $inside = $true; break } }
                if (-not $inside) { $dirs.Add($dir) }
            } else {
                $curDir = $dir
            }
            continue
        }
        $f = Read-RobocopyFileLine $line
        if ($f) {
            $paths = Get-CopyPaths $Src $Dst $curDir $f.Name
            if ((-not [IO.File]::Exists($paths.From)) -and [IO.File]::Exists($paths.To)) {
                $files.Add([pscustomobject]@{ Path = $paths.To; Size = $f.Size })
            }
        }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Dirs = $dirs.ToArray(); Files = $files.ToArray() }
}

# Дописывает в технический лог отдельную главу со списком лишнего в копии (для ручного удаления).
function Add-ExtrasToLog([string]$LogFile, [string]$Src, [string]$Dst, $Extra) {
    $bytes = [double]0
    foreach ($f in $Extra.Files) { $bytes += $f.Size }
    $bar = '#' * 78
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine($bar)
    [void]$sb.AppendLine('ЛИШНЕЕ В КОПИИ: есть на HDD, но нет в источнике. Можно удалить вручную.')
    [void]$sb.AppendLine('Скрипт сам ничего не удаляет.')
    [void]$sb.AppendLine('Источник: ' + $Src)
    [void]$sb.AppendLine('Копия   : ' + $Dst)
    if ($Extra.Dirs.Count -eq 0 -and $Extra.Files.Count -eq 0) {
        [void]$sb.AppendLine('Лишнего нет.')
    } else {
        [void]$sb.AppendLine(('Найдено: папок {0}, файлов {1}, объём файлов {2}' -f $Extra.Dirs.Count, $Extra.Files.Count, (Format-Size $bytes)))
        [void]$sb.AppendLine('-' * 78)
        foreach ($d in ($Extra.Dirs | Sort-Object)) { [void]$sb.AppendLine('[папка] ' + $d) }
        foreach ($f in ($Extra.Files | Sort-Object -Property Path)) {
            [void]$sb.AppendLine(('[файл]  {0}  ({1})' -f $f.Path, (Format-Size $f.Size)))
        }
    }
    [void]$sb.AppendLine($bar)
    # Номер строки, с которой начнётся глава (первая линия из #), чтобы потом открыть файл именно там.
    $startLine = 0
    try { $startLine = [IO.File]::ReadAllLines($LogFile).Length + 2 } catch { }
    [IO.File]::AppendAllText($LogFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $startLine
}

# Открывает файл на нужной строке: сначала VS Code, затем Notepad++, иначе Блокнот (он строку не умеет).
function Open-FileAtLine([string]$Path, [int]$Line) {
    if ($Line -lt 1) { $Line = 1 }
    $code = Get-Command code -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($code) {
        Start-Process -FilePath $code.Source -ArgumentList ('-g "{0}:{1}"' -f $Path, $Line)
        Write-Host "Открыто в VS Code, строка $Line." -ForegroundColor DarkGray
        return
    }
    $npp = @("$env:ProgramFiles\Notepad++\notepad++.exe", "${env:ProgramFiles(x86)}\Notepad++\notepad++.exe") |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    if ($npp) {
        Start-Process -FilePath $npp -ArgumentList ('-n{0} "{1}"' -f $Line, $Path)
        Write-Host "Открыто в Notepad++, строка $Line." -ForegroundColor DarkGray
        return
    }
    Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $Path)
    Write-Host "Открыто в Блокноте. Он не умеет переходить к строке: нажмите Ctrl+G и введите $Line." -ForegroundColor Yellow
}

function Format-Duration([TimeSpan]$Span) {
    if ($Span.TotalHours -ge 1) { return ('{0} ч {1} мин' -f [int][Math]::Floor($Span.TotalHours), $Span.Minutes) }
    if ($Span.TotalMinutes -ge 1) { return ('{0} мин {1} сек' -f [int][Math]::Floor($Span.TotalMinutes), $Span.Seconds) }
    return ('{0} сек' -f [int][Math]::Ceiling($Span.TotalSeconds))
}

# Дописывает в logs\report.txt отчёт об одной синхронизации: шапка с итогами и список файлов.
function Write-SyncReport($Dev, [datetime]$Started, [datetime]$Finished, $Records, $SkippedNotes, $Notes, [int]$Worst, [string]$RunId, [string]$RawLog, [long]$ExtraFiles, [long]$ExtraDirs) {
    $Records     = @($Records)
    $SkippedNotes = @($SkippedNotes)
    $Notes       = @($Notes)
    $failed = @($Records | Where-Object { $_.Status -eq 'ошибка' })
    $copied = @($Records | Where-Object { $_.Status -ne 'ошибка' })
    $bytes  = [double]0
    foreach ($r in $copied) { $bytes += $r.Size }

    $ok = ($Worst -lt 8) -and ($failed.Count -eq 0)
    if ($ok) { $result = 'успех' } else { $result = 'не успех' }

    $inv   = [Globalization.CultureInfo]::InvariantCulture
    $thick = '=' * 78
    $thin  = '-' * 78
    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine($thick)
    [void]$sb.AppendLine(('{0} - синхронизация "{1}"  [#{2}]' -f $Started.ToString('dd.MM.yyyy, HH:mm', $inv), $Dev.name, $RunId))
    [void]$sb.AppendLine(('Длительность: {0} | Файлов: {1} | Объём: {2} | Результат: {3}' -f (Format-Duration ($Finished - $Started)), $copied.Count, (Format-Size $bytes), $result))
    if ($RawLog) { [void]$sb.AppendLine('Технический лог: raw\' + (Split-Path -Leaf $RawLog)) }
    if ($failed.Count -gt 0 -or $SkippedNotes.Count -gt 0 -or $Notes.Count -gt 0) {
        [void]$sb.AppendLine(('Ошибок: {0} | Пропущено папок-источников: {1}' -f ($failed.Count + $Notes.Count), $SkippedNotes.Count))
    }
    foreach ($n in $SkippedNotes) { [void]$sb.AppendLine('Пропущено: ' + $n) }
    foreach ($n in $Notes) { [void]$sb.AppendLine('Ошибка: ' + $n) }
    if ($ExtraFiles -gt 0 -or $ExtraDirs -gt 0) {
        [void]$sb.AppendLine(('Лишнее в копии (можно удалить вручную): папок {0}, файлов {1} - список в техническом логе' -f $ExtraDirs, $ExtraFiles))
    }

    # Список скопированных файлов в отчёт не пишем: только файлы с ошибками.
    if ($failed.Count -gt 0) {
        [void]$sb.AppendLine($thin)
        [void]$sb.AppendLine('Файлы с ошибками:')
        foreach ($r in $failed) {
            [void]$sb.AppendLine('  ' + $r.From)
            if ($r.Note) { [void]$sb.AppendLine('    ' + $r.Note) }
        }
    } elseif ($Records.Count -eq 0) {
        [void]$sb.AppendLine($thin)
        [void]$sb.AppendLine('Копировать было нечего: копия уже актуальна.')
    }
    [void]$sb.AppendLine($thick)
    [void]$sb.AppendLine('')

    New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    $path = Join-Path $script:LogDir 'report.txt'
    [IO.File]::AppendAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Invoke-Sync($Dev) {
    Write-Title "Синхронизация: $($Dev.name)"

    if (-not (Test-ThisPc $Dev)) {
        Write-Host "Устройство привязано к компьютеру '$($Dev.computerName)', а вы сейчас на '$env:COMPUTERNAME'." -ForegroundColor Red
        Write-Host 'Синхронизация остановлена. Если это тот же компьютер (например, переустановили Windows),'
        Write-Host 'откройте настройки устройства и выберите "Привязать к этому компьютеру".'
        Pause-Menu; return
    }
    $sources = @(Get-Sources $Dev)
    if ($sources.Count -eq 0) {
        Write-Host 'У устройства нет папок-источников. Добавьте их в настройках.' -ForegroundColor Red
        Pause-Menu; return
    }

    $hdd     = $script:Root.TrimEnd('\')
    $devRoot = Join-Path $script:DataDir $Dev.folder
    $cmp     = [StringComparison]::OrdinalIgnoreCase
    $jobs    = @()
    $skipped = 0
    $skippedNotes = @()

    # Проверяем каждую папку отдельно: проблемную пропускаем, остальные копируем.
    foreach ($s in $sources) {
        $problem = $null
        $src = $null
        $dst = $null
        if (-not (Test-Path -LiteralPath $s.path -PathType Container)) {
            $problem = 'папка не найдена'
        } else {
            $src = [IO.Path]::GetFullPath($s.path).TrimEnd('\')
            $dst = [IO.Path]::GetFullPath((Join-Path $devRoot $s.name)).TrimEnd('\')
            if ($src.Length -le 2) {
                $problem = 'корень диска использовать нельзя'
            } elseif (($src -eq $dst) -or $dst.StartsWith($src + '\', $cmp)) {
                $problem = 'папка копии лежит внутри источника'
            } elseif ($src.StartsWith($hdd + '\', $cmp)) {
                $problem = 'источник находится на самом HDD с бэкапом'
            } elseif (-not (Get-ChildItem -LiteralPath $src -Force | Select-Object -First 1)) {
                $problem = 'папка пуста (возможно, Яндекс Диск ещё не докачал файлы)'
            }
        }
        if ($problem) {
            Write-Host "ПРОПУЩЕНО: $($s.path) - $problem" -ForegroundColor Red
            $skipped++
            $skippedNotes += "$($s.path) - $problem"
        } else {
            $jobs += [pscustomobject]@{ Src = $src; Dst = $dst }
        }
    }

    if ($jobs.Count -eq 0) {
        Write-Host ''
        Write-Host 'Нечего копировать: все папки пропущены. Ничего не сделано.' -ForegroundColor Red
        Pause-Menu; return
    }

    Write-Host ''
    foreach ($j in $jobs) {
        Write-Host "Откуда : $($j.Src)"
        Write-Host "Куда   : $($j.Dst)"
        Write-Host ''
    }
    Write-Host '1. Копировать'
    Write-Host '2. Пробный запуск (показать, что будет скопировано, ничего не копируя)'
    Write-Host '0. Отмена'
    $mode = Ask 'Выбор'
    if ($mode -ne '1' -and $mode -ne '2') { return }
    $dry = ($mode -eq '2')

    # Технические логи robocopy лежат в logs\raw, а читаемый отчёт - в logs\report.txt.
    $rawDir = Join-Path $script:LogDir 'raw'
    New-Item -ItemType Directory -Force -Path $rawDir | Out-Null
    # Идентификатор запуска: одинаковый в отчёте, в имени технического лога и внутри него.
    $runId = ('{0:x6}' -f (Get-Random -Maximum 16777216))
    $log = Join-Path $rawDir ('{0}_{1}_{2}.log' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'), $Dev.folder, $runId)
    [IO.File]::WriteAllText($log, ("### Запуск #{0} | {1} | устройство: {2} | компьютер: {3}`r`n" -f $runId, (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'), $Dev.name, $env:COMPUTERNAME), (New-Object System.Text.UTF8Encoding($true)))
    # Служебную папку Яндекс Диска .sync исключаем всегда: это его рабочая база, в бэкапе она не нужна.
    $ex = @(@($Dev.excludeDirs) + '.sync') | Where-Object { $_ } | Select-Object -Unique

    $worst      = 0
    $started    = Get-Date
    $allRecords = New-Object System.Collections.Generic.List[object]
    $allNotes   = New-Object System.Collections.Generic.List[string]
    $extraFiles = 0
    $extraDirs  = 0
    $extraLine  = 0
    foreach ($j in $jobs) {
        Write-Host ''
        Write-Host "--- $($j.Src) ---" -ForegroundColor Cyan
        if (-not $dry) { New-Item -ItemType Directory -Force -Path $j.Dst | Out-Null }

        # /E - с подпапками, /XO - не перезаписывать более новые файлы в копии.
        # /XA:O - пропускать файлы с атрибутом Offline (лежат только в облаке, не скачаны на диск).
        # /R:1 /W:2 - если файл занят (например, Яндекс Диск его ещё качает), одна повторная попытка и дальше.
        # Нет /MIR и /PURGE: ничего не удаляется из копии. Пропущенное скопируется при следующем запуске.
        # Вывод и лог ведёт Invoke-RobocopyWithProgress, поэтому /NP, /TEE и /UNILOG здесь не нужны.
        # /BYTES - размеры файлов в байтах (нужно для подсчёта прогресса).
        # /XX - не перечислять лишние файлы, которые есть в копии, но уже нет в источнике (их мы не трогаем).
        $roboArgs = @($j.Src, $j.Dst, '/E', '/XO', '/XX', '/XA:O', '/R:1', '/W:2', '/BYTES')
        if ($ex) { $roboArgs += '/XD'; $roboArgs += @($ex) }
        if ($dry) { $roboArgs += '/L' }

        # Заранее считаем, сколько файлов и байт предстоит скопировать.
        Write-Host -NoNewline 'Подсчёт объёма...'
        $plan = Get-RobocopyPlan $roboArgs $j.Src $j.Dst
        Write-Host -NoNewline ("`r" + (' ' * 30) + "`r")
        if ($plan.Files -eq 0) {
            Write-Host 'Нечего копировать: копия уже актуальна.' -ForegroundColor Green
        } else {
            Write-Host ('К копированию: {0}' -f (Format-Size $plan.Bytes))

            $res  = Invoke-RobocopyWithProgress $roboArgs $log $plan $j.Src $j.Dst
            $code = $res.Code
            foreach ($r in $res.Records) { $allRecords.Add($r) }
            foreach ($n in $res.Notes) { $allNotes.Add($n) }
            if ($code -gt $worst) { $worst = $code }
            if ($code -ge 8) { Write-Host "Эта папка завершена С ОШИБКАМИ (код $code)." -ForegroundColor Red }
        }

        # Ищем лишнее в копии (есть на HDD, нет в источнике): только список в техническом логе, ничего не удаляется.
        Write-Host -NoNewline 'Поиск лишнего в копии...'
        $extraArgs = @($j.Src, $j.Dst, '/E', '/L', '/BYTES', '/NJH', '/NJS', '/NP', '/R:0', '/W:0')
        if ($ex) { $extraArgs += '/XD'; $extraArgs += @($ex) }
        try {
            $extra = Get-ExtraItems $extraArgs $j.Src $j.Dst
            Write-Host -NoNewline ("`r" + (' ' * 40) + "`r")
            $chapterLine = Add-ExtrasToLog $log $j.Src $j.Dst $extra
            $extraFiles += $extra.Files.Count
            $extraDirs  += $extra.Dirs.Count
            # Запоминаем главу первой папки, где нашлось лишнее.
            if ($extraLine -eq 0 -and ($extra.Files.Count -gt 0 -or $extra.Dirs.Count -gt 0)) { $extraLine = $chapterLine }
            if ($extra.Files.Count -gt 0 -or $extra.Dirs.Count -gt 0) {
                Write-Host ('Лишнее в копии: папок {0}, файлов {1} (список в техническом логе)' -f $extra.Dirs.Count, $extra.Files.Count) -ForegroundColor Yellow
            }
        } catch {
            Write-Host ("`r" + (' ' * 40) + "`r") -NoNewline
            Write-Host "Не удалось найти лишнее в копии: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    $finished = Get-Date
    $reportPath = ''
    if (-not $dry) {
        try { $reportPath = Write-SyncReport $Dev $started $finished $allRecords.ToArray() $skippedNotes $allNotes.ToArray() $worst $runId $log $extraFiles $extraDirs }
        catch { Write-Host "Не удалось записать отчёт: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    Write-Host ''
    if ($worst -ge 8) {
        Write-Host "Завершено С ОШИБКАМИ (наибольший код robocopy $worst)." -ForegroundColor Red
    } else {
        Write-Host "Готово (наибольший код robocopy $worst)." -ForegroundColor Green
    }
    if ($reportPath) { Write-Host "Отчёт: $reportPath  (запуск #$runId)" }
    Write-Host "Технический лог: $log" -ForegroundColor DarkGray
    if ($skipped -gt 0) {
        Write-Host "Пропущено папок: $skipped (причины выше)." -ForegroundColor Yellow
    }

    if ($extraFiles -gt 0 -or $extraDirs -gt 0) {
        # Нашлось лишнее в копии: предлагаем открыть список или выйти.
        while ($true) {
            Write-Host ''
            Write-Host ('Лишнее в копии (есть на HDD, нет в источнике): папок {0}, файлов {1}.' -f $extraDirs, $extraFiles) -ForegroundColor Yellow
            Write-Host '1. Показать полный список (откроется технический лог на нужной строке)'
            Write-Host '0. Выйти'
            if ((Ask 'Выбор') -eq '1') { Open-FileAtLine $log $extraLine } else { break }
        }
    } else {
        Pause-Menu
    }
}

# ---------------------------------------------------------------- настройки устройства

function Edit-Sources([string]$Folder) {
    while ($true) {
        $dev = Find-Device $Folder
        if (-not $dev) { return }
        $isThisPc = Test-ThisPc $dev

        Write-Title "Папки-источники: $($dev.name)"
        $sources = @(Get-Sources $dev)
        for ($i = 0; $i -lt $sources.Count; $i++) {
            Write-Host ('{0}. {1}' -f ($i + 1), $sources[$i].path)
            Write-Host ('      копия: {0}' -f (Join-Path (Join-Path $script:DataDir $dev.folder) $sources[$i].name)) -ForegroundColor DarkGray
        }
        Write-Host ''
        if ($isThisPc) {
            Write-Host 'a. Добавить папку'
            Write-Host 'd. Убрать папку из списка'
        } else {
            Write-Host "Менять список можно только на компьютере '$($dev.computerName)'." -ForegroundColor Yellow
        }
        Write-Host '0. Назад'
        Write-Host ''
        $c = Ask 'Выбор'
        if ($c -eq '0' -or $c -eq '') { return }
        if (-not $isThisPc) { continue }

        $list   = @(Get-Devices)
        $target = $list | Where-Object { $_.folder -eq $Folder } | Select-Object -First 1
        $cur    = @(Get-Sources $target)

        if ($c -eq 'a' -or $c -eq 'A') {
            $v = (Ask 'Новая папка-источник').Trim('"')
            if (-not $v) { continue }
            $problem = Test-SourceProblem $v $cur
            if ($problem) { Write-Host $problem -ForegroundColor Red; Pause-Menu; continue }
            $name = New-SourceName $v $cur
            Write-Host "Копия будет лежать в: $(Join-Path (Join-Path $script:DataDir $target.folder) $name)" -ForegroundColor DarkGray
            if (Confirm-Action "Добавить папку '$v'?") {
                $cur += [pscustomobject]@{ path = $v; name = $name }
                Set-Sources $target $cur
                Save-Devices $list
            }
        }
        elseif ($c -eq 'd' -or $c -eq 'D') {
            if ($cur.Count -le 1) {
                Write-Host 'Нельзя убрать последнюю папку: у устройства должна быть хотя бы одна.' -ForegroundColor Red
                Pause-Menu; continue
            }
            $n = 0
            if (-not [int]::TryParse((Ask 'Номер папки, которую убрать'), [ref]$n) -or $n -lt 1 -or $n -gt $cur.Count) { continue }
            $removed = $cur[$n - 1]
            Write-Host ''
            Write-Host 'Будет убрана только ЗАПИСЬ о папке из списка. Файлы НЕ удаляются:' -ForegroundColor Yellow
            Write-Host "  - уже скопированные файлы остаются на HDD: $(Join-Path (Join-Path $script:DataDir $target.folder) $removed.name)"
            Write-Host "  - исходные файлы на компьютере не затрагиваются: $($removed.path)"
            if (Confirm-Action "Убрать '$($removed.path)' из списка?") {
                $cur = @($cur | Where-Object { $_.name -ne $removed.name })
                Set-Sources $target $cur
                Save-Devices $list
            }
        }
    }
}

function Edit-Device([string]$Folder) {
    while ($true) {
        $dev = Find-Device $Folder
        if (-not $dev) { return }

        Write-Title "Настройки: $($dev.name)"
        $isThisPc = Test-ThisPc $dev
        Write-Host "Компьютер (задаётся автоматически, не редактируется): $($dev.computerName)"
        if (-not $isThisPc) {
            Write-Host "Это НЕ текущий компьютер ($env:COMPUTERNAME)." -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host "1. Название          : $($dev.name)"
        $devSources = @(Get-Sources $dev)
        Write-Host ("2. Папки-источники   : {0} шт." -f $devSources.Count)
        foreach ($s in $devSources) { Write-Host ('      {0}' -f $s.path) -ForegroundColor DarkGray }
        Write-Host ("3. Исключаемые папки : {0}  (действуют для всех источников)" -f ((@($dev.excludeDirs)) -join ', '))
        if (-not $isThisPc) { Write-Host '4. Привязать к этому компьютеру' }
        Write-Host '0. Назад'
        Write-Host ''
        $c = Ask 'Что изменить'
        if ($c -eq '0' -or $c -eq '') { return }

        $list = @(Get-Devices)
        $target = $list | Where-Object { $_.folder -eq $Folder } | Select-Object -First 1

        switch ($c) {
            '1' {
                $v = Ask 'Новое название'
                if (-not $v) { break }
                if ($list | Where-Object { $_.name -eq $v -and $_.folder -ne $Folder }) {
                    Write-Host 'Устройство с таким названием уже есть.' -ForegroundColor Red; Pause-Menu; break
                }
                if (Confirm-Action "Изменить название на '$v'?") { $target.name = $v; Save-Devices $list }
            }
            '2' { Edit-Sources $Folder }
            '3' {
                $v = Ask 'Исключаемые папки через запятую (пусто - не исключать ничего)'
                if (Confirm-Action 'Сохранить список исключений?') {
                    $target.excludeDirs = @(Read-ExcludeDirs $v)
                    Save-Devices $list
                }
            }
            '4' {
                if ($isThisPc) { break }
                Write-Host ''
                Write-Host "Сейчас устройство привязано к компьютеру: $($dev.computerName)" -ForegroundColor Yellow
                Write-Host "Будет привязано к текущему         : $env:COMPUTERNAME" -ForegroundColor Yellow
                Write-Host 'Используйте это, только если это тот же компьютер (переустановили Windows, заменили систему).'
                Write-Host 'Папка-источник останется прежней, при необходимости поправьте её после привязки.'
                if (Confirm-Action 'Привязать устройство к этому компьютеру?') {
                    $target.computerName = $env:COMPUTERNAME
                    if ($target.PSObject.Properties['machineId']) { $target.machineId = $script:MachineId }
                    else { $target | Add-Member -NotePropertyName machineId -NotePropertyValue $script:MachineId -Force }
                    Save-Devices $list
                }
            }
        }
    }
}

# ---------------------------------------------------------------- меню устройства

function Open-DeviceFolder($Dev) {
    $path = Join-Path $script:DataDir $Dev.folder
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Host 'Папки с копией ещё нет: синхронизация для этого устройства не запускалась.' -ForegroundColor Yellow
        Pause-Menu; return
    }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path)
}

function Show-DeviceMenu([string]$Folder) {
    while ($true) {
        $dev = Find-Device $Folder
        if (-not $dev) { return }

        Write-Title "Устройство: $($dev.name)"
        Write-Host "Компьютер : $($dev.computerName)"
        foreach ($s in @(Get-Sources $dev)) { Write-Host "Источник  : $($s.path)" }
        Write-Host "Копии     : $(Join-Path $script:DataDir $dev.folder)  (по подпапке на каждый источник)"
        Write-Host ''
        Write-Host '1. Провести синхронизацию'
        Write-Host '2. Изменить настройки'
        Write-Host '3. Открыть папку с копией'
        Write-Host '0. Назад'
        Write-Host ''
        switch (Ask 'Выбор') {
            '1' { Invoke-Sync $dev }
            '2' { Edit-Device $Folder }
            '3' { Open-DeviceFolder $dev }
            '0' { return }
            ''  { return }
        }
    }
}

# ---------------------------------------------------------------- добавление / удаление

function Add-Device {
    Write-Title 'Добавить устройство'
    $list = @(Get-Devices)

    $name = Ask 'Название (например: Мой - Дом)'
    if (-not $name) { Write-Host 'Название обязательно. Отмена.'; Pause-Menu; return }
    if ($list | Where-Object { $_.name -eq $name }) {
        Write-Host 'Устройство с таким названием уже есть.' -ForegroundColor Red; Pause-Menu; return
    }

    # Компьютер определяется автоматически, вводить его нельзя.
    $pc = $env:COMPUTERNAME
    Write-Host "Компьютер определён автоматически: $pc" -ForegroundColor DarkGray

    # Папок-источников может быть несколько.
    $srcs = @()
    while ($true) {
        if ($srcs.Count -eq 0) { $prompt = 'Папка-источник №1 (например: C:\Users\Имя\YandexDisk)' }
        else { $prompt = "Ещё одна папка-источник №$($srcs.Count + 1) (Enter - закончить)" }
        $v = (Ask $prompt).Trim('"')
        if (-not $v) {
            if ($srcs.Count -eq 0) { Write-Host 'Нужна хотя бы одна папка. Отмена.' -ForegroundColor Red; Pause-Menu; return }
            break
        }
        $problem = Test-SourceProblem $v $srcs
        if ($problem) { Write-Host $problem -ForegroundColor Red; continue }
        $srcs += [pscustomobject]@{ path = $v; name = (New-SourceName $v $srcs) }
        Write-Host "Добавлено: $v" -ForegroundColor DarkGray
    }

    $ex = Read-ExcludeDirs (Ask 'Исключаемые папки через запятую, для всех источников (можно пусто)')

    $folder = New-FolderName $name $list

    Write-Host ''
    Write-Host 'Будет добавлено:' -ForegroundColor Yellow
    Write-Host "  Название   : $name"
    Write-Host "  Компьютер  : $pc (автоматически)"
    foreach ($s in $srcs) {
        Write-Host "  Источник   : $($s.path)"
        Write-Host ("               -> {0}" -f (Join-Path (Join-Path $script:DataDir $folder) $s.name)) -ForegroundColor DarkGray
    }
    Write-Host ("  Исключения : {0}" -f ($ex -join ', '))
    Write-Host ''
    if (-not (Confirm-Action 'Добавить?')) { Write-Host 'Отменено.'; Pause-Menu; return }

    $new = [pscustomobject]@{
        name         = $name
        computerName = $pc
        machineId    = $script:MachineId
        sources      = @($srcs)
        folder       = $folder
        excludeDirs  = @($ex)
    }
    $list += $new
    Save-Devices $list
    Write-Host 'Устройство добавлено.' -ForegroundColor Green
    Pause-Menu
}

function Remove-Device {
    Write-Title 'Удалить устройство'
    $list = @(Get-Devices)
    $dev = Select-Device $list 'Какое устройство удалить'
    if (-not $dev) { return }

    # Удалять можно только устройство, привязанное к этому компьютеру.
    if (-not (Test-ThisPc $dev)) {
        Write-Host ''
        Write-Host "Устройство '$($dev.name)' привязано к другому компьютеру: $($dev.computerName)." -ForegroundColor Red
        Write-Host "Сейчас вы на компьютере: $env:COMPUTERNAME."
        Write-Host 'Удалить его можно только с того компьютера, к которому оно привязано.'
        Write-Host 'Если это тот же компьютер (сменилась система), привяжите устройство в его настройках.'
        Pause-Menu; return
    }

    $copyPath = Join-Path $script:DataDir $dev.folder
    Write-Host ''
    Write-Host "Будет удалена только ЗАПИСЬ об устройстве '$($dev.name)' из списка (devices.json)." -ForegroundColor Yellow
    Write-Host 'Файлы НЕ удаляются:' -ForegroundColor Yellow
    Write-Host "  - уже скопированные файлы остаются на HDD: $copyPath"
    foreach ($s in @(Get-Sources $dev)) {
        Write-Host "  - исходные файлы на компьютере не затрагиваются: $($s.path)"
    }
    Write-Host ''
    if (-not (Confirm-Action "Удалить устройство '$($dev.name)' из списка?")) {
        Write-Host 'Отменено.'; Pause-Menu; return
    }

    $rest = @($list | Where-Object { $_.folder -ne $dev.folder })
    Save-Devices $rest
    Write-Host ''
    Write-Host 'Запись удалена. Файлы не тронуты.' -ForegroundColor Green
    Write-Host "Если копия больше не нужна, папку можно удалить вручную: $copyPath"
    Pause-Menu
}

# ---------------------------------------------------------------- проводник

function Open-InExplorer {
    Write-Title 'Открыть проводник'
    $list = @(Get-Devices)
    Show-DeviceList $list
    Write-Host 'c. Общая папка (копии всех устройств)'
    Write-Host '0. Назад'
    Write-Host ''
    $c = Ask 'Выбор'
    if ($c -eq '0' -or $c -eq '') { return }

    if ($c -eq 'c' -or $c -eq 'C' -or $c -eq 'с' -or $c -eq 'С') {
        $path = $script:DataDir
    } else {
        $n = 0
        if (-not [int]::TryParse($c, [ref]$n) -or $n -lt 1 -or $n -gt $list.Count) { return }
        $path = Join-Path $script:DataDir $list[$n - 1].folder
    }

    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Write-Host 'Этой папки ещё нет: копирование для неё не запускалось.' -ForegroundColor Yellow
        Pause-Menu; return
    }
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path)
}

# ---------------------------------------------------------------- главное меню

$script:MachineId = Get-MachineId
try { Update-PcRecords } catch { Write-Host "Не удалось обновить записи: $($_.Exception.Message)" -ForegroundColor Yellow }

$running = $true
while ($running) {
    try {
        $devices = @(Get-Devices)
        Write-Title 'Резервное копирование'
        if ($devices.Count -eq 0) {
            Write-Host 'Устройств пока нет - добавьте первое (пункт 2).' -ForegroundColor Yellow
            Write-Host ''
        }
        Write-Host '1. Выбрать устройство'
        Write-Host '2. Добавить устройство'
        Write-Host '3. Удалить устройство'
        Write-Host '4. Открыть проводник с файлами'
        Write-Host '0. Выход'
        Write-Host ''

        switch (Ask 'Выбор') {
            '1' {
                Write-Title 'Выберите устройство'
                $dev = Select-Device $devices 'Номер устройства'
                if ($dev) { Show-DeviceMenu $dev.folder }
            }
            '2' { Add-Device }
            '3' { Remove-Device }
            '4' { Open-InExplorer }
            '0' { $running = $false }
        }
    } catch {
        Write-Host ''
        Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
        Pause-Menu
    }
}
