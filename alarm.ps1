#requires -Version 5.1
<#
.SYNOPSIS
  Alarm-bell notification system for Claude Code hooks.

.DESCRIPTION
  Plays a looping, hard-to-ignore sound when a long turn finishes ("done") or
  when Claude is blocked waiting on you ("needs-input").

  Dismissal, in order of convenience:
    * Focus the Claude terminal window       -> alarm stops
    * Click the tray notification            -> terminal surfaces, alarm stops
    * Type anything into Claude              -> UserPromptSubmit kills it
    * Wait $ALARM_SECONDS                    -> gives up on its own

  Only one alarm ever runs at a time; starting a new one kills the previous.

.PARAMETER Action
  start                : record turn start timestamp + kill any running alarm
  stop                 : kill any running alarm (you're awake)
  done                 : fire the "done" alarm, gated on turn duration
  needs-input          : fire the "needs input" alarm, no gate
  banner-done          : print terminalSequence JSON for "done" (gated)
  banner-needs-input   : print terminalSequence JSON for "needs input"
  test-done            : fire "done" alarm ignoring the duration gate
  test-needs-input     : fire "needs input" alarm
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateSet('start', 'stop', 'done', 'needs-input',
               'banner-done', 'banner-needs-input',
               'test-done', 'test-needs-input')]
  [string]$Action
)

# ==========================================================================
#  CONFIG -- edit these
# ==========================================================================

# Master switch. Set to $false to silence every alarm without touching settings.json.
$ENABLED = $true

# A "done" alarm only fires if the turn took longer than this many seconds.
# Short turns stay silent. Does NOT apply to "needs-input" alarms.
$MIN_TURN_SECONDS = 60

# Maximum time an alarm keeps looping before giving up, in seconds.
$ALARM_SECONDS = 20

# Sound files. Verified present on this machine.
#   Alarm03.wav ~4.1s -- rising alarm tone, used for "turn finished"
#   Ring01.wav  ~5.8s -- phone ring, used for "blocked, needs you"
$SOUND_DONE        = 'C:\Windows\Media\Alarm03.wav'
$SOUND_NEEDS_INPUT = 'C:\Windows\Media\Ring01.wav'

# Focusing the Claude terminal stops the alarm. This is the delay before that
# watcher arms, so an alarm that fires while you are already at the keyboard
# still makes a noise instead of being silently swallowed. Set to 0 to have
# the alarm never sound while the terminal is already focused.
$FOREGROUND_ARM_DELAY_MS = 1500

# How often the dismiss-watcher polls (also the tray-click response time).
$POLL_INTERVAL_MS = 150

# Flash the terminal's taskbar button while the alarm sounds.
$FLASH_TASKBAR = $true

# Turn-timestamp files are written one per Claude session and are worthless once
# the session ends. Anything older than this many days is pruned on next use.
$STATE_RETENTION_DAYS = 7

# Text shown in the tray balloon and the terminal title bar.
$TITLE_DONE        = 'Claude Code'
$BODY_DONE         = 'Turn finished.'
$TITLE_NEEDS_INPUT = 'Claude Code'
$BODY_NEEDS_INPUT  = 'Blocked -- needs your input.'

# Marker written into the terminal title by the banner hooks, and searched for
# by the alarm to locate its own window. Must match between the two.
$TITLE_MARKER = '(!) Claude'

# ==========================================================================
#  End of config
# ==========================================================================

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off

$StateDir = Join-Path $PSScriptRoot '.alarm-state'
$PidFile  = Join-Path $StateDir 'alarm.pid'

function Initialize-StateDir {
  if (-not (Test-Path -LiteralPath $StateDir)) {
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
  }
}

# Claude Code hands each hook a JSON blob on stdin. session_id keeps concurrent
# Claude sessions from clobbering each other's turn timestamps, and gives each
# window a distinct title marker. Guarded: never block if stdin isn't redirected.
function Get-SessionKey {
  $key = 'default'
  try {
    if ([Console]::IsInputRedirected) {
      $raw = [Console]::In.ReadToEnd()
      if ($raw) {
        $obj = $raw | ConvertFrom-Json
        if ($obj.session_id) {
          $key = ($obj.session_id -replace '[^A-Za-z0-9_-]', '')
          if (-not $key) { $key = 'default' }
        }
      }
    }
  } catch { $key = 'default' }
  return $key
}

# Short, human-tolerable window tag: first 8 chars of the session id.
function Get-SessionTag { param([string]$Key)
  if ($Key.Length -gt 8) { return $Key.Substring(0, 8) } else { return $Key }
}

function Get-TurnFile { param([string]$Key) Join-Path $StateDir "turn-$Key.txt" }

# One turn file is created per Claude session and nothing else ever removes them,
# so without this they accumulate indefinitely. Session ids are also the only
# identifying data this script stores, so expiring them is worth doing on its own.
function Remove-StaleTurnFiles {
  try {
    $cutoff = (Get-Date).AddDays(-$STATE_RETENTION_DAYS)
    Get-ChildItem -LiteralPath $StateDir -Filter 'turn-*.txt' -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt $cutoff } |
      ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
  } catch { }
}

