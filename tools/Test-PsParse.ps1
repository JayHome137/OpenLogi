# Parse-only check: no code is executed. Usage: pwsh -File tools/Test-PsParse.ps1 <file.ps1>...
'PSVersion={0} Edition={1}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition
$bad = 0
foreach ($f in $args) {
    $t = $null; $e = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $f).Path, [ref]$t, [ref]$e)
    '{0,-45} errors={1}' -f $f, @($e).Count
    foreach ($x in @($e)) { '   line {0}: {1}' -f $x.Extent.StartLineNumber, $x.Message }
    $bad += @($e).Count
}
'TOTAL_ERRORS={0}' -f $bad
exit ([int]($bad -gt 0))
