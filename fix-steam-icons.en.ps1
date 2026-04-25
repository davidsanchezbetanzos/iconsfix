# =============================================================================
#  Fix Steam Icons - Single script
#  Author: Claude (Cowork) for Davs
# -----------------------------------------------------------------------------
#  What it does, in order. It won't ask you anything unless two .exe
#  candidates are tied for a given game:
#    1. Reads appmanifest_*.acf from the configured Steam libraries and
#       extracts (appid, name, installdir) for every installed game.
#    2. Scans desktop shortcuts (.lnk and .url).
#    3. For each Steam-like shortcut: pulls the appid, locates the main
#       .exe of the game (heuristic), and points the shortcut's icon at
#       that .exe.
#       -> Only prompts you when there are tied candidates.
#    4. Forces Windows to repaint icons: SHChangeNotify + touch +
#       rename-trick on .lnk files + icon/thumbnail cache purge +
#       Explorer restart.
#    5. Prints a summary table.
# =============================================================================

# ---------- CONFIGURATION ----------------------------------------------------
$SteamLibraries = @(
    'F:\SteamLibrary',
    'E:\SteamLibrary',
    'D:\SteamLibrary'
)

# Name fragments that disqualify an .exe as "main executable"
$ExeBlacklist = @(
    'unins','uninstall','setup','installer','redist','vcredist',
    'dxsetup','directx','dotnet','windowsdesktop-runtime',
    'crashpad','crashreport','crashhandler','bugtrap','cef',
    'eac','easyanticheat','battleye','benchmark','driverversionchecker'
)

$ErrorActionPreference = 'Stop'

function Write-Title($t) {
    Write-Host ""
    Write-Host ("=" * 72) -ForegroundColor Cyan
    Write-Host "  $t" -ForegroundColor Cyan
    Write-Host ("=" * 72) -ForegroundColor Cyan
}
function Write-Section($t) {
    Write-Host ""
    Write-Host "-- $t --" -ForegroundColor Yellow
}

# ---------- ACF PARSER -------------------------------------------------------
# appmanifest_*.acf uses Valve's KeyValues format. For our purposes
# (appid/name/installdir) a flat key-value regex pass is enough.
function Parse-Acf {
    param([string]$Path)
    $text = Get-Content -Raw -LiteralPath $Path -ErrorAction Stop
    $result = @{}
    $rx = [regex]'"([^"]+)"\s+"([^"]*)"'
    foreach ($m in $rx.Matches($text)) {
        $k = $m.Groups[1].Value; $v = $m.Groups[2].Value
        if (-not $result.ContainsKey($k)) { $result[$k] = $v }
    }
    return $result
}

function Get-InstalledGames {
    param([string[]]$Libraries)
    $games = @()
    foreach ($lib in $Libraries) {
        $sa = Join-Path $lib 'steamapps'
        if (-not (Test-Path $sa)) {
            Write-Host "  [warn] missing: $sa" -ForegroundColor DarkYellow
            continue
        }
        $mfs = Get-ChildItem -Path $sa -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue
        foreach ($mf in $mfs) {
            try { $kv = Parse-Acf -Path $mf.FullName } catch { continue }
            $appid = $kv['appid']; $name = $kv['name']; $inst = $kv['installdir']
            if (-not $appid -or -not $inst) { continue }
            $ip = Join-Path (Join-Path $sa 'common') $inst
            $games += [PSCustomObject]@{
                AppId = $appid; Name = $name; InstallDir = $inst
                InstallPath = $ip; Library = $lib; Exists = (Test-Path $ip)
            }
        }
    }
    return $games
}

