param([string]$Duration)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ==============================================================================
# KEEP SCREEN AWAKE — shared with the profile's `keepawake` command
# ==============================================================================
. (Join-Path $PSScriptRoot "helpers\keepawake.ps1")

# ==============================================================================
# BIG DIGITS  (5 rows tall)
# ==============================================================================

$script:Digits = @{
    '0' = @(
        ' ██████ '
        '██    ██'
        '██    ██'
        '██    ██'
        ' ██████ '
    )
    '1' = @(
        '   ██   '
        ' ████   '
        '   ██   '
        '   ██   '
        ' ██████ '
    )
    '2' = @(
        ' ██████ '
        '     ██ '
        ' ██████ '
        '██      '
        ' ██████ '
    )
    '3' = @(
        ' ██████ '
        '     ██ '
        '  █████ '
        '     ██ '
        ' ██████ '
    )
    '4' = @(
        '██    ██'
        '██    ██'
        ' ███████'
        '      ██'
        '      ██'
    )
    '5' = @(
        ' ██████ '
        '██      '
        ' ██████ '
        '     ██ '
        ' ██████ '
    )
    '6' = @(
        ' ██████ '
        '██      '
        '███████ '
        '██    ██'
        ' ██████ '
    )
    '7' = @(
        ' ██████ '
        '     ██ '
        '    ██  '
        '   ██   '
        '   ██   '
    )
    '8' = @(
        ' ██████ '
        '██    ██'
        ' ██████ '
        '██    ██'
        ' ██████ '
    )
    '9' = @(
        ' ██████ '
        '██    ██'
        ' ███████'
        '      ██'
        ' ██████ '
    )
    ':' = @(
        '   '
        ' █ '
        '   '
        ' █ '
        '   '
    )
    ' ' = @(
        '   '
        '   '
        '   '
        '   '
        '   '
    )
}

function _BigTextRows
{
    param([string]$Text)
    $rows = @('','','','','')
    foreach ($ch in $Text.ToCharArray())
    {
        $glyph = if ($script:Digits.ContainsKey([string]$ch)) { $script:Digits[[string]$ch] } else { $script:Digits[' '] }
        for ($r = 0; $r -lt 5; $r++)
        { $rows[$r] += $glyph[$r] + ' ' }
    }
    return $rows
}

# ==============================================================================
# HELPERS
# ==============================================================================

function _ParseDuration
{
    param([string]$Raw)
    if (-not $Raw -or $Raw -notmatch '^\d') { return -1 }

    $total = 0
    $found = $false

    # Accept decimals: e.g. 1.5h, 2.5m, 0.5s
    foreach ($part in [regex]::Matches($Raw, '(\d+(?:\.\d+)?)([hms])'))
    {
        $num  = [double]$part.Groups[1].Value
        $unit = $part.Groups[2].Value
        switch ($unit)
        {
            'h' { $total += [math]::Round($num * 3600) }
            'm' { $total += [math]::Round($num * 60)   }
            's' { $total += [math]::Round($num)         }
        }
        $found = $true
    }

    if (-not $found) { return -1 }
    return $total
}

function _FormatDuration
{
    param([int]$Seconds)
    $h = [int][math]::Floor($Seconds / 3600)
    $m = [int][math]::Floor(($Seconds % 3600) / 60)
    $s = [int]($Seconds % 60)
    if ($h -gt 0) { return "{0}:{1:D2}:{2:D2}" -f $h, $m, $s }
    return "{0:D2}:{1:D2}" -f $m, $s
}

function _ProgressBar
{
    param([int]$Remaining, [int]$Total, [int]$Width)
    $filled = if ($Total -gt 0) { [math]::Round(($Total - $Remaining) / $Total * $Width) } else { $Width }
    $empty  = $Width - $filled
    return ("█" * $filled) + ("░" * $empty)
}

