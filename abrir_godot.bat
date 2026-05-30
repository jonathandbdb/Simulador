@echo off
REM ============================================================
REM Abre ESTE proyecto con Godot 4.6.3 (la version cuyo Android
REM build template esta instalado). Usar SIEMPRE esta version
REM para evitar el error "Android build version mismatch".
REM ============================================================
set GODOT="C:\Users\jvare\Godot_v4.6.3\Godot_v4.6.3-stable_win64.exe"
start "" %GODOT% --path "%~dp0" --editor
