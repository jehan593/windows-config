# ==============================================================================
# KEEP AWAKE (Windows SetThreadExecutionState)
# Shared by the profile's `keepawake` command and timer.ps1.
# ==============================================================================

if (-not ("Win32.Power" -as [type]))
{
    Add-Type -Namespace Win32 -Name Power -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
}

$script:ES_CONTINUOUS       = [uint32]"0x80000000"
$script:ES_SYSTEM_REQUIRED  = [uint32]"0x00000001"
$script:ES_DISPLAY_REQUIRED = [uint32]"0x00000002"

function _EnableKeepAwake
{
    # Prevent both system sleep and display sleep
    [Win32.Power]::SetThreadExecutionState(
        $script:ES_CONTINUOUS -bor $script:ES_SYSTEM_REQUIRED -bor $script:ES_DISPLAY_REQUIRED
    ) | Out-Null
}

function _DisableKeepAwake
{
    # Restore normal power management behavior
    [Win32.Power]::SetThreadExecutionState($script:ES_CONTINUOUS) | Out-Null
}