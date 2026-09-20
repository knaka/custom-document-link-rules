@REM Downloads and executes Mise in a project where contributors may not have mise installed.
@REM — Home | mise-en-place https://mise.jdx.dev/

@REM Releases · jdx/mise https://github.com/jdx/mise/releases
@set ver=2026.8.6

@echo off
setlocal enabledelayedexpansion

if "%PROCESSOR_ARCHITECTURE%" == "AMD64" (
  set mise_arch=x64
) else if "%PROCESSOR_ARCHITECTURE%" == "ARM64" (
  set mise_arch=arm64
) else (
  echo ERROR: Unexpected architecture "%PROCESSOR_ARCHITECTURE%". >&2
  exit /b 1 
)

set cache_dir_path=%USERPROFILE%\.cache\mise
if not exist !cache_dir_path! (
  mkdir "!cache_dir_path!"
)
set cmd_path=!cache_dir_path!\mise-%ver%.exe
if not exist !cmd_path! (
  echo Downloading Mise for Windows. >&2
  curl.exe --fail --location --output "!cmd_path!" https://github.com/jdx/mise/releases/download/v!ver!/mise-v!ver!-windows-!mise_arch!.exe || exit /b !ERRORLEVEL!
)
!cmd_path! %* || exit /b !ERRORLEVEL!

endlocal ^
& "%cmd_path%" %* || exit /b %ERRORLEVEL%
