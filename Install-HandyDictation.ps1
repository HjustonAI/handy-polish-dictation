#Requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Whisper', 'Parakeet')]
    [string]$Engine = 'Auto',

    [string]$MicrophoneName,

    [switch]$AuditOnly,

    [switch]$NoStart
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptRoot = $PSScriptRoot
$ManifestPath = Join-Path $ScriptRoot 'config\versions.json'
$OverridesPath = Join-Path $ScriptRoot 'config\settings-overrides.json'
$HandyExe = Join-Path $env:LOCALAPPDATA 'Handy\Handy.exe'
$HandyData = Join-Path $env:APPDATA 'com.pais.handy'
$SettingsPath = Join-Path $HandyData 'settings_store.json'
$TempRoot = Join-Path $env:TEMP 'HandyPolishDictation'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Write-Note {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor DarkCyan
}

function Write-Caution {
    param([string]$Message)
    Write-Host "[UWAGA] $Message" -ForegroundColor Yellow
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Brakuje pliku: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-ExpectedHash {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $actual -eq $ExpectedSha256.ToLowerInvariant()
}

function Get-VerifiedDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$DisplayName
    )

    $destinationDirectory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null

    if (Test-ExpectedHash -Path $Destination -ExpectedSha256 $ExpectedSha256) {
        Write-Ok "$DisplayName jest już pobrany i ma poprawną sumę SHA-256."
        return
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $partial = "$Destination.partial"
    if (Test-Path -LiteralPath $partial) {
        Remove-Item -LiteralPath $partial -Force
    }

    Write-Note "Pobieranie: $DisplayName"
    try {
        if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
            Start-BitsTransfer -Source $Url -Destination $partial -DisplayName $DisplayName -Description 'Instalator polskiego dyktowania'
        }
        else {
            Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        }
    }
    catch {
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
        throw "Nie udało się pobrać $DisplayName. $($_.Exception.Message)"
    }

    if (-not (Test-ExpectedHash -Path $partial -ExpectedSha256 $ExpectedSha256)) {
        $actual = if (Test-Path -LiteralPath $partial) {
            (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        else {
            'brak pliku'
        }
        if (Test-Path -LiteralPath $partial) {
            Remove-Item -LiteralPath $partial -Force
        }
        throw "Błędna suma SHA-256 dla $DisplayName. Oczekiwano $ExpectedSha256, otrzymano $actual."
    }

    Move-Item -LiteralPath $partial -Destination $Destination
    Write-Ok "Pobrano i zweryfikowano: $DisplayName"
}

function Stop-Handy {
    $processes = @(Get-Process -Name 'Handy' -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(1200)) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
                [void]$process.WaitForExit(3000)
            }
        }
        catch {
            if (Get-Process -Id $process.Id -ErrorAction SilentlyContinue) {
                Stop-Process -Id $process.Id -Force -ErrorAction Stop
            }
        }
    }
}

function Install-Handy {
    param([Parameter(Mandatory = $true)]$Manifest)

    $expectedVersion = [string]$Manifest.handy.version
    if (Test-Path -LiteralPath $HandyExe -PathType Leaf) {
        $installedVersion = (Get-Item -LiteralPath $HandyExe).VersionInfo.FileVersion
        if ($installedVersion -eq $expectedVersion) {
            Write-Ok "Handy $expectedVersion jest już zainstalowany."
            return
        }
        Write-Caution "Zainstalowana wersja Handy to $installedVersion; instaluję przypiętą wersję $expectedVersion."
    }

    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
    $installer = Join-Path $TempRoot "Handy_$expectedVersion`_x64-setup.exe"
    Get-VerifiedDownload -Url ([string]$Manifest.handy.url) -Destination $installer -ExpectedSha256 ([string]$Manifest.handy.sha256) -DisplayName "Handy $expectedVersion"

    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid') {
        throw "Podpis cyfrowy instalatora Handy nie jest prawidłowy: $($signature.Status)."
    }
    if ($signature.SignerCertificate.Subject -notlike "*$($Manifest.handy.signer_contains)*") {
        throw "Nieoczekiwany wydawca instalatora Handy: $($signature.SignerCertificate.Subject)."
    }
    Write-Ok "Podpis cyfrowy instalatora jest prawidłowy ($($Manifest.handy.signer_contains))."

    Stop-Handy
    $installProcess = Start-Process -FilePath $installer -ArgumentList '/S' -Wait -PassThru
    if ($installProcess.ExitCode -ne 0) {
        throw "Instalator Handy zakończył się kodem $($installProcess.ExitCode)."
    }
    if (-not (Test-Path -LiteralPath $HandyExe -PathType Leaf)) {
        throw "Instalator zakończył pracę, ale nie znaleziono $HandyExe."
    }
    $installedVersion = (Get-Item -LiteralPath $HandyExe).VersionInfo.FileVersion
    if ($installedVersion -ne $expectedVersion) {
        throw "Po instalacji wykryto wersję $installedVersion zamiast $expectedVersion."
    }

    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    Write-Ok "Zainstalowano Handy $expectedVersion dla bieżącego użytkownika."
}

