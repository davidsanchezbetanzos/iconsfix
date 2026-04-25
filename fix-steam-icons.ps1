# =============================================================================
#  Fix Steam Icons - Script unico
#  Autor: Claude (Cowork) para Davs
# -----------------------------------------------------------------------------
#  Que hace, en orden, sin preguntarte nada salvo en caso de empate de .exe:
#    1. Lee los appmanifest_*.acf de las librerias configuradas y extrae
#       (appid, nombre, installdir) de cada juego instalado.
#    2. Escanea accesos directos (.lnk y .url) del Escritorio.
#    3. Para cada uno tipo Steam: saca el appid, localiza el .exe principal
#       y le asigna ese .exe como icono. Solo pregunta en caso de empate.
#    4. Fuerza el refresco visual (SHChangeNotify + touch + rename-trick +
#       limpieza de cache + reinicio de Explorer).
#    5. Muestra un resumen.
# =============================================================================

# ---------- CONFIGURACION ----------------------------------------------------
$SteamLibraries = @(
    'F:\SteamLibrary',
    'E:\SteamLibrary',
    'D:\SteamLibrary'
)

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

# ---------- PARSEO ACF -------------------------------------------------------
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
            Write-Host "  [aviso] no existe: $sa" -ForegroundColor DarkYellow
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

# ---------- HEURISTICA .EXE --------------------------------------------------
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

# ---------- ESCANEO DE SHORTCUTS ---------------------------------------------
function Get-SteamShortcuts {
    $desktops = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $shell = New-Object -ComObject WScript.Shell
    $items = @()
    foreach ($desk in $desktops) {
        Get-ChildItem -Path $desk -Filter *.lnk -File -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $sc = $shell.CreateShortcut($_.FullName)
                $items += [PSCustomObject]@{
                    Type='lnk'; Name=$_.BaseName; Path=$_.FullName
                    Target=$sc.TargetPath; Arguments=$sc.Arguments; IconLocation=$sc.IconLocation
                }
            } catch {}
        }
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
        $shell = New-Object -ComObject WScript.Shell
        $s = $shell.CreateShortcut($Sc.Path)
        $s.IconLocation = "$ExePath,0"
        $s.Save()
    } elseif ($Sc.Type -eq 'url') {
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
#  EJECUCION
# =============================================================================
Write-Title "Fix Steam Icons"

Write-Section "Leer librerias de Steam"
$SteamLibraries | ForEach-Object { Write-Host "  - $_" }

$games = Get-InstalledGames -Libraries $SteamLibraries
Write-Host ("Juegos detectados: {0}" -f $games.Count) -ForegroundColor Green
if ($games.Count -eq 0) {
    Write-Host "No se han encontrado juegos. Revisa las rutas al inicio del script." -ForegroundColor Red
    Read-Host "Enter para salir"; return
}

$byAppId = @{}
foreach ($g in $games) { $byAppId[$g.AppId] = $g }

Write-Section "Accesos directos del Escritorio"
$shortcuts = @(Get-SteamShortcuts)
Write-Host ("Accesos directos tipo Steam: {0}" -f $shortcuts.Count)

Write-Section "Resolver .exe y aplicar iconos"
$results = New-Object System.Collections.Generic.List[object]

foreach ($sc in $shortcuts) {
    $appid = Get-AppIdFromShortcut -Sc $sc
    $row = [ordered]@{ Acceso=$sc.Name; AppId=$appid; Estado=''; Exe='' }

    if (-not $appid) { $row.Estado = 'sin appid (se ignora)'; $results.Add([PSCustomObject]$row); continue }
    $game = $byAppId[$appid]
    if (-not $game)          { $row.Estado = "appid $appid no instalado"; $results.Add([PSCustomObject]$row); continue }
    if (-not $game.Exists)   { $row.Estado = "carpeta no existe";         $results.Add([PSCustomObject]$row); continue }

    $cands = @(Get-MainExe -InstallPath $game.InstallPath -GameName $game.Name)
    if ($cands.Count -eq 0)  { $row.Estado = 'sin .exe';                  $results.Add([PSCustomObject]$row); continue }

    $best = $cands[0]
    $ambig = $false
    if ($cands.Count -gt 1 -and ($best.Score - $cands[1].Score) -lt 8) { $ambig = $true }

    $chosen = $best
    if ($ambig) {
        Write-Host ""
        Write-Host ("Empate para {0} (appid {1}):" -f $game.Name, $appid) -ForegroundColor Yellow
        $top = $cands | Select-Object -First 5
        $i = 0
        foreach ($c in $top) {
            $i++
            Write-Host ("  [{0}] score={1,3} size={2,8:N0}KB  {3}" -f $i, $c.Score, ($c.Size/1KB), $c.Rel)
        }
        $sel = Read-Host ("Numero [1-{0}], vacio=1, 's'=saltar" -f $top.Count)
        if ($sel -match '^(s|skip)$') { $row.Estado = 'saltado'; $results.Add([PSCustomObject]$row); continue }
        if ([string]::IsNullOrWhiteSpace($sel)) { $sel = '1' }
        $idx = [int]$sel - 1
        if ($idx -ge 0 -and $idx -lt $top.Count) { $chosen = $top[$idx] }
    }

    try {
        Set-ShortcutIcon -Sc $sc -ExePath $chosen.Path
        $row.Estado = 'OK'; $row.Exe = $chosen.Rel
    } catch {
        $row.Estado = "error: $($_.Exception.Message)"
    }
    $results.Add([PSCustomObject]$row)
}

# ---------- REFRESCO AGRESIVO ------------------------------------------------
Write-Section "Forzar refresco visual de Windows"

Add-Type -Namespace ShNative -Name Shell32 -MemberDefinition @"
[DllImport("shell32.dll", CharSet=CharSet.Auto)]
public static extern void SHChangeNotify(int wEventId, int uFlags, IntPtr dwItem1, IntPtr dwItem2);
"@
[ShNative.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
Write-Host "  SHCNE_ASSOCCHANGED lanzado." -ForegroundColor DarkGray

foreach ($r in $results) {
    if ($r.Estado -ne 'OK') { continue }
    $sc = $shortcuts | Where-Object { $_.Name -eq $r.Acceso } | Select-Object -First 1
    if (-not $sc) { continue }
    try {
        (Get-Item -LiteralPath $sc.Path).LastWriteTime = Get-Date
        Write-Host "  touch: $($sc.Name)" -ForegroundColor DarkGray
    } catch {}
}

foreach ($r in $results) {
    if ($r.Estado -ne 'OK') { continue }
    $sc = $shortcuts | Where-Object { $_.Name -eq $r.Acceso } | Select-Object -First 1
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
        Write-Host "  rename-trick fallido: $($sc.Name)" -ForegroundColor DarkYellow
    }
}

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
            Write-Host "  borrado: $($_.FullName)" -ForegroundColor DarkGray
        } catch {
            Write-Host "  bloqueado: $($_.FullName)" -ForegroundColor DarkYellow
        }
    }
}

Start-Process explorer.exe
Start-Sleep 2
try { & ie4uinit.exe -show } catch {}
[ShNative.Shell32]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Section "Resumen"
$results | Format-Table -AutoSize -Wrap | Out-String | Write-Host

Write-Host "Hecho." -ForegroundColor Green
Write-Host "Si algun icono tarda, pulsa F5 en el Escritorio o reinicia." -ForegroundColor DarkGray
Read-Host "Enter para salir"
