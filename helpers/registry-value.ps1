# ==============================================================================
# REGISTRY VALUE TYPE CONVERSION
# ==============================================================================
function ConvertTo-RegistryTypedValue
{
    param(
        [Parameter(Mandatory)][string]$Type,
        [Parameter(Mandatory)]$RawValue,
        [Parameter(Mandatory)][string]$EntryName
    )

    switch ($Type)
    {
        'DWord'  { return 'DWord', ([int]$RawValue) }
        'String' { return 'String', ([string]$RawValue) }
        'Json'   { return 'String', ($RawValue | ConvertTo-Json -Compress -Depth 10) }
        Default  { throw "Unknown registry value type '$Type' for entry '$EntryName'" }
    }
}
