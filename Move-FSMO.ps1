<#
  FSMO transfer (single domain, single site): all five roles $Old -> $New

    .\Move-FSMO.ps1 -Phase Pre    # before the window; must end in GO
    .\Move-FSMO.ps1 -Phase Move   # the transfer
    .\Move-FSMO.ps1 -Phase Post   # right after; must end in PASS

  Run elevated on a DC as a member of Schema Admins + Enterprise Admins + Domain Admins.
  Logs + transcript land in C:\Temp\FSMO-<Phase>-<timestamp>.
#>
param(
    [Parameter(Mandatory)][ValidateSet('Pre','Move','Post')][string]$Phase,
    [string]$Old = 'OLD-DC',   # current holder of all five roles
    [string]$New = 'NEW-DC'    # new holder
)
Import-Module ActiveDirectory
$Roles = 'SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster'
$Log   = "C:\Temp\FSMO-$Phase-$(Get-Date -f yyyyMMdd-HHmm)"
New-Item $Log -ItemType Directory -Force | Out-Null
Start-Transcript "$Log\transcript.txt" | Out-Null

$Fail   = [System.Collections.Generic.List[string]]::new()   # blocks GO / PASS
$Review = [System.Collections.Generic.List[string]]::new()   # judgement call, look before proceeding

$OldFqdn = (Get-ADDomainController -Identity $Old).HostName
$NewFqdn = (Get-ADDomainController -Identity $New).HostName

function Section($t) { Write-Host "`n=== $t" -ForegroundColor Cyan }

# Every DC's own view of who holds each role; any mismatch with $fqdn is a failure
function Test-RolesOn($fqdn) {
    foreach ($dc in (Get-ADDomainController -Filter *).HostName) {
        $d = Get-ADDomain -Server $dc; $f = Get-ADForest -Server $dc
        $v = [pscustomobject]@{ AskedDC = $dc; SchemaMaster = $f.SchemaMaster; DomainNamingMaster = $f.DomainNamingMaster
                                PDCEmulator = $d.PDCEmulator; RIDMaster = $d.RIDMaster; InfrastructureMaster = $d.InfrastructureMaster }
        $v
        foreach ($r in $Roles) { if ($v.$r -ne $fqdn) { $Fail.Add("$dc sees $r on $($v.$r), expected $fqdn") } }
    }
}

# Event-log tests (SystemLog etc.) fail on any recent error, so they go to Review, not Fail
function Invoke-Dcdiag($dc, $Tag, [string[]]$Tests) {
    $file = "$Log\dcdiag-$Tag-$dc.txt"
    $a = @("/s:$dc", "/f:$file") + @(foreach ($t in $Tests) { "/test:$t" })
    & dcdiag.exe @a | Out-Null
    Select-String -Path $file -Pattern 'failed test (\S+)' | ForEach-Object {
        $t = $_.Matches[0].Groups[1].Value
        if ($t -in 'SystemLog','DFSREvent','KccEvent','FrsEvent') { $Review.Add("$dc failed dcdiag $t (event-log test) - check $file") }
        else { $Fail.Add("$dc failed dcdiag $t - see $file") }
    }
    Write-Host "$dc dcdiag ($Tag) -> $file"
}

function Test-Replication {
    repadmin /replsummary
    $bad = repadmin /showrepl * /csv | ConvertFrom-Csv | Where-Object { ($_.'Number of Failures' -as [int]) -gt 0 }
    $bad | Select-Object 'Destination DSA','Source DSA','Naming Context','Number of Failures','Last Failure Status' | Format-Table -AutoSize
    foreach ($b in $bad) { $Fail.Add("Replication $($b.'Source DSA') -> $($b.'Destination DSA') [$($b.'Naming Context')]: $($b.'Number of Failures') failures") }
}

