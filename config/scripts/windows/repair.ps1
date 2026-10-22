# Windows health repair (Windows > Diagnostics): DISM repairs the component
# store, then SFC repairs system files, then the report lists what was fixed.
# Changes system files. Takes 10-40 minutes. Keep this file ASCII-only.

$start = Get-Date

Write-Step 'Checking for a pending restart'
Add-TTPart 'Before repair' {
    $s = New-TTSection 'Before repair'
    $why = @(Test-TTRebootPending)
    if ($why.Count) {
        $s.Level = 'warn'
        $s.Summary = 'A restart is pending (' + ($why -join ', ') + ')'
        Add-TTNote $s 'SFC may not be able to finish until the PC restarts. If it reports a pending repair, restart and run this again.' 'warn'
    } else { $s.Summary = 'No restart pending' }
    $os = Get-CimInstance Win32_OperatingSystem
    Add-TTFact $s 'Windows' ('{0} (build {1})' -f $os.Caption, $os.BuildNumber)
    Add-TTFact $s 'Started' $start.ToString('yyyy-MM-dd HH:mm')
    $s
}

Write-Step 'DISM: repairing the Windows component store (5-20 min, needs internet)'
$dismOk = $true
Add-TTPart 'DISM component store repair' {
    $s = New-TTSection 'DISM component store repair'
    $r = Invoke-TTWatchedProcess -File (Join-Path $env:windir 'System32\Dism.exe') -Arguments '/Online /Cleanup-Image /RestoreHealth' -Label 'DISM'
    $o = Get-TTDismOutcome $r.Text $r.Code
    $s.Level = $o.Level
    $s.Summary = $o.Text
    Add-TTFact $s 'Exit code' $r.Code
    $tail = @(($r.Text -split "`n") | Select-Object -Last 4) -join ' / '
    if ($tail) { Add-TTFact $s 'DISM said' (Get-TTShortText $tail 300) }
    $s
}

Write-Step 'SFC: checking and repairing system files (5-20 min)'
$sfc = $null
$script:TTSfc = $null
Add-TTPart 'SFC system file check' {
    $s = New-TTSection 'SFC system file check'
    $r = Invoke-TTWatchedProcess -File (Join-Path $env:windir 'System32\sfc.exe') -Arguments '/scannow' -Label 'SFC'
    $o = Get-TTSfcOutcome $r.Text $r.Code
    $script:TTSfc = $o
    $s.Level = $o.Level
    $s.Summary = $o.Text
    Add-TTFact $s 'Exit code' $r.Code
    if ($o.Repaired) { Add-TTNote $s 'Restart the PC to finish the repair.' 'warn' }
    $s
}
$sfc = $script:TTSfc

Write-Step 'Reading what was repaired'
Add-TTPart 'Files repaired' {
    $s = New-TTSection 'Files repaired'
    $s.Level = 'info'
    $rows = @(Get-TTCbsRepairs -Since $start)
    Add-TTTable $s 'From the Windows repair log (CBS.log)' @('File', 'Result') $rows
    $bad = @($rows | Where-Object { $_.Result -ne 'Repaired' }).Count
    if ($bad) { $s.Level = 'fail'; Add-TTNote $s 'Some files could not be repaired. An in-place upgrade (repair install) of Windows usually fixes this.' 'fail' }
    $s.Summary = $(if ($rows.Count) { '{0} file(s) repaired, {1} could not be' -f ($rows.Count - $bad), $bad } else { 'Nothing needed repairing' })
    $s
}

Write-Step 'Saving the report'
$lead = 'Repair finished.'
$leadLv = 'ok'
if ($sfc -and $sfc.Repaired) { $lead = 'Repairs were made. Restart the PC to finish.'; $leadLv = 'warn'; Write-Warn 'Restart the PC to finish the repair.' }
Complete-TTReport -Title 'Windows Health Repair' -Prefix 'Repair' -Tool 'repair' -Lead $lead -LeadLevel $leadLv
