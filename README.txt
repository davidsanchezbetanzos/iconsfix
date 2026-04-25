FIX STEAM ICONS - Single script
===============================

Contents:
  - RUN.bat                 -> double-click to launch.
  - fix-steam-icons.en.ps1  -> the script (edit to change library paths).
  - README.txt              -> this file.

Flow (won't ask anything except on .exe ties):
  1. Reads appmanifest_*.acf from your Steam libraries and extracts
     appid, name, and installdir for each installed game.
  2. Scans desktop shortcuts (.lnk and .url).
  3. For every Steam-like shortcut:
       - pulls the appid from the target/arguments
       - matches it against your installed games
       - locates the main .exe via heuristic
       - points the shortcut's icon at that .exe
     If a game has tied .exe candidates, it shows the top 5 and
     asks you to pick (empty = 1, 's' = skip).
  4. Forces a visual refresh: SHChangeNotify + touch of each .lnk
     + rename-trick to break path-keyed caching + IconCache and
     thumbcache purge + Explorer restart.
  5. Prints a summary with the status of every shortcut.

Configured libraries:
  F:\SteamLibrary
  E:\SteamLibrary
  D:\SteamLibrary

To add/change libraries: open fix-steam-icons.en.ps1 in Notepad and
edit the $SteamLibraries array at the top of the file.

Status values in the summary:
  OK                        -> icon assigned successfully
  no appid (skipped)        -> not a game shortcut (e.g. Steam itself)
  appid N not installed     -> no manifest for that appid in your libs
  install folder missing    -> manifest points to a deleted folder
  no .exe found             -> no executables found in the folder
  skipped                   -> you skipped it at the tie prompt
  error: ...                -> save failed, usually a permissions issue
