@echo off
REM World Boss Announcer - Bridge Launcher (Windows)
REM Double-click this file to start the bridge

cd /d "%~dp0"

echo ========================================
echo   World Boss Announcer - Bridge
echo ========================================
echo.

REM Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo ERROR: Python is not installed.
    echo Please install Python from https://www.python.org/downloads/
    echo Make sure to check "Add Python to PATH" during installation.
    echo.
    pause
    exit /b 1
)

REM Check if requests module is installed
python -c "import requests" >nul 2>&1
if errorlevel 1 (
    echo Installing required packages...
    pip install requests
    echo.
)

REM Check if config is set (look for empty LOGS_DIR)
findstr /C:"LOGS_DIR" bridge.py | findstr /C:": \"\"," >nul 2>&1
if not errorlevel 1 (
    echo ERROR: LOGS_DIR is not configured!
    echo.
    echo Please edit bridge.py and set your WoW Logs directory:
    echo   Windows: C:\Program Files\World of Warcraft\_anniversary_\Logs
    echo.
    pause
    exit /b 1
)

REM Run the bridge
python bridge.py

REM Keep window open if bridge exits
echo.
pause
