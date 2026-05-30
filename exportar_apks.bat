@echo off
REM ============================================================
REM Exporta ambos APK por linea de comandos con Godot 4.6.3.
REM   - build\Simulador.apk        (visor VR, para el Quest)
REM   - build\SimuladorTablet.apk  (control, para el celular/tablet)
REM Uso: doble clic, o ejecutar desde la terminal en la raiz del proyecto.
REM ============================================================
setlocal
set GODOT="C:\Users\jvare\Godot_v4.6.3\Godot_v4.6.3-stable_win64.exe"
cd /d "%~dp0"
if not exist build mkdir build

echo [1/2] Exportando visor VR (Simulador.apk)...
%GODOT% --headless --path . --export-debug "Android" build/Simulador.apk

echo [2/2] Exportando control celular/tablet (SimuladorTablet.apk)...
%GODOT% --headless --path . --export-debug "AndroidTablet" build/SimuladorTablet.apk

echo.
echo Listo. APKs en la carpeta build\
dir build\*.apk
endlocal
pause