# --------------------------------------------------------------------------
#  Win32 interop: locate, flash and raise the terminal window.
# --------------------------------------------------------------------------
function Initialize-Win32 {
  if ('ClaudeAlarmWin' -as [type]) { return }
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class ClaudeAlarmWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  [DllImport("user32.dll")] static extern bool FlashWindowEx(ref FLASHWINFO i);
  [DllImport("user32.dll")] static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);

  delegate bool EnumProc(IntPtr h, IntPtr p);

  [StructLayout(LayoutKind.Sequential)]
  struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }

  // Returns "hwnd|title" for every visible titled top-level window.
  public static List<string> Windows() {
    var r = new List<string>();
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(512);
      GetWindowText(h, sb, 512);
      if (sb.Length > 0) r.Add(h.ToInt64() + "|" + sb.ToString());
      return true;
    }, IntPtr.Zero);
    return r;
  }

  public static void Flash(IntPtr h, bool on) {
    var i = new FLASHWINFO();
    i.cbSize = (uint)Marshal.SizeOf(i);
    i.hwnd = h;
    i.dwFlags = on ? (uint)0x0000000F : (uint)0;  // FLASHW_ALL|FLASHW_TIMERNOFG : FLASHW_STOP
    i.uCount = on ? uint.MaxValue : 0;
    i.dwTimeout = 0;
    FlashWindowEx(ref i);
  }

  // Raising a window from a background process is restricted by Windows.
  // Nudging a modifier key first releases the foreground lock.
  public static void Raise(IntPtr h) {
    try {
      AllowSetForegroundWindow(-1);
      keybd_event(0x12, 0, 0, UIntPtr.Zero);        // ALT down
      keybd_event(0x12, 0, 0x0002, UIntPtr.Zero);   // ALT up
      if (IsIconic(h)) ShowWindow(h, 9);            // SW_RESTORE
      SetForegroundWindow(h);
    } catch { }
  }
}
'@
}

# Find the terminal window belonging to THIS Claude session.
#   1. exact marker + session tag  (set by the paired banner hook)
#   2. any window carrying the marker
#   3. any titled window mentioning Claude
# Returns [IntPtr]::Zero when nothing matches, in which case the alarm still
# sounds -- it just can't be dismissed by focus.
function Find-TerminalWindow {
  param([string]$Tag)
  Initialize-Win32
  $wins = [ClaudeAlarmWin]::Windows()
  foreach ($pass in 1, 2, 3) {
    foreach ($w in $wins) {
      $parts = $w -split '\|', 2
      $hwnd  = [IntPtr][int64]$parts[0]
      $title = $parts[1]
      switch ($pass) {
        1 { if ($title -like "*$TITLE_MARKER*" -and $title -like "*$Tag*") { return $hwnd } }
        2 { if ($title -like "*$TITLE_MARKER*")                            { return $hwnd } }
        3 { if ($title -like '*Claude*')                                   { return $hwnd } }
      }
    }
  }
  return [IntPtr]::Zero
}