# ---------- MAIN .EXE HEURISTIC ----------------------------------------------
# Scores every .exe under the install path by:
#   - depth (closer to root is better)
#   - being inside common binary folders (bin, Binaries, Win64, x64)
#   - name similarity to the game's name (tokenized)
#   - file size (main exes tend to be bigger than helpers)
# Penalises blacklisted names (installers, crash handlers, redistributables).
function Get-MainExe {
    param([string]$InstallPath, [string]$GameName)
    if (-not (Test-Path $InstallPath)) { return @() }
    $exes = Get-ChildItem -Path $InstallPath -Filter *.exe -File -Recurse -Depth 3 -ErrorAction SilentlyContinue
    if (-not $exes) { return @() }

    $words = ($GameName -replace "[^a-zA-Z0-9 ]", ' ').ToLower() -split '\s+' |
             Where-Object { $_.Length -ge 3 }

    $scored = foreach ($e in $exes) {
        $rel = $e.FullName.Substring($InstallPath.Length).TrimStart('\','/')
        $depth = ($rel.Split('\')).Count
        $lower = $e.Name.ToLower()
        $lowerRel = $rel.ToLower()
        $s = 0
        if     ($depth -eq 1) { $s += 20 }
        elseif ($depth -eq 2) { $s += 10 }
        elseif ($depth -eq 3) { $s += 4  }
        if ($rel -match '\\(bin|Bin|Binaries|Win64|x64)\\') { $s += 6 }
        foreach ($bad in $ExeBlacklist) {
            if ($lower.Contains($bad) -or $lowerRel.Contains($bad)) { $s -= 50 }
        }
        foreach ($w in $words) {
            if ($lower.Contains($w)) { $s += 8 }
        }
        if ($e.Length -gt 10MB) { $s += 3 }
        if ($e.Length -gt 50MB) { $s += 3 }
        [PSCustomObject]@{ Path=$e.FullName; Name=$e.Name; Rel=$rel; Size=$e.Length; Score=$s }
    }
    return ($scored | Sort-Object -Property Score -Descending)
}

# ---------- SHORTCUT DISCOVERY -----------------------------------------------
function Get-SteamShortcuts {
    $desktops = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $shell = New-Object -ComObject WScript.Shell
    $items = @()
    foreach ($desk in $desktops) {
        # Classic .lnk shortcuts
        Get-ChildItem -Path $desk -Filter *.lnk -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $sc = $shell.CreateShortcut($_.FullName)
                $items += [PSCustomObject]@{
                    Type='lnk'; Name=$_.BaseName; Path=$_.FullName
                    Target=$sc.TargetPath; Arguments=$sc.Arguments; IconLocation=$sc.IconLocation
                }
            } catch {}
        }
        # URL shortcuts (Steam sometimes uses these instead of .lnk)
        Get-ChildItem -Path $desk -Filter *.url -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $lines = Get-Content -LiteralPath $_.FullName -ErrorAction Stop
                $url = ($lines | Where-Object { $_ -like 'URL=*' } | Select-Object -First 1) -replace '^URL=',''
                $icf = ($lines | Where-Object { $_ -like 'IconFile=*' } | Select-Object -First 1) -replace '^IconFile=',''
                $items += [PSCustomObject]@{
                    Type='url'; Name=$_.BaseName; Path=$_.FullName
                    Target=$url; Arguments=''; IconLocation=$icf
                }
            } catch {}
        }
    }
    # Filter to shortcuts that "smell like Steam"
    $items | Where-Object {
        ($_.Target -like '*steam.exe') -or
        ($_.Target -match '^steam://') -or
        ($_.Arguments -match 'applaunch') -or
        ($_.Arguments -match 'steam://') -or
        ($_.IconLocation -match '\\[Ss]team\\') -or
        ($_.IconLocation -match 'SteamLibrary')
    }
}

function Get-AppIdFromShortcut {
    param($Sc)
    foreach ($s in @($Sc.Arguments, $Sc.Target)) {
        if (-not $s) { continue }
        if ($s -match 'rungameid[/=](\d+)') { return $Matches[1] }
        if ($s -match 'applaunch\s+(\d+)')  { return $Matches[1] }
    }
    return $null
}

function Set-ShortcutIcon {
    param($Sc, [string]$ExePath)
    if ($Sc.Type -eq 'lnk') {
        # .lnk: use the Windows Scripting Host COM object
        $shell = New-Object -ComObject WScript.Shell
        $s = $shell.CreateShortcut($Sc.Path)
        $s.IconLocation = "$ExePath,0"
        $s.Save()
    } elseif ($Sc.Type -eq 'url') {
        # .url: plain INI file, rewrite IconFile / IconIndex fields
        $lines = Get-Content -LiteralPath $Sc.Path
        $new = New-Object System.Collections.Generic.List[string]
        $hasF = $false; $hasI = $false
        foreach ($l in $lines) {
            if ($l -like 'IconFile=*')  { $new.Add("IconFile=$ExePath");  $hasF = $true; continue }
            if ($l -like 'IconIndex=*') { $new.Add("IconIndex=0");        $hasI = $true; continue }
            $new.Add($l)
        }
        if (-not $hasF) { $new.Add("IconFile=$ExePath") }
        if (-not $hasI) { $new.Add("IconIndex=0") }
        Set-Content -LiteralPath $Sc.Path -Value $new -Encoding ASCII
    }
}

# =============================================================================
#  MAIN
# =============================================================================
Write-Title "Fix Steam Icons"

Write-Section "Reading Steam libraries"
$SteamLibraries | ForEach-Object { Write-Host "  - $_" }

$games = Get-InstalledGames -Libraries $SteamLibraries
Write-Host ("Games detected: {0}" -f $games.Count) -ForegroundColor Green
if ($games.Count -eq 0) {
    Write-Host "No games found. Check the paths at the top of the script." -ForegroundColor Red
    Read-Host "Press Enter to exit"; return
}

$byAppId = @{}
foreach ($g in $games) { $byAppId[$g.AppId] = $g }

Write-Section "Scanning desktop shortcuts"
$shortcuts = @(Get-SteamShortcuts)
Write-Host ("Steam-like shortcuts: {0}" -f $shortcuts.Count)

Write-Section "Resolving .exe and applying icons"
$results = New-Object System.Collections.Generic.List[object]