switch ($Phase) {
'Pre' {
    Section "1. Current role holders (all five must be on $OldFqdn)"
    Test-RolesOn $OldFqdn | Format-Table -AutoSize

    Section '2. dcdiag on old and new DC'
    foreach ($dc in $Old, $New) { Invoke-Dcdiag $dc 'default'; Invoke-Dcdiag $dc 'fsmo' FsmoCheck }

    Section '3. AD replication'
    Test-Replication

    Section '4. SYSVOL (DFSR folder State 4 = Normal)'
    dfsrmig /getmigrationstate
    foreach ($dc in $Old, $New) {
        try {
            $s = Get-CimInstance -ComputerName $dc -Namespace root/microsoftdfs -ClassName DfsrReplicatedFolderInfo -ErrorAction Stop |
                 Where-Object ReplicatedFolderName -eq 'SYSVOL Share'
        } catch { $Review.Add("$dc DFSR query failed: $($_.Exception.Message)"); continue }
        if (-not $s) { $Fail.Add("$dc has no DFSR SYSVOL folder") }
        elseif ($s.State -ne 4) { $Fail.Add("$dc SYSVOL DFSR state is $($s.State), expected 4") }
        $s | Select-Object @{n='DC';e={$dc}}, ReplicatedFolderName, State
    }

    Section '5. My admin groups'
    $g = whoami /groups
    foreach ($n in 'Schema Admins','Enterprise Admins','Domain Admins') {
        if ($g -match [regex]::Escape($n)) { "OK  $n" } else { $Fail.Add("Token missing $n (add the group, then log off/on)") }
    }

    Section '6. Time config on current PDC (Post phase copies this to the new PDC)'
    w32tm /query /computer:$Old /source
    w32tm /query /computer:$Old /configuration | Tee-Object "$Log\time-$Old.txt" | Select-String 'Type:|NtpServer:'

    Section '7. Last backup of old DC'
    repadmin /showbackup $Old
    $Review.Add('Confirm the backup dates in section 7 are recent')
}

'Move' {
    Section "Transferring all five roles to $NewFqdn"
    try {
        Move-ADDirectoryServerOperationMasterRole -Identity $New -OperationMasterRole $Roles -Confirm:$false -ErrorAction Stop
        Test-RolesOn $NewFqdn | Format-Table -AutoSize
    } catch { $Fail.Add("Transfer failed: $($_.Exception.Message)") }
}

'Post' {
    Section "1. Every DC must see all five roles on $NewFqdn"
    Test-RolesOn $NewFqdn | Format-Table -AutoSize

    Section '2. Force replication, then check'
    repadmin /syncall $New /AdP | Out-File "$Log\syncall.txt"
    Start-Sleep 30
    Test-Replication

    Section '3. dcdiag role tests on new DC'
    Invoke-Dcdiag $New 'roles' RidManager,KnowsOfRoleHolders,FsmoCheck,Advertising

    Section '4. Time: move the PDC time-source config to the new DC'
    $cfg  = w32tm /query /computer:$Old /configuration
    $type = ($cfg | Select-String '^\s*Type:').Line
    $ntp  = ($cfg | Select-String '^\s*NtpServer:').Line
    "Old PDC -> $type | $ntp"
    if ("$type$ntp" -match '\(Policy\)') {
        $Review.Add('Time is set by GPO - nothing changed; confirm the GPO follows the PDC role (WMI filter), not the old DC by name')
    } elseif ($type -match 'NTP') {
        $peers = ($ntp -replace '^\s*NtpServer:\s*', '' -replace '\s*\(Local\)\s*$', '').Trim()
        w32tm /config /computer:$New /manualpeerlist:"$peers" /syncfromflags:manual /reliable:yes /update
        w32tm /config /computer:$Old /syncfromflags:domhier /reliable:no /update
        foreach ($dc in $New, $Old) { Get-Service w32time -ComputerName $dc | Restart-Service }
        Start-Sleep 15
        w32tm /resync /computer:$New /rediscover
    } else {
        $Review.Add("Old PDC was not syncing to external NTP ($type) - decide the new PDC's time source; nothing changed")
    }
    "New PDC source: $(w32tm /query /computer:$New /source)"
    "Old DC source:  $(w32tm /query /computer:$Old /source)"
    w32tm /monitor

    Section '5. Errors in the last 2 hours (Directory Service + System)'
    foreach ($dc in $Old, $New) {
        $ev = Get-WinEvent -ComputerName $dc -FilterHashtable @{ LogName = 'Directory Service','System'; Level = 1,2; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue
        $ev | Select-Object @{n='DC';e={$dc}}, TimeCreated, LogName, Id, ProviderName, Message | Format-List
        if ($ev) { $Review.Add("$dc has $(@($ev).Count) error events in the last 2h - see section 5") }
    }
}
}

Section 'Summary'
if ($Review.Count) { 'REVIEW:'; $Review | ForEach-Object { "  - $_" } }
if ($Fail.Count) {
    Write-Host "RESULT: $(if ($Phase -eq 'Pre') {'NO-GO'} else {'FAIL'})" -ForegroundColor Red
    $Fail | ForEach-Object { "  - $_" }
} else {
    Write-Host "RESULT: $(if ($Phase -eq 'Pre') {'GO'} else {'PASS'})" -ForegroundColor Green
}
"Logs: $Log"
Stop-Transcript | Out-Null
