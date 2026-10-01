@echo off
rem Opens the Smart Teacher web admin dashboard at http://localhost:8765/ in a couple of seconds.
rem
rem It serves a PRE-BUILT copy (build\web), so there is no compile wait. If that copy is
rem missing, or you have changed the app's code and want the changes in it, run:
rem     admin_dashboard.bat rebuild
rem (a rebuild takes a few minutes; the normal start does not).
cd /d "%~dp0"
set PATH=%PATH%;C:\flutter\bin

if /I "%1"=="rebuild" goto build
if not exist build\web\index.html goto build
goto serve

:build
echo Building the web admin dashboard - this takes a few minutes, once...
call flutter build web --release -t lib/main_web.dart
if errorlevel 1 (
  echo Build failed - see the messages above.
  pause
  exit /b 1
)

:serve
echo Serving the dashboard at http://localhost:8765/  (close this window to stop it)
start "" http://localhost:8765/
py -3 -m http.server 8765 --directory build\web