foreach ($sc in $shortcuts) {
    $appid = Get-AppIdFromShortcut -Sc $sc
    $row = [ordered]@{ Shortcut=$sc.Name; AppId=$appid; Status=''; Exe='' }

    if (-not $appid) { $row.Status = 'no appid (skipped)'; $results.Add([PSCustomObject]$row); continue }
    $game = $byAppId[$appid]
    if (-not $game)        { $row.Status = "appid $appid not installed"; $results.Add([PSCustomObject]$row); continue }
    if (-not $game.Exists) { $row.Status = "install folder missing";     $results.Add([PSCustomObject]$row); continue }

    $cands = @(Get-MainExe -InstallPath $game.InstallPath -GameName $game.Name)
    if ($cands.Count -eq 0) { $row.Status = 'no .exe found'; $results.Add([PSCustomObject]$row); continue }

    $best = $cands[0]
    $ambig = $false
    if ($cands.Count -gt 1 -and ($best.Score - $cands[1].Score) -lt 8) { $ambig = $true }

    $chosen = $best
    if ($ambig) {
        Write-Host ""
        Write-Host ("Tie for {0} (appid {1}):" -f $game.Name, $appid) -ForegroundColor Yellow
        $top = $cands | Select-Object -First 5
        $i = 0
        foreach ($c in $top) {
            $i++
            Write-Host ("  [{0}] score={1,3} size={2,8:N0}KB  {3}" -f $i, $c.Score, ($c.Size/1KB), $c.Rel)
        }
        $sel = Read-Host ("Pick [1-{0}], empty=1, 's'=skip" -f $top.Count)
        if ($sel -match '^(s|skip)$') { $row.Status = 'skipped'; $results.Add([PSCustomObject]$row); continue }
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '1' }
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $top.Count) { $chosen = $top[$idx] }
    }

    try {
        Set-ShortcutIcon -Sc $sc -ExePath $chosen.Path
        $row.Status = 'OK'; $row.Exe = $chosen.Rel
    } catch {
        $row.Status = "error: $($_.Exception.Message)"
    }
    $results.Add([PSCustomObject]$row)
}

# ---------- AGGRESSIVE REFRESH -----------------------------------------------
Write-Section "Forcing Windows icon refresh"

# 1) Tell the shell that icon associations changed
Add-Type -Namespace ShNative -Name Shell32 -MemberDefinition @"
[DllImport("shell32.dll", CharSet=CharSet.Auto)]
public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
"@
[ShNative.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
Write-Host "  SHCNE_ASSOCCHANGED fired." -ForegroundColor DarkGray

# 2) Bump the LastWriteTime of each touched shortcut
foreach ($r in $results) {
    if ($r.Status -ne 'OK') { continue }
    $sc = $shortcuts | Where-Object { $_.Name -eq $r.Shortcut } | Select-Object -First 1
    if (-not $sc) { continue }
    try {
        (Get-Item -LiteralPath $sc.Path).LastWriteTime = Get-Date
        Write-Host "  touch: $($sc.Name)" -ForegroundColor DarkGray
    } catch {}
}

# 3) Rename-trick on .lnk files. Renaming to a temp name and back breaks
#    any path-keyed icon caching the shell may still be holding onto.
foreach ($r in $results) {
    if ($r.Status -ne 'OK') { continue }
    $sc = $shortcuts | Where-Object { $_.Name -eq $r.Shortcut } | Select-Object -First 1
    if (-not $sc -or $sc.Type -ne 'lnk') { continue }
    try {
        $dir  = Split-Path $sc.Path -Parent
        $ext  = [IO.Path]::GetExtension($sc.Path)
        $base = [IO.Path]::GetFileNameWithoutExtension($sc.Path)
        $tmp  = Join-Path $dir ("{0}__tmp_{1}{2}" -f $base, [guid]::NewGuid().ToString('N').Substring(0,6), $ext)
        Rename-Item -LiteralPath $sc.Path -NewName (Split-Path $tmp -Leaf) -Force
        Start-Sleep -Milliseconds 150
        Rename-Item -LiteralPath $tmp -NewName (Split-Path $sc.Path -Leaf) -Force
        Write-Host "  rename-trick: $($sc.Name)" -ForegroundColor DarkGray
    } catch {
        Write-Host "  rename-trick failed: $($sc.Name)" -ForegroundColor DarkYellow
    }
}

# 4) Clear icon/thumbnail caches and restart Explorer
try { Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue } catch {}
Start-Sleep 1

$paths = @(
    "$env:LOCALAPPDATA\IconCache.db",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db",
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db"
)
foreach ($p in $paths) {
    Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item $_.FullName -Force -ErrorAction Stop
            Write-Host "  deleted: $($_.FullName)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  locked:  $($_.FullName)" -ForegroundColor DarkYellow
        }
    }
}

Start-Process explorer.exe
Start-Sleep 2
try { & ie4uinit.exe -show } catch {}
[ShNative.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Section "Summary"
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host

Write-Host "Done." -ForegroundColor Green
Write-Host "If an icon still looks stale, press F5 on the Desktop or reboot." -ForegroundColor DarkGray
Read-Host "Press Enter to exit"