function _WriteAt
{
    param([int]$X, [int]$Y, [string]$Text)
    $bufH = [Console]::BufferHeight
    $bufW = [Console]::BufferWidth
    $safeY = [math]::Max(0, [math]::Min($Y, $bufH - 1))
    $safeX = [math]::Max(0, [math]::Min($X, $bufW - 1))
    [Console]::SetCursorPosition($safeX, $safeY)
    [Console]::Write($Text)
}

function _DrawStatic
{
    param([int]$W, [string]$Label, [int]$StartRow, [int]$HintRow)

    [Console]::Write("`e[2J")

    $dimColor = "`e[38;5;240m"
    $reset    = "`e[0m"

    # Label
    $labelLine = "    $Label"
    $lPad      = [math]::Max(0, [math]::Floor(($W - $labelLine.Length) / 2))
    $lTail     = [math]::Max(0, $W - $lPad - $labelLine.Length)
    _WriteAt 0 ($StartRow - 2) (" " * $lPad + "$dimColor$labelLine$reset" + " " * $lTail)

    # Hint
    $hint  = "Space/p to pause  ·  Ctrl+C to cancel"
    $hPad  = [math]::Max(0, [math]::Floor(($W - $hint.Length) / 2))
    $hTail = [math]::Max(0, $W - $hPad - $hint.Length)
    _WriteAt 0 $HintRow (" " * $hPad + "$dimColor$hint$reset" + " " * $hTail)
}

function _DrawDynamic
{
    param([int]$Remaining, [int]$Total, [int]$W, [int]$StartRow, [int]$BarRow, [int]$PctRow, [bool]$Paused)

    $pct      = if ($Total -gt 0) { [math]::Round(($Total - $Remaining) / $Total * 100) } else { 100 }
    $timeStr  = _FormatDuration $Remaining
    $barWidth = [math]::Max(20, $W - 8)
    $bar      = _ProgressBar $Remaining $Total $barWidth

    # Colors — yellow when paused, urgency scale otherwise
    $timeColor = if ($Paused)                   { "`e[93m" }
                 elseif ($Remaining -le 10)     { "`e[91m" }
                 elseif ($Remaining -le 60)     { "`e[38;2;208;135;112m" }
                 else                            { "`e[92m" }
    $barColor  = if ($Paused)                   { "`e[93m" }
                 elseif ($Remaining -le 10)     { "`e[91m" }
                 elseif ($Remaining -le 60)     { "`e[38;2;208;135;112m" }
                 else                            { "`e[34m" }
    $dimColor  = "`e[38;5;240m"
    $reset     = "`e[0m"

    # Big digits
    $rows     = _BigTextRows $timeStr
    $rowWidth = $rows[0].Length
    $tPad     = [math]::Max(0, [math]::Floor(($W - $rowWidth) / 2))

    for ($r = 0; $r -lt 5; $r++)
    {
        $tail = [math]::Max(0, $W - $tPad - $rows[$r].Length)
        _WriteAt 0 ($StartRow + $r) (" " * $tPad + "$timeColor$($rows[$r])$reset" + " " * $tail)
    }

    # Bar
    $barLine = "  $bar  "
    $bPad    = [math]::Max(0, [math]::Floor(($W - $barLine.Length) / 2))
    $bTail   = [math]::Max(0, $W - $bPad - $barLine.Length)
    _WriteAt 0 $BarRow (" " * $bPad + "$barColor$barLine$reset" + " " * $bTail)

    # Percentage / paused label
    $pctStr = if ($Paused) { "  paused" } else { "$pct%" }
    $pPad   = [math]::Max(0, [math]::Floor(($W - $pctStr.Length) / 2))
    $pTail  = [math]::Max(0, $W - $pPad - $pctStr.Length)
    _WriteAt 0 $PctRow (" " * $pPad + "$dimColor$pctStr$reset" + " " * $pTail)
}

# ==============================================================================
# MAIN
# ==============================================================================

if (-not $Duration)
{
    Write-Host ""
    Write-Host "Usage: timer <duration>" -ForegroundColor Yellow
    Write-Host "─────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "│  Examples:  30s   5m   1h   1h30m   1.5h   2.5m" -ForegroundColor DarkGray
    Write-Host "─────────────────────────────────────────────────────`n" -ForegroundColor DarkGray
    exit
}

