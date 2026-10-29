<#
  FSMO pre-transfer audit (single domain, single site) - READ-ONLY, changes nothing.

    .\Audit-FSMO.ps1 -Old <current-dc> -New <target-dc>

  Must end in GO. Run elevated on a DC.
  Only local output is written: C:\Temp\FSMO-Audit-<timestamp>.
#>
param(
    [string]$Old = 'OLD-DC',   # current holder of all five roles
    [string]$New = 'NEW-DC'    # intended new holder
)
Import-Module ActiveDirectory
$Roles = 'SchemaMaster','DomainNamingMaster','PDCEmulator','RIDMaster','InfrastructureMaster'
$Log   = "C:\Temp\FSMO-Audit-$(Get-Date -f yyyyMMdd-HHmm)"
New-Item $Log -ItemType Directory -Force | Out-Null
Start-Transcript "$Log\transcript.txt" | Out-Null

$Fail   = [System.Collections.Generic.List[string]]::new()   # blocks GO
$Review = [System.Collections.Generic.List[string]]::new()   # judgement call

$OldFqdn = (Get-ADDomainController -Identity $Old).HostName

function Section($t) { Write-Host "`n=== $t" -ForegroundColor Cyan }

Section "1. Current role holders - every DC's view (all five must be on $OldFqdn)"
& {
    foreach ($dc in (Get-ADDomainController -Filter *).HostName) {
        $d = Get-ADDomain -Server $dc; $f = Get-ADForest -Server $dc
        $v = [pscustomobject]@{ AskedDC = $dc; SchemaMaster = $f.SchemaMaster; DomainNamingMaster = $f.DomainNamingMaster
                                PDCEmulator = $d.PDCEmulator; RIDMaster = $d.RIDMaster; InfrastructureMaster = $d.InfrastructureMaster }
        $v
        foreach ($r in $Roles) { if ($v.$r -ne $OldFqdn) { $Fail.Add("$dc sees $r on $($v.$r), expected $OldFqdn") } }
    }
} | Format-Table -AutoSize

Section '2. dcdiag on old and new DC'
foreach ($dc in $Old, $New) {
    foreach ($run in @{ Tag = 'default'; Args = @() }, @{ Tag = 'fsmo'; Args = @('/test:FsmoCheck') }) {
        $file = "$Log\dcdiag-$($run.Tag)-$dc.txt"
        & dcdiag.exe "/s:$dc" "/f:$file" @($run.Args) | Out-Null
        Write-Host "$dc dcdiag ($($run.Tag)) -> $file"
        # Event-log tests fail on any recent error, so they go to Review, not Fail
        Select-String -Path $file -Pattern 'failed test (\S+)' | ForEach-Object {
            $t = $_.Matches[0].Groups[1].Value
            if ($t -in 'SystemLog','DFSREvent','KccEvent','FrsEvent') { $Review.Add("$dc failed dcdiag $t (event-log test) - check $file") }
            else { $Fail.Add("$dc failed dcdiag $t - see $file") }
        }
    }
}

Section '3. AD replication'
repadmin /replsummary
$bad = repadmin /showrepl * /csv | ConvertFrom-Csv | Where-Object { ($_.'Number of Failures' -as [int]) -gt 0 }
$bad | Select-Object 'Destination DSA','Source DSA','Naming Context','Number of Failures','Last Failure Status' | Format-Table -AutoSize
foreach ($b in $bad) { $Fail.Add("Replication $($b.'Source DSA') -> $($b.'Destination DSA') [$($b.'Naming Context')]: $($b.'Number of Failures') failures") }

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

Section '5. My admin groups (needed for the transfer)'
$g = whoami /groups
foreach ($n in 'Schema Admins','Enterprise Admins','Domain Admins') {
    if ($g -match [regex]::Escape($n)) { "OK  $n" } else { $Fail.Add("Token missing $n (add the group, then log off/on)") }
}

Section '6. Time config on current PDC (new PDC will need the same external source)'
w32tm /query /computer:$Old /source
w32tm /query /computer:$Old /configuration | Tee-Object "$Log\time-$Old.txt" | Select-String 'Type:|NtpServer:'

Section '7. Last backup of old DC'
repadmin /showbackup $Old
$Review.Add('Confirm the backup dates in section 7 are recent')

Section 'Summary'
if ($Review.Count) { 'REVIEW:'; $Review | ForEach-Object { "  - $_" } }
if ($Fail.Count) { Write-Host 'RESULT: NO-GO' -ForegroundColor Red; $Fail | ForEach-Object { "  - $_" } }
else { Write-Host 'RESULT: GO' -ForegroundColor Green }
"Logs: $Log"
Stop-Transcript | Out-Null
