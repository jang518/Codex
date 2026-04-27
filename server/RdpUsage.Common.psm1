Set-StrictMode -Version Latest

$script:RdpUsageWtsLoaded = $false

function Initialize-RdpUsageStore {
    param([Parameter(Mandatory = $true)][string]$Path)
    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        $store = [pscustomobject]@{ version = 1; reservations = @(); clients = @() }
        $store | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Read-RdpUsageStore {
    param([Parameter(Mandatory = $true)][string]$Path)
    Initialize-RdpUsageStore -Path $Path
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = '{"version":1,"reservations":[],"clients":[]}'
    }
    $store = $raw | ConvertFrom-Json
    if (-not (Get-Member -InputObject $store -Name reservations -MemberType NoteProperty)) {
        $store | Add-Member -NotePropertyName reservations -NotePropertyValue @()
    }
    if (-not (Get-Member -InputObject $store -Name clients -MemberType NoteProperty)) {
        $store | Add-Member -NotePropertyName clients -NotePropertyValue @()
    }
    return $store
}

function Write-RdpUsageStore {
    param([Parameter(Mandatory = $true)][string]$Path,[Parameter(Mandatory = $true)][pscustomobject]$Store)
    $Store | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertTo-RdpUsageUtc {
    param([Parameter(Mandatory = $true)][object]$Value)
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [DateTime]) { return ([DateTimeOffset]$Value).ToUniversalTime() }
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal).ToUniversalTime()
}

function Format-RdpUsageUtc {
    param([Parameter(Mandatory = $true)][DateTimeOffset]$Value)
    return $Value.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-RdpUsageReservationOverlap {
    param([DateTimeOffset]$StartUtc,[DateTimeOffset]$EndUtc,[DateTimeOffset]$ExistingStartUtc,[DateTimeOffset]$ExistingEndUtc)
    return ($StartUtc -lt $ExistingEndUtc -and $EndUtc -gt $ExistingStartUtc)
}

function Add-RdpUsageReservation {
    param([pscustomobject]$Store,[string]$Owner,[DateTimeOffset]$StartUtc,[DateTimeOffset]$EndUtc,[string]$Note = '',[string]$ClientId = '')
    if ([string]::IsNullOrWhiteSpace($Owner)) { throw 'Validation: owner is required.' }
    if ($EndUtc -le $StartUtc) { throw 'Validation: endUtc must be later than startUtc.' }
    foreach ($reservation in @($Store.reservations)) {
        $existingStart = ConvertTo-RdpUsageUtc $reservation.startUtc
        $existingEnd = ConvertTo-RdpUsageUtc $reservation.endUtc
        if (Test-RdpUsageReservationOverlap -StartUtc $StartUtc -EndUtc $EndUtc -ExistingStartUtc $existingStart -ExistingEndUtc $existingEnd) {
            $exception = [InvalidOperationException]::new('ReservationConflict: requested time overlaps an existing reservation.')
            $exception.Data['conflictId'] = [string]$reservation.id
            $exception.Data['conflictOwner'] = [string]$reservation.owner
            $exception.Data['conflictStartUtc'] = Format-RdpUsageUtc $existingStart
            $exception.Data['conflictEndUtc'] = Format-RdpUsageUtc $existingEnd
            $exception.Data['conflictNote'] = [string]$reservation.note
            throw $exception
        }
    }
    $newReservation = [pscustomobject]@{
        id = [guid]::NewGuid().ToString('N')
        owner = $Owner.Trim()
        startUtc = Format-RdpUsageUtc $StartUtc
        endUtc = Format-RdpUsageUtc $EndUtc
        note = $Note
        clientId = $ClientId
        createdUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
    }
    $Store.reservations = @($Store.reservations) + $newReservation
    return $newReservation
}

function Remove-RdpUsageReservation {
    param([pscustomobject]$Store,[string]$Id)
    $before = @($Store.reservations).Count
    $Store.reservations = @($Store.reservations | Where-Object { $_.id -ne $Id })
    return (@($Store.reservations).Count -lt $before)
}

function Get-RdpUsageReservationsForApi {
    param([pscustomobject]$Store)
    $cutoff = [DateTimeOffset]::UtcNow
    return @($Store.reservations | Where-Object { (ConvertTo-RdpUsageUtc $_.endUtc) -gt $cutoff } | Sort-Object { ConvertTo-RdpUsageUtc $_.startUtc })
}

function Update-RdpUsageClientHeartbeat {
    param([pscustomobject]$Store,[string]$ClientId,[string]$DisplayName = '',[string]$ComputerName = '')
    if ([string]::IsNullOrWhiteSpace($ClientId)) { throw 'Validation: clientId is required.' }
    $clients = @($Store.clients)
    $existing = $clients | Where-Object { $_.clientId -eq $ClientId } | Select-Object -First 1
    if ($null -eq $existing) {
        $existing = [pscustomobject]@{ clientId = $ClientId; displayName = $DisplayName; computerName = $ComputerName; lastSeenUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow) }
        $clients += $existing
    } else {
        $existing.displayName = $DisplayName
        $existing.computerName = $ComputerName
        $existing.lastSeenUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
    }
    $Store.clients = $clients
    return $existing
}

function Get-RdpUsageCurrentSessions { return @() }
function Get-RdpUsageStatus { return [pscustomobject]@{ version='1.0.0'; checkedAtUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow); machineName = $env:COMPUTERNAME; status='available'; isAvailable=$true; remoteSessions=@(); userSessions=@(); allSessions=@() } }

Export-ModuleMember -Function Initialize-RdpUsageStore, Read-RdpUsageStore, Write-RdpUsageStore, ConvertTo-RdpUsageUtc, Format-RdpUsageUtc, Test-RdpUsageReservationOverlap, Add-RdpUsageReservation, Remove-RdpUsageReservation, Get-RdpUsageReservationsForApi, Update-RdpUsageClientHeartbeat, Get-RdpUsageCurrentSessions, Get-RdpUsageStatus