function Get-ComputeDevices {
    if (-not (Test-Path -LiteralPath $HandyExe -PathType Leaf)) {
        return @()
    }

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $HandyExe --list-devices 2>&1 | Out-String -Width 500
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $devices = @()
    foreach ($line in ($output -split "`r?`n")) {
        if ($line -match '^\s*index=(\d+)\s+kind=(\S+)\s+name=(.+?)\s+vram=(\d+)MB\s*$') {
            $devices += [pscustomobject]@{
                Index  = [int]$Matches[1]
                Kind   = [string]$Matches[2]
                Name   = [string]$Matches[3]
                VramMb = [int64]$Matches[4]
            }
        }
    }
    return $devices
}

function Select-DiscreteGpu {
    param(
        [Parameter(Mandatory = $true)][array]$Devices,
        [Parameter(Mandatory = $true)][int64]$MinimumVramMb
    )

    $candidates = @($Devices | Where-Object {
        $_.Kind -eq 'vulkan' -and
        $_.VramMb -ge $MinimumVramMb -and
        $_.Name -match '(?i)(NVIDIA|Radeon\s+RX|Radeon\s+Pro|Intel.*Arc)'
    })

    return $candidates |
        Sort-Object @{ Expression = {
            if ($_.Name -match '(?i)NVIDIA') { 0 }
            elseif ($_.Name -match '(?i)Radeon') { 1 }
            else { 2 }
        } }, @{ Expression = 'VramMb'; Descending = $true } |
        Select-Object -First 1
}

