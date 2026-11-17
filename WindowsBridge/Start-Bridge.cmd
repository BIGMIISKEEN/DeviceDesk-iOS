@echo off
setlocal
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
 echo Follow SETUP.md to create the Python environment first.
 pause
 exit /b 1
)
".venv\Scripts\python.exe" bridge.py --config config.json
if errorlevel 1 pause
