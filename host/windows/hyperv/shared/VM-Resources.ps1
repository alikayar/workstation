function ConvertTo-WorkstationResource {
    param([string]$Name, [string]$Value, [int]$Minimum, [int]$Maximum)
    $number = 0
    if ($Value -notmatch '^[0-9]+$' -or -not [int]::TryParse($Value, [ref]$number) -or
        $number -lt $Minimum -or $number -gt $Maximum) {
        throw "$Name must be an integer between $Minimum and $Maximum."
    }
    return $number
}