function Ensure-WhisperModel {
    param([Parameter(Mandatory = $true)]$Model)

    Write-Step 'Przygotowanie modelu Whisper Large v3 Turbo Q8'
    $repoFolderName = 'models--' + ([string]$Model.repo_id -replace '/', '--')
    $repoRoot = Join-Path (Join-Path $env:USERPROFILE '.cache\huggingface\hub') $repoFolderName
    $blobDirectory = Join-Path $repoRoot 'blobs'
    $refsDirectory = Join-Path $repoRoot 'refs'
    $snapshotDirectory = Join-Path (Join-Path $repoRoot 'snapshots') ([string]$Model.revision)
    $blobPath = Join-Path $blobDirectory ([string]$Model.sha256)
    $snapshotPath = Join-Path $snapshotDirectory ([string]$Model.filename)
    $refPath = Join-Path $refsDirectory 'main'

    New-Item -ItemType Directory -Path $blobDirectory, $refsDirectory, $snapshotDirectory -Force | Out-Null
    Get-VerifiedDownload -Url ([string]$Model.url) -Destination $blobPath -ExpectedSha256 ([string]$Model.sha256) -DisplayName 'Whisper Large v3 Turbo Q8 (~845 MB)'

    if (-not (Test-ExpectedHash -Path $snapshotPath -ExpectedSha256 ([string]$Model.sha256))) {
        if (Test-Path -LiteralPath $snapshotPath) {
            Remove-Item -LiteralPath $snapshotPath -Force
        }
        try {
            New-Item -ItemType HardLink -Path $snapshotPath -Target $blobPath -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Caution 'Nie udało się utworzyć dowiązania twardego; model zostanie skopiowany (zajmie dodatkowe ~845 MB).'
            Copy-Item -LiteralPath $blobPath -Destination $snapshotPath
        }
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($refPath, [string]$Model.revision, $utf8NoBom)
    Write-Ok 'Model Whisper jest zarejestrowany w pamięci podręcznej Hugging Face.'
}

function Remove-SafeTempDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $resolvedRoot = [IO.Path]::GetFullPath($TempRoot).TrimEnd('\') + '\'
    $resolvedPath = [IO.Path]::GetFullPath($Path).TrimEnd('\') + '\'
    if (-not $resolvedPath.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or $resolvedPath -eq $resolvedRoot) {
        throw "Odmowa usunięcia katalogu spoza bezpiecznego katalogu tymczasowego: $Path"
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Test-ParakeetDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $config = Join-Path $Path 'config.json'
    $encoder = Join-Path $Path 'encoder-model.int8.onnx'
    return (Test-Path -LiteralPath $config -PathType Leaf) -and
        (Test-Path -LiteralPath $encoder -PathType Leaf) -and
        ((Get-Item -LiteralPath $encoder).Length -gt 100MB)
}

function Ensure-ParakeetModel {
    param([Parameter(Mandatory = $true)]$Model)

    Write-Step 'Przygotowanie szybkiego modelu Parakeet V3'
    $modelsRoot = Join-Path $HandyData 'models'
    $destination = Join-Path $modelsRoot ([string]$Model.directory)
    if (Test-ParakeetDirectory -Path $destination) {
        Write-Ok 'Model Parakeet V3 jest już zainstalowany.'
        return
    }

    New-Item -ItemType Directory -Path $modelsRoot, $TempRoot -Force | Out-Null
    $archive = Join-Path $TempRoot 'parakeet-v3-int8.tar.gz'
    Get-VerifiedDownload -Url ([string]$Model.url) -Destination $archive -ExpectedSha256 ([string]$Model.sha256) -DisplayName 'Parakeet V3 (~456 MB)'

    $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
    if (-not $tar) {
        throw 'Brakuje systemowego programu tar.exe potrzebnego do rozpakowania modelu.'
    }

    $staging = Join-Path $TempRoot ('parakeet-extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    & $tar.Source -xzf $archive -C $staging
    if ($LASTEXITCODE -ne 0) {
        throw "Nie udało się rozpakować modelu Parakeet (kod $LASTEXITCODE)."
    }

    $sourceDirectory = Get-ChildItem -LiteralPath $staging -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq [string]$Model.directory } |
        Select-Object -First 1
    if ($sourceDirectory) {
        $sourcePath = $sourceDirectory.FullName
    }
    elseif (Test-ParakeetDirectory -Path $staging) {
        $sourcePath = $staging
    }
    else {
        throw 'Archiwum Parakeet nie zawiera oczekiwanych plików modelu.'
    }

    if (Test-Path -LiteralPath $destination) {
        $backup = "$destination.broken-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $destination -Destination $backup
        Write-Caution "Niekompletny poprzedni model przeniesiono do: $backup"
    }
    Move-Item -LiteralPath $sourcePath -Destination $destination

    if (-not (Test-ParakeetDirectory -Path $destination)) {
        throw 'Model Parakeet po rozpakowaniu nie przeszedł kontroli plików.'
    }

    if (Test-Path -LiteralPath $staging) {
        Remove-SafeTempDirectory -Path $staging
    }
    Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
    Write-Ok 'Model Parakeet V3 jest gotowy.'
}

function Get-AudioEndpointNames {
    if (-not (Get-Command Get-PnpDevice -ErrorAction SilentlyContinue)) {
        return @()
    }
    return @(Get-PnpDevice -Class AudioEndpoint -Status OK -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FriendlyName -Unique)
}

function Select-Microphone {
    param([string]$RequestedName)

    $endpoints = @(Get-AudioEndpointNames)
    if ($RequestedName) {
        if ($endpoints.Count -gt 0 -and $RequestedName -notin $endpoints) {
            throw "Nie znaleziono urządzenia audio o dokładnej nazwie '$RequestedName'. Podłącz je albo uruchom instalator bez parametru -MicrophoneName."
        }
        return $RequestedName
    }

    $focusrite = $endpoints |
        Where-Object {
            $_ -match '(?i)Focusrite' -and
            $_ -match '(?i)(Analogue|Mic|Mikrofon|Input)' -and
            $_ -notmatch '(?i)(Głośniki|Speakers|Output)'
        } |
        Select-Object -First 1

    if ($focusrite) {
        return [string]$focusrite
    }
    return $null
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowNull()]$Value
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    }
    else {
        Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Merge-Object {
    param(
        [Parameter(Mandatory = $true)]$Target,
        [Parameter(Mandatory = $true)]$Source
    )

    foreach ($sourceProperty in $Source.PSObject.Properties) {
        $name = $sourceProperty.Name
        $value = $sourceProperty.Value
        if ($value -is [Management.Automation.PSCustomObject]) {
            $targetProperty = $Target.PSObject.Properties[$name]
            if (-not $targetProperty -or -not ($targetProperty.Value -is [Management.Automation.PSCustomObject])) {
                Set-ObjectProperty -Object $Target -Name $name -Value ([pscustomobject]@{})
            }
            Merge-Object -Target $Target.PSObject.Properties[$name].Value -Source $value
        }
        else {
            Set-ObjectProperty -Object $Target -Name $name -Value $value
        }
    }
}

function Ensure-DefaultSettingsFile {
    if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
        return
    }

    New-Item -ItemType Directory -Path $HandyData -Force | Out-Null
    $process = Start-Process -FilePath $HandyExe -ArgumentList '--start-hidden' -PassThru
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        if (Test-Path -LiteralPath $SettingsPath -PathType Leaf) {
            break
        }
        Start-Sleep -Milliseconds 400
    }
    Stop-Handy

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        throw "Handy nie utworzył domyślnego pliku ustawień: $SettingsPath"
    }
}

