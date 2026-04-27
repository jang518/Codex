$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\server\RdpUsage.Common.psm1') -Force

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$store = [pscustomobject]@{
    version      = 1
    reservations = @()
    clients      = @()
}

$start = [DateTimeOffset]::Parse('2026-04-22T01:00:00Z')
$end = [DateTimeOffset]::Parse('2026-04-22T02:00:00Z')

$reservation = Add-RdpUsageReservation -Store $store -Owner 'Kim' -StartUtc $start -EndUtc $end -Note 'CAD' -ClientId 'client-a'
Assert-True ($reservation.owner -eq 'Kim') 'reservation owner should be saved'
Assert-True (@($store.reservations).Count -eq 1) 'one reservation should exist'

$conflictThrown = $false
try {
    Add-RdpUsageReservation -Store $store -Owner 'Lee' -StartUtc ($start.AddMinutes(30)) -EndUtc ($end.AddMinutes(30)) -Note '' -ClientId 'client-b' | Out-Null
}
catch {
    $conflictThrown = $_.Exception.Message.StartsWith('ReservationConflict:')
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['conflictOwner'])) 'conflict should include the existing reservation owner'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['conflictStartUtc'])) 'conflict should include the existing start time'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Data['conflictEndUtc'])) 'conflict should include the existing end time'
}
Assert-True $conflictThrown 'overlapping reservation should be rejected'

Add-RdpUsageReservation -Store $store -Owner 'Park' -StartUtc $end -EndUtc ($end.AddHours(1)) -Note '' -ClientId 'client-c' | Out-Null
Assert-True (@($store.reservations).Count -eq 2) 'back-to-back reservation should be allowed'

$removed = Remove-RdpUsageReservation -Store $store -Id $reservation.id
Assert-True $removed 'existing reservation should be removed'
Assert-True (@($store.reservations).Count -eq 1) 'one reservation should remain'

$client = Update-RdpUsageClientHeartbeat -Store $store -ClientId 'client-a' -DisplayName 'Kim' -ComputerName 'DESK-01'
Assert-True ($client.computerName -eq 'DESK-01') 'client heartbeat should save computer name'

$filterStore = [pscustomobject]@{
    version      = 1
    reservations = @()
    clients      = @()
}

$now = [DateTimeOffset]::UtcNow
Add-RdpUsageReservation -Store $filterStore -Owner 'Old' -StartUtc ($now.AddHours(-2)) -EndUtc ($now.AddHours(-1)) -Note '' -ClientId 'client-old' | Out-Null
Add-RdpUsageReservation -Store $filterStore -Owner 'Future' -StartUtc ($now.AddMinutes(10)) -EndUtc ($now.AddHours(1)) -Note '' -ClientId 'client-future' | Out-Null
$visibleReservations = @(Get-RdpUsageReservationsForApi -Store $filterStore)
Assert-True ($visibleReservations.Count -eq 1) 'completed reservations should be hidden from API results'
Assert-True ($visibleReservations[0].owner -eq 'Future') 'future reservation should remain visible'

Write-Host 'All unit tests passed.'
