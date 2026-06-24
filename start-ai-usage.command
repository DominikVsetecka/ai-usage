#!/bin/zsh

set -u

PROJECT_DIR="${0:A:h}"

cd "$PROJECT_DIR" || {
  echo "Could not open project directory:"
  echo "$PROJECT_DIR"
  echo
  read -r "?Press Enter to close..."
  exit 1
}

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift was not found."
  echo "Install Xcode Command Line Tools first:"
  echo "  xcode-select --install"
  echo
  read -r "?Press Enter to close..."
  exit 1
fi

echo "Starting AI Usage..."
echo "Project: $PROJECT_DIR"
echo

swift run AIUsage
STATUS=$?

echo
if [ "$STATUS" -eq 0 ]; then
  echo "AI Usage exited."
else
  echo "AI Usage failed with exit code $STATUS."
fi

echo
if [ "${AI_USAGE_NO_PAUSE:-0}" != "1" ] && [ -t 0 ]; then
  read -r "?Press Enter to close..."
fi
exit "$STATUS"