function Set-HandyConfiguration {
    param(
        [Parameter(Mandatory = $true)][string]$SelectedModel,
        [Parameter(Mandatory = $true)][string]$Accelerator,
        [AllowNull()][Nullable[int]]$GpuDevice,
        [AllowNull()][string]$SelectedMicrophone
    )

    Write-Step 'Konfigurowanie polskiego dyktowania'
    Stop-Handy
    Ensure-DefaultSettingsFile

    $backupPath = Join-Path $HandyData ("settings_store.$(Get-Date -Format 'yyyyMMdd-HHmmss').backup.json")
    Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
    Write-Note "Kopia poprzednich ustawień: $backupPath"

    try {
        $root = Read-JsonFile -Path $SettingsPath
    }
    catch {
        $brokenPath = Join-Path $HandyData ("settings_store.$(Get-Date -Format 'yyyyMMdd-HHmmss').invalid.json")
        Move-Item -LiteralPath $SettingsPath -Destination $brokenPath
        throw "Plik ustawień Handy ma nieprawidłowy JSON. Zachowano go jako $brokenPath."
    }

    if (-not $root.PSObject.Properties['settings']) {
        Set-ObjectProperty -Object $root -Name 'settings' -Value ([pscustomobject]@{})
    }
    $overrides = Read-JsonFile -Path $OverridesPath
    Merge-Object -Target $root.settings -Source $overrides

    Set-ObjectProperty -Object $root.settings -Name 'selected_model' -Value $SelectedModel
    Set-ObjectProperty -Object $root.settings -Name 'selected_microphone' -Value $SelectedMicrophone
    Set-ObjectProperty -Object $root.settings -Name 'transcribe_accelerator' -Value $Accelerator
    Set-ObjectProperty -Object $root.settings -Name 'transcribe_gpu_device' -Value $GpuDevice

    $json = $root | ConvertTo-Json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($SettingsPath, $json + [Environment]::NewLine, $utf8NoBom)

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $runKey -Force | Out-Null
    Set-ItemProperty -Path $runKey -Name 'Handy' -Value ('"' + $HandyExe + '" --start-hidden')

    Write-Ok 'Ustawiono język polski, tryb przełączany i skrót Ctrl + * na klawiaturze numerycznej.'
    Write-Ok 'Tekst będzie wklejany automatycznie i pozostanie w schowku.'
    Write-Ok 'Stały mikrofon, zapisywanie nagrań i przetwarzanie w chmurze są wyłączone.'
    if ($SelectedMicrophone) {
        Write-Ok "Wybrany mikrofon: $SelectedMicrophone"
    }
    else {
        Write-Note 'Nie znaleziono Focusrite — Handy użyje domyślnego mikrofonu wejściowego Windows.'
    }
}

