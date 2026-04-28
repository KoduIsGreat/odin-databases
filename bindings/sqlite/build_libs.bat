@echo off
REM Builds a static SQLite library for Windows amd64 into lib\windows_amd64\sqlite3.lib.
REM Run from a "x64 Native Tools Command Prompt for VS" so that cl.exe and lib.exe are on PATH.

setlocal
cd /d %~dp0

set OUTDIR=lib\windows_amd64
if not exist %OUTDIR% mkdir %OUTDIR%

set CFLAGS=/O2 /MT /nologo ^
  /DSQLITE_ENABLE_FTS5 ^
  /DSQLITE_ENABLE_JSON1 ^
  /DSQLITE_ENABLE_RTREE ^
  /DSQLITE_ENABLE_COLUMN_METADATA ^
  /DSQLITE_THREADSAFE=1 ^
  /DSQLITE_DEFAULT_FOREIGN_KEYS=1

echo ^>^> Compiling sqlite3.c
cl %CFLAGS% /c src\sqlite3.c /Fo%OUTDIR%\sqlite3.obj || exit /b 1

echo ^>^> Archiving sqlite3.lib
lib /nologo /OUT:%OUTDIR%\sqlite3.lib %OUTDIR%\sqlite3.obj || exit /b 1
del %OUTDIR%\sqlite3.obj

echo Done: %OUTDIR%\sqlite3.lib
