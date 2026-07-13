# ==============================================================================
# KEEP AWAKE (Windows SetThreadExecutionState)
# ==============================================================================

if (-not ("Win32.Power" -as [type]))
{
    Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

$script:ES_CONTINUOUS       = 0x80000000u
$script:ES_SYSTEM_REQUIRED  = 0x00000001u
$script:ES_DISPLAY_REQUIRED = 0x00000002u

function _EnableKeepAwake
{
    [Win32.Power]::SetThreadExecutionState(
        $script:ES_CONTINUOUS -bor $script:ES_SYSTEM_REQUIRED -bor $script:ES_DISPLAY_REQUIRED
    ) | Out-Null
}

function _DisableKeepAwake
{
    [Win32.Power]::SetThreadExecutionState($script:ES_CONTINUOUS) | Out-Null
}