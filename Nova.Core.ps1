Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NovaHash([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-NovaPath([string]$Root, [string]$Relative) {
    if ($Relative -notmatch '^(mods/[^/]+\.jar|resourcepacks/[^/]+\.zip|shaderpacks/[^/]+\.zip|config/fancymenu/.+|config/nova/.+)$') { throw "Unmanaged path: $Relative" }
    foreach ($part in $Relative.Split('/')) {
        if ($part -in @('', '.', '..') -or $part -match '[\\:*?"<>|\x00-\x1f]' -or $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe path: $Relative" }
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $target = [IO.Path]::GetFullPath((Join-Path $rootPath $Relative.Replace('/', '\')))
    if (-not $target.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path leaves instance' }
    $cursor = $target
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse point rejected: $cursor" }
        }
        $parent = [IO.Directory]::GetParent($cursor)
        if ($null -eq $parent) { break }
        $cursor = $parent.FullName
    }
    return $target
}

function Assert-NovaRelease($Release, [string]$Root) {
    if ($Release.schema -ne 1 -or $Release.pack -ne 'nova' -or -not $Release.ready) { throw 'Release is not approved for installation' }
    if ($Release.minecraft -ne '1.21.1' -or $Release.fabric -ne '0.18.4') { throw 'Loader change requires a new imported instance' }
    if ($Release.version -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw 'Invalid release version' }
    $seen = @{}
    foreach ($file in @($Release.files)) {
        [void](Assert-NovaPath $Root $file.path)
        if ($seen.ContainsKey($file.path)) { throw 'Duplicate file path' }
        $seen[$file.path] = $true
        if ($file.sha256 -notmatch '^[a-f0-9]{64}$' -or $file.size -lt 0 -or $file.size -gt 2147483648) { throw 'Invalid file integrity fields' }
        $uri = [Uri]$file.url
        if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'HTTPS download required' }
    }
    if ($seen.Count -eq 0) { throw 'Empty release' }
}

function Save-NovaFile($File, [string]$Destination) {
    $uri=[Uri]$File.url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $File.sha256 -notmatch '^[a-f0-9]{64}$' -or $File.size -lt 0 -or $File.size -gt 2147483648) { throw 'Invalid download metadata' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $File.url -OutFile $Destination -TimeoutSec 120 | Out-Null
    if ((Get-Item -LiteralPath $Destination).Length -ne $File.size -or (Get-NovaHash $Destination) -ne $File.sha256) { throw "Download checksum mismatch: $($File.path)" }
}

function Assert-NovaGameStopped {
    # Refuse to update while any Java game/server is running. Do not read arguments or tokens.
    if (Get-Process -Name java,javaw -ErrorAction SilentlyContinue) { throw 'Close Minecraft and Java launchers before updating. No files changed.' }
}

function Invoke-NovaUpdate([string]$Root, $Release, [string]$Workspace) {
    Assert-NovaRelease $Release $Root
    Assert-NovaGameStopped
    $statePath = Join-Path $Root '.nova-managed.json'
    $pendingPath = Join-Path $Root '.nova-pending.json'
    if (Test-Path -LiteralPath $pendingPath) { throw 'Interrupted update detected. Restore the recorded backup before launching.' }
    if (-not (Test-Path -LiteralPath $statePath)) { throw 'Instance must be registered after first import' }
    if ((Get-Item -LiteralPath $statePath).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Invalid state link' }
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.pack -ne 'nova') { throw 'Wrong managed instance' }
    $lockPath = Join-Path $Root '.nova-update.lock'
    if ((Test-Path -LiteralPath $lockPath) -and ((Get-Item -LiteralPath $lockPath).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Invalid lock link' }
    $lock = [IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
    try {
        $old = @{}; $desired = @{}; $changes = @(); $removals = @()
        foreach ($f in @($state.files)) {
            $p = Assert-NovaPath $Root $f.path
            if ($old.ContainsKey($f.path) -or $f.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid managed file state' }
            $old[$f.path] = $f
            if (-not (Test-Path -LiteralPath $p) -or (Get-NovaHash $p) -ne $f.sha256) { throw "Local file changed; preserve and review: $($f.path)" }
        }
        foreach ($f in @($Release.files)) {
            $p = Assert-NovaPath $Root $f.path; $desired[$f.path] = $f
            if (-not $old.ContainsKey($f.path) -and (Test-Path -LiteralPath $p)) { throw "Unmanaged file collision: $($f.path)" }
            if (-not $old.ContainsKey($f.path) -or $old[$f.path].sha256 -ne $f.sha256) { $changes += $f }
        }
        foreach ($name in $old.Keys) { if (-not $desired.ContainsKey($name)) { $removals += $old[$name] } }
        if ($changes.Count -eq 0 -and $removals.Count -eq 0 -and $state.version -eq $Release.version) { return 'already-current' }
        $transaction = Join-Path $Workspace ('transactions/' + [Guid]::NewGuid().ToString('N'))
        $staging = Join-Path $transaction 'download'; $backup = Join-Path $transaction 'backup'
        [void](New-Item -ItemType Directory -Path $staging,$backup -Force)
        foreach ($f in $changes) {
            $temp = Join-Path $staging $f.sha256
            if (-not (Test-Path -LiteralPath $temp)) { Save-NovaFile $f $temp }
            if ((Get-NovaHash $temp) -ne $f.sha256 -or (Get-Item $temp).Length -ne $f.size) { throw 'Staged file verification failed' }
        }
        Assert-NovaGameStopped
        Copy-Item -LiteralPath $statePath -Destination (Join-Path $backup 'state.json')
        $journal = @()
        foreach ($f in @($changes) + @($removals)) {
            $dest = Assert-NovaPath $Root $f.path
            $exists = Test-Path -LiteralPath $dest
            if ($exists) {
                if (-not $old.ContainsKey($f.path) -or (Get-NovaHash $dest) -ne $old[$f.path].sha256) { throw 'Files changed during preparation' }
                $b = Join-Path $backup $f.path
                [void](New-Item -ItemType Directory -Path (Split-Path $b) -Force)
                Copy-Item -LiteralPath $dest -Destination $b
                if ((Get-NovaHash $b) -ne $old[$f.path].sha256) { throw 'Backup verification failed' }
            }
            $journal += [PSCustomObject]@{path=$f.path;existed=$exists}
        }
        $journal | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $transaction 'journal.json') -Encoding UTF8
        @{transaction=$transaction} | ConvertTo-Json | Set-Content -LiteralPath $pendingPath -Encoding UTF8
        $changed = @()
        try {
            foreach ($f in $changes) {
                $dest = Assert-NovaPath $Root $f.path
                [void](New-Item -ItemType Directory -Path (Split-Path $dest) -Force)
                $changed += $f.path
                Copy-Item -LiteralPath (Join-Path $staging $f.sha256) -Destination $dest -Force
                if ((Get-NovaHash $dest) -ne $f.sha256) { throw 'Installed file verification failed' }
            }
            foreach ($f in $removals) {
                $dest = Assert-NovaPath $Root $f.path; $changed += $f.path
                Remove-Item -LiteralPath $dest
            }
            $nextState = @{schema=1;pack='nova';version=$Release.version;files=@($Release.files | Select-Object path,sha256)}
            $tempState = Join-Path $transaction 'next-state.json'
            $nextState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tempState -Encoding UTF8
            Copy-Item -LiteralPath $tempState -Destination $statePath -Force
            'committed' | Set-Content -LiteralPath (Join-Path $transaction 'status.txt')
            Remove-Item -LiteralPath $pendingPath
            return 'updated'
        } catch {
            $failure = $_
            foreach ($entry in $journal) {
                if ($changed -notcontains $entry.path) { continue }
                $dest = Assert-NovaPath $Root $entry.path
                if ($entry.existed) { Copy-Item -LiteralPath (Join-Path $backup $entry.path) -Destination $dest -Force }
                elseif (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest }
            }
            Copy-Item -LiteralPath (Join-Path $backup 'state.json') -Destination $statePath -Force
            'rolled-back' | Set-Content -LiteralPath (Join-Path $transaction 'status.txt')
            Remove-Item -LiteralPath $pendingPath
            throw $failure
        }
    } finally { $lock.Dispose() }
}