$totalSecs = _ParseDuration $Duration
if ($totalSecs -le 0)
{
    Write-Host " Invalid duration '$Duration'. Examples: 30s, 5m, 1h, 1.5h" -ForegroundColor Red
    exit
}

# Enter alternate screen buffer
[Console]::Write("`e[?1049h")
[Console]::CursorVisible = $false

# Keep display/system awake for the duration of the timer
_EnableKeepAwake

$remaining = $totalSecs
$paused    = $false
$lastW     = 0
$lastH     = 0
$startRow  = 0
$barRow    = 0
$pctRow    = 0
$hintRow   = 0

try
{
    while ($remaining -ge 0)
    {
        $w = $Host.UI.RawUI.WindowSize.Width
        $h = $Host.UI.RawUI.WindowSize.Height

        if ($w -ne $lastW -or $h -ne $lastH)
        {
            $mid      = [int][math]::Floor($h / 2) - 2
            $startRow = $mid
            $barRow   = $mid + 7
            $pctRow   = $mid + 9
            $hintRow  = $mid + 11

            _DrawStatic $w $Duration $startRow $hintRow
            $lastW = $w
            $lastH = $h
        }

        _DrawDynamic $remaining $totalSecs $w $startRow $barRow $pctRow $paused

        if ($remaining -eq 0 -and -not $paused) { break }

        # Poll for keypresses in 100 ms slices; only advance time when not paused
        $elapsed = 0
        while ($elapsed -lt 10)
        {
            # Detect resize while inside the poll loop (e.g. resized while paused)
            $curW = $Host.UI.RawUI.WindowSize.Width
            $curH = $Host.UI.RawUI.WindowSize.Height
            if ($curW -ne $lastW -or $curH -ne $lastH)
            {
                $w        = $curW
                $mid      = [int][math]::Floor($curH / 2) - 2
                $startRow = $mid
                $barRow   = $mid + 7
                $pctRow   = $mid + 9
                $hintRow  = $mid + 11
                _DrawStatic  $w $Duration $startRow $hintRow
                _DrawDynamic $remaining $totalSecs $w $startRow $barRow $pctRow $paused
                $lastW = $curW
                $lastH = $curH
            }

            if ([Console]::KeyAvailable)
            {
                $key = [Console]::ReadKey($true)
                if ($key.Key -eq [ConsoleKey]::Spacebar -or
                    $key.KeyChar -eq 'p' -or $key.KeyChar -eq 'P')
                {
                    $paused = -not $paused
                    _DrawDynamic $remaining $totalSecs $w $startRow $barRow $pctRow $paused
                }
            }
            _EnableKeepAwake
            Start-Sleep -Milliseconds 100
            if (-not $paused) { $elapsed++ }
        }

        if (-not $paused) { $remaining-- }
    }

    # Done screen
    [Console]::Write("`e[2J")
    $w    = $Host.UI.RawUI.WindowSize.Width
    $h    = $Host.UI.RawUI.WindowSize.Height
    $mid  = [int][math]::Floor($h / 2)

    $done = "  Timer complete!"
    $dPad = [math]::Max(0, [math]::Floor(($w - $done.Length) / 2))
    _WriteAt $dPad ($mid - 1) ("`e[92m$done`e[0m")

    $sub  = _FormatDuration $totalSecs
    $sPad = [math]::Max(0, [math]::Floor(($w - $sub.Length) / 2))
    _WriteAt $sPad ($mid + 1) ("`e[38;5;240m$sub`e[0m")

    [Console]::Beep(880,  200); Start-Sleep -Milliseconds 100
    [Console]::Beep(880,  200); Start-Sleep -Milliseconds 100
    [Console]::Beep(1100, 400)

    Start-Sleep -Seconds 2
}
finally
{
    [Console]::CursorVisible = $true
    [Console]::Write("`e[?1049l")
    _DisableKeepAwake
}