function Test-Installation {
    param([Parameter(Mandatory = $true)]$Manifest)

    Write-Step 'Kontrola instalacji'
    $issues = New-Object System.Collections.Generic.List[string]

    if (-not (Test-Path -LiteralPath $HandyExe -PathType Leaf)) {
        $issues.Add("Brakuje programu: $HandyExe")
    }
    else {
        $version = (Get-Item -LiteralPath $HandyExe).VersionInfo.FileVersion
        if ($version -ne [string]$Manifest.handy.version) {
            $issues.Add("Wersja Handy to $version zamiast $($Manifest.handy.version).")
        }
        else {
            Write-Ok "Handy $version"
        }
    }

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        $issues.Add("Brakuje ustawień: $SettingsPath")
    }
    else {
        try {
            $settings = (Read-JsonFile -Path $SettingsPath).settings
            if ($settings.bindings.transcribe.current_binding -ne 'ctrl+KeypadMultiply') {
                $issues.Add('Skrót nie jest ustawiony na Ctrl + numpad *.')
            }
            if ($settings.selected_language -ne 'pl') {
                $issues.Add('Język transkrypcji nie jest ustawiony na polski.')
            }
            if ($settings.always_on_microphone -ne $false) {
                $issues.Add('Opcja stałego mikrofonu nie jest wyłączona.')
            }
            if ($settings.push_to_talk -ne $false) {
                $issues.Add('Tryb nagrywania nie jest ustawiony jako przełącznik.')
            }
            if ($settings.post_process_enabled -ne $false) {
                $issues.Add('Przetwarzanie sieciowe/post-processing nie jest wyłączone.')
            }
            if ($settings.recording_retention_period -ne 'never') {
                $issues.Add('Zapisywanie nagrań nie jest wyłączone.')
            }

            $selectedModel = [string]$settings.selected_model
            if ($selectedModel -eq [string]$Manifest.whisper.id) {
                $repoFolderName = 'models--' + ([string]$Manifest.whisper.repo_id -replace '/', '--')
                $modelPath = Join-Path (Join-Path (Join-Path (Join-Path $env:USERPROFILE '.cache\huggingface\hub') $repoFolderName) 'snapshots') ([string]$Manifest.whisper.revision)
                $modelPath = Join-Path $modelPath ([string]$Manifest.whisper.filename)
                if (-not (Test-ExpectedHash -Path $modelPath -ExpectedSha256 ([string]$Manifest.whisper.sha256))) {
                    $issues.Add('Model Whisper jest nieobecny albo ma błędną sumę SHA-256.')
                }
                else {
                    Write-Ok 'Model Whisper Large v3 Turbo Q8'
                }
            }
            elseif ($selectedModel -eq [string]$Manifest.parakeet.id) {
                $modelPath = Join-Path (Join-Path $HandyData 'models') ([string]$Manifest.parakeet.directory)
                if (-not (Test-ParakeetDirectory -Path $modelPath)) {
                    $issues.Add('Model Parakeet jest nieobecny albo niekompletny.')
                }
                else {
                    Write-Ok 'Model Parakeet V3'
                }
            }
            else {
                $issues.Add("Wybrano nieoczekiwany model: $selectedModel")
            }

            Write-Ok 'Konfiguracja prywatności i skrótu klawiszowego'
            if ($settings.selected_microphone) {
                Write-Note "Mikrofon: $($settings.selected_microphone)"
            }
            else {
                Write-Note 'Mikrofon: domyślne wejście Windows'
            }
        }
        catch {
            $issues.Add("Nie można sprawdzić ustawień: $($_.Exception.Message)")
        }
    }

    $runValue = Get-ItemPropertyValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Handy' -ErrorAction SilentlyContinue
    if (-not $runValue) {
        $issues.Add('Brakuje autostartu Handy dla bieżącego użytkownika.')
    }
    else {
        Write-Ok 'Autostart Handy'
    }

    if (Get-Process -Name 'Handy' -ErrorAction SilentlyContinue) {
        Write-Ok 'Handy działa w tle'
    }
    else {
        Write-Caution 'Handy nie działa teraz w tle (konfiguracja autostartu jest sprawdzana osobno).'
    }

    if ($issues.Count -gt 0) {
        foreach ($issue in $issues) {
            Write-Host "[BŁĄD] $issue" -ForegroundColor Red
        }
        return $false
    }

    Write-Ok 'Wszystkie kontrole zakończone pomyślnie.'
    return $true
}