# Kill a previously running alarm so alarms never stack.
# Guards against PID reuse by matching both process name and start time.
function Stop-RunningAlarm {
  if (-not (Test-Path -LiteralPath $PidFile)) { return }
  try {
    $parts      = (Get-Content -LiteralPath $PidFile -Raw).Trim() -split '\|'
    $oldPid     = [int]$parts[0]
    $startTicks = if ($parts.Count -gt 1) { [long]$parts[1] } else { 0 }
    if ($oldPid -ne $PID) {
      $p = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
      if ($p -and $p.ProcessName -match '^(powershell|pwsh)$' -and
          ($startTicks -eq 0 -or $p.StartTime.Ticks -eq $startTicks)) {
        Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
      }
    }
  } catch { }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

# If we have no timestamp (fresh install, resumed session) stay silent rather
# than fire a spurious alarm.
function Test-TurnWasLong {
  param([string]$Key)
  $f = Get-TurnFile -Key $Key
  if (-not (Test-Path -LiteralPath $f)) { return $false }
  try {
    $startMs   = [long]((Get-Content -LiteralPath $f -Raw).Trim())
    $elapsedMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $startMs
    return ($elapsedMs -ge ($MIN_TURN_SECONDS * 1000))
  } catch { return $false }
}

function Invoke-Alarm {
  param([string]$Wav, [string]$Title, [string]$Body, [string]$Tag)

  if (-not $ENABLED) { return }

  Initialize-StateDir
  Stop-RunningAlarm
  Initialize-Win32

  try {
    $selfStart = (Get-Process -Id $PID).StartTime.Ticks
    Set-Content -LiteralPath $PidFile -Value "$PID|$selfStart" -Encoding ascii
  } catch { }

  $hwnd = Find-TerminalWindow -Tag $Tag

  # Shared dismissal flag, flipped by the tray-click handlers.
  $state = [hashtable]::Synchronized(@{ Dismissed = $false })

  $icon = $null
  try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop

    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon            = [System.Drawing.SystemIcons]::Exclamation
    $icon.BalloonTipTitle = $Title
    $icon.BalloonTipText  = "$Body  (click to open)"
    $icon.Text            = "$Title - $Body"
    $icon.Visible         = $true

    # Clicking the balloon OR the tray icon: surface the terminal, stop the alarm.
    $onClick = {
      $state.Dismissed = $true
      if ($hwnd -ne [IntPtr]::Zero) { [ClaudeAlarmWin]::Raise($hwnd) }
    }.GetNewClosure()

    $icon.add_BalloonTipClicked($onClick)
    $icon.add_Click($onClick)
    $icon.ShowBalloonTip(10000)
  } catch { $icon = $null }

  if ($FLASH_TASKBAR -and $hwnd -ne [IntPtr]::Zero) {
    try { [ClaudeAlarmWin]::Flash($hwnd, $true) } catch { }
  }

  # PlayLooping (not PlaySync) so the sound is continuous but interruptible
  # within $POLL_INTERVAL_MS rather than at the end of a 4-6 second clip.
  $player = $null
  if (Test-Path -LiteralPath $Wav) {
    try { $player = New-Object System.Media.SoundPlayer $Wav; $player.Load(); $player.PlayLooping() } catch { $player = $null }
  }

  $sw       = [Diagnostics.Stopwatch]::StartNew()
  $deadline = $ALARM_SECONDS * 1000

  try {
    while ($sw.ElapsedMilliseconds -lt $deadline) {

      # Pump the message loop so tray click events actually fire.
      try { [System.Windows.Forms.Application]::DoEvents() } catch { }

      if ($state.Dismissed) { break }

      # Focusing the Claude terminal dismisses the alarm, once the watcher arms.
      if ($hwnd -ne [IntPtr]::Zero -and $sw.ElapsedMilliseconds -ge $FOREGROUND_ARM_DELAY_MS) {
        if ([ClaudeAlarmWin]::GetForegroundWindow() -eq $hwnd) { break }
      }

      if (-not $player) {
        # Fallback: no usable wav -> console beep instead of silence.
        [Console]::Beep(880, 300)
      }

      Start-Sleep -Milliseconds $POLL_INTERVAL_MS
    }
  } catch { } finally {
    if ($player) { try { $player.Stop() } catch { } }
    if ($hwnd -ne [IntPtr]::Zero) { try { [ClaudeAlarmWin]::Flash($hwnd, $false) } catch { } }
    if ($icon) { try { $icon.Visible = $false; $icon.Dispose() } catch { } }
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  }
}

# Emits a Claude Code hook JSON payload carrying allowlisted terminal escapes.
#   OSC 9 -> Windows Terminal / ConEmu / WezTerm desktop notification
#   OSC 0 -> window+icon title; also the marker the alarm uses to find this window
function Write-BannerJson {
  param([string]$Title, [string]$Body, [string]$Tag)
  $esc = [char]27
  $bel = [char]7
  $seq = "$esc]9;$Title`: $Body$bel$esc]0;$TITLE_MARKER $Tag - $Body$bel"
  [pscustomobject]@{
    terminalSequence = $seq
    suppressOutput   = $true
  } | ConvertTo-Json -Compress
}

$key = $null
switch ($Action) {

  'start' {
    # User typed something: they're awake. Kill any alarm and stamp the turn.
    Initialize-StateDir
    Stop-RunningAlarm
    Remove-StaleTurnFiles
    $key = Get-SessionKey
    Set-Content -LiteralPath (Get-TurnFile -Key $key) `
                -Value ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Encoding ascii
  }

  'stop' { Stop-RunningAlarm }

  'done' {
    $key = Get-SessionKey
    if (Test-TurnWasLong -Key $key) {
      Invoke-Alarm -Wav $SOUND_DONE -Title $TITLE_DONE -Body $BODY_DONE -Tag (Get-SessionTag $key)
    }
  }

  'needs-input' {
    # No duration gate: if Claude is blocked on you, you want to know now.
    $key = Get-SessionKey
    Invoke-Alarm -Wav $SOUND_NEEDS_INPUT -Title $TITLE_NEEDS_INPUT -Body $BODY_NEEDS_INPUT -Tag (Get-SessionTag $key)
  }

  'banner-done' {
    $key = Get-SessionKey
    if ($ENABLED -and (Test-TurnWasLong -Key $key)) {
      Write-BannerJson -Title $TITLE_DONE -Body $BODY_DONE -Tag (Get-SessionTag $key)
    }
  }

  'banner-needs-input' {
    $key = Get-SessionKey
    if ($ENABLED) { Write-BannerJson -Title $TITLE_NEEDS_INPUT -Body $BODY_NEEDS_INPUT -Tag (Get-SessionTag $key) }
  }

  'test-done'        { Invoke-Alarm -Wav $SOUND_DONE        -Title $TITLE_DONE        -Body $BODY_DONE        -Tag (Get-SessionTag (Get-SessionKey)) }
  'test-needs-input' { Invoke-Alarm -Wav $SOUND_NEEDS_INPUT -Title $TITLE_NEEDS_INPUT -Body $BODY_NEEDS_INPUT -Tag (Get-SessionTag (Get-SessionKey)) }
}

exit 0
