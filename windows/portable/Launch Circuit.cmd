@echo off
setlocal
set "HERE=%~dp0"
set "TARGET=%~1"
if not defined TARGET set /p "TARGET=Folder to inspect: "
if not defined TARGET exit /b 2
rem Start the local service in its own console window; closing that window stops Circuit.
start "Black Label Circuit" "%HERE%BlackLabelCircuit.exe" "%TARGET%"
rem Give the service a moment to bind 127.0.0.1:8923, then open the buyer interface.
timeout /t 3 /nobreak >nul
start "" "http://127.0.0.1:8923/"
endlocal
