#!/bin/bash
# World Boss Announcer - Bridge Launcher (macOS)
# Double-click this file to start the bridge

# Change to the directory where this script is located
cd "$(dirname "$0")"

echo "========================================"
echo "  World Boss Announcer - Bridge"
echo "========================================"
echo ""

# Check if Python 3 is installed
if ! command -v python3 &> /dev/null; then
    echo "ERROR: Python 3 is not installed."
    echo "Please install Python 3 from https://www.python.org/downloads/"
    echo ""
    read -p "Press Enter to exit..."
    exit 1
fi

# Check if requests module is installed
if ! python3 -c "import requests" &> /dev/null; then
    echo "Installing required packages..."
    pip3 install requests
    echo ""
fi

# Check if config is set
if grep -q 'CHAT_LOG_PATH": ""' bridge.py; then
    echo "ERROR: CHAT_LOG_PATH is not configured!"
    echo ""
    echo "Please edit bridge.py and set your WoWChatLog.txt path:"
    echo "  macOS: /Applications/World of Warcraft/_classic_/Logs/WoWChatLog.txt"
    echo ""
    read -p "Press Enter to exit..."
    exit 1
fi

# Run the bridge
python3 bridge.py

# Keep window open if bridge exits
echo ""
read -p "Press Enter to exit..."