function Invoke-Main {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Ten instalator obsługuje wyłącznie Windows.'
    }
    if (-not [Environment]::Is64BitOperatingSystem) {
        throw 'Handy wymaga 64-bitowego systemu Windows.'
    }

    $manifest = Read-JsonFile -Path $ManifestPath

    if ($AuditOnly) {
        if (Test-Installation -Manifest $manifest) {
            exit 0
        }
        exit 2
    }

    Write-Host 'Polskie dyktowanie lokalne — instalator' -ForegroundColor White
    Write-Host 'Program nie uruchomi testu mikrofonu i nie nagra dźwięku podczas instalacji.' -ForegroundColor DarkGray

    Write-Step 'Instalacja aplikacji'
    Install-Handy -Manifest $manifest
    Stop-Handy

    Write-Step 'Analiza dostępnych urządzeń obliczeniowych'
    $devices = @(Get-ComputeDevices)
    foreach ($device in $devices) {
        Write-Note "[$($device.Index)] $($device.Kind): $($device.Name), pamięć raportowana $($device.VramMb) MB"
    }
    $gpu = Select-DiscreteGpu -Devices $devices -MinimumVramMb ([int64]$manifest.whisper.minimum_discrete_gpu_vram_mb)

    $selectedEngine = $Engine
    if ($selectedEngine -eq 'Auto') {
        if ($gpu) {
            $selectedEngine = 'Whisper'
        }
        else {
            $selectedEngine = 'Parakeet'
        }
    }

    if ($selectedEngine -eq 'Whisper') {
        Ensure-WhisperModel -Model $manifest.whisper
        $selectedModel = [string]$manifest.whisper.id
        if ($gpu) {
            $accelerator = 'gpu'
            $gpuDevice = [Nullable[int]]([int]$gpu.Index)
            Write-Ok "Whisper użyje GPU: $($gpu.Name)"
        }
        else {
            $accelerator = 'cpu'
            $gpuDevice = $null
            Write-Caution 'Nie wykryto odpowiedniej dedykowanej karty. Whisper będzie działał na CPU i może być wolniejszy.'
        }
    }
    else {
        Ensure-ParakeetModel -Model $manifest.parakeet
        $selectedModel = [string]$manifest.parakeet.id
        $accelerator = 'cpu'
        $gpuDevice = $null
        Write-Ok 'Wybrano Parakeet V3 — wariant szybszy na komputerach bez mocnego GPU.'
    }

    $microphone = Select-Microphone -RequestedName $MicrophoneName
    Set-HandyConfiguration -SelectedModel $selectedModel -Accelerator $accelerator -GpuDevice $gpuDevice -SelectedMicrophone $microphone

    if (-not $NoStart) {
        Start-Process -FilePath $HandyExe -ArgumentList '--start-hidden'
        Start-Sleep -Milliseconds 900
    }

    if (-not (Test-Installation -Manifest $manifest)) {
        throw 'Instalacja zakończyła się, ale co najmniej jedna kontrola nie powiodła się.'
    }

    Write-Host "`nGotowe." -ForegroundColor Green
    Write-Host 'Ctrl + * na klawiaturze numerycznej — rozpocznij nagrywanie.'
    Write-Host 'Naciśnij ten sam skrót ponownie — zakończ, przepisz i wklej tekst.'
    Write-Host 'Escape — anuluj bieżące nagranie.'
}

try {
    Invoke-Main
}
catch {
    Write-Host "`n[BŁĄD] $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Szczegóły: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkRed
    exit 1
}
