@echo off
REM Boney World Bosses - Bridge Launcher (Windows)
REM Double-click this file to start the bridge

cd /d "%~dp0"

echo ========================================
echo   Boney World Bosses - Bridge
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

REM Check if GUILD_ID is set
findstr /C:"GUILD_ID" bridge.py | findstr /C:": \"\"," >nul 2>&1
if not errorlevel 1 (
    echo ERROR: GUILD_ID is not configured!
    echo.
    echo Please edit bridge.py and set your Discord server ID.
    echo Right-click your server in Discord ^> Copy Server ID
    echo.
    pause
    exit /b 1
)

REM Run the bridge
python bridge.py

REM Keep window open if bridge exits
echo.
pause
