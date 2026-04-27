Set-StrictMode -Version Latest

$script:RdpUsageWtsLoaded = $false

function Initialize-RdpUsageStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $store = [pscustomobject]@{
            version      = 1
            reservations = @()
            clients      = @()
        }
        $store | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
    }
}

function Read-RdpUsageStore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

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
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Store
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Store | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function ConvertTo-RdpUsageUtc {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }

    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }

    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal
    ).ToUniversalTime()
}

function Format-RdpUsageUtc {
    param(
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$Value
    )

    return $Value.ToUniversalTime().ToString("o", [Globalization.CultureInfo]::InvariantCulture)
}

function Test-RdpUsageReservationOverlap {
    param(
        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$StartUtc,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$EndUtc,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$ExistingStartUtc,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$ExistingEndUtc
    )

    return ($StartUtc -lt $ExistingEndUtc -and $EndUtc -gt $ExistingStartUtc)
}

function Add-RdpUsageReservation {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Store,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$StartUtc,

        [Parameter(Mandatory = $true)]
        [DateTimeOffset]$EndUtc,

        [string]$Note = "",

        [string]$ClientId = ""
    )

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        throw "Validation: owner is required."
    }

    if ($EndUtc -le $StartUtc) {
        throw "Validation: endUtc must be later than startUtc."
    }

    $existingReservations = @($Store.reservations)
    foreach ($reservation in $existingReservations) {
        $existingStart = ConvertTo-RdpUsageUtc $reservation.startUtc
        $existingEnd = ConvertTo-RdpUsageUtc $reservation.endUtc
        if (Test-RdpUsageReservationOverlap -StartUtc $StartUtc -EndUtc $EndUtc -ExistingStartUtc $existingStart -ExistingEndUtc $existingEnd) {
            $exception = [InvalidOperationException]::new("ReservationConflict: requested time overlaps an existing reservation.")
            $exception.Data['conflictId'] = [string]$reservation.id
            $exception.Data['conflictOwner'] = [string]$reservation.owner
            $exception.Data['conflictStartUtc'] = Format-RdpUsageUtc $existingStart
            $exception.Data['conflictEndUtc'] = Format-RdpUsageUtc $existingEnd
            $exception.Data['conflictNote'] = [string]$reservation.note
            throw $exception
        }
    }

    $newReservation = [pscustomobject]@{
        id         = [guid]::NewGuid().ToString("N")
        owner      = $Owner.Trim()
        startUtc   = Format-RdpUsageUtc $StartUtc
        endUtc     = Format-RdpUsageUtc $EndUtc
        note       = $Note
        clientId   = $ClientId
        createdUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
    }

    $Store.reservations = @($Store.reservations) + $newReservation
    return $newReservation
}

function Remove-RdpUsageReservation {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Store,

        [Parameter(Mandatory = $true)]
        [string]$Id
    )

    $before = @($Store.reservations).Count
    $Store.reservations = @($Store.reservations | Where-Object { $_.id -ne $Id })
    return (@($Store.reservations).Count -lt $before)
}

function Get-RdpUsageReservationsForApi {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Store
    )

    $cutoff = [DateTimeOffset]::UtcNow
    return @($Store.reservations |
        Where-Object { (ConvertTo-RdpUsageUtc $_.endUtc) -gt $cutoff } |
        Sort-Object { ConvertTo-RdpUsageUtc $_.startUtc })
}

function Update-RdpUsageClientHeartbeat {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Store,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [string]$DisplayName = "",

        [string]$ComputerName = ""
    )

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "Validation: clientId is required."
    }

    $clients = @($Store.clients)
    $existing = $clients | Where-Object { $_.clientId -eq $ClientId } | Select-Object -First 1
    if ($null -eq $existing) {
        $existing = [pscustomobject]@{
            clientId     = $ClientId
            displayName  = $DisplayName
            computerName = $ComputerName
            lastSeenUtc  = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
        }
        $clients += $existing
    }
    else {
        $existing.displayName = $DisplayName
        $existing.computerName = $ComputerName
        $existing.lastSeenUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
    }

    $Store.clients = $clients
    return $existing
}

function Ensure-RdpUsageWtsHelper {
    if ($script:RdpUsageWtsLoaded) {
        return
    }

    $source = @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RdpUsage.Native
{
    public enum WTS_CONNECTSTATE_CLASS
    {
        Active,
        Connected,
        ConnectQuery,
        Shadow,
        Disconnected,
        Idle,
        Listen,
        Reset,
        Down,
        Init
    }

    public enum WTS_INFO_CLASS
    {
        WTSInitialProgram = 0,
        WTSApplicationName = 1,
        WTSWorkingDirectory = 2,
        WTSOEMId = 3,
        WTSSessionId = 4,
        WTSUserName = 5,
        WTSWinStationName = 6,
        WTSDomainName = 7,
        WTSConnectState = 8,
        WTSClientBuildNumber = 9,
        WTSClientName = 10,
        WTSClientDirectory = 11,
        WTSClientProductId = 12,
        WTSClientHardwareId = 13,
        WTSClientAddress = 14
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct WTS_SESSION_INFO
    {
        public int SessionID;
        [MarshalAs(UnmanagedType.LPTStr)]
        public string pWinStationName;
        public WTS_CONNECTSTATE_CLASS State;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_CLIENT_ADDRESS
    {
        public int AddressFamily;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 20)]
        public byte[] Address;
    }

    public sealed class RdpSession
    {
        public int SessionId { get; set; }
        public string SessionName { get; set; }
        public string State { get; set; }
        public string UserName { get; set; }
        public string DomainName { get; set; }
        public string ClientName { get; set; }
        public string ClientAddress { get; set; }
        public bool IsRemote { get; set; }
    }

    public static class WtsReader
    {
        private static readonly IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WTSEnumerateSessions(
            IntPtr hServer,
            int Reserved,
            int Version,
            out IntPtr ppSessionInfo,
            out int pCount);

        [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool WTSQuerySessionInformation(
            IntPtr hServer,
            int sessionId,
            WTS_INFO_CLASS wtsInfoClass,
            out IntPtr ppBuffer,
            out int pBytesReturned);

        [DllImport("wtsapi32.dll")]
        private static extern void WTSFreeMemory(IntPtr memory);

        public static RdpSession[] GetSessions()
        {
            IntPtr buffer = IntPtr.Zero;
            int count = 0;
            if (!WTSEnumerateSessions(WTS_CURRENT_SERVER_HANDLE, 0, 1, out buffer, out count))
            {
                throw new InvalidOperationException("WTSEnumerateSessions failed with Win32 error " + Marshal.GetLastWin32Error());
            }

            try
            {
                int dataSize = Marshal.SizeOf(typeof(WTS_SESSION_INFO));
                long current = buffer.ToInt64();
                List<RdpSession> sessions = new List<RdpSession>();

                for (int i = 0; i < count; i++)
                {
                    WTS_SESSION_INFO info = (WTS_SESSION_INFO)Marshal.PtrToStructure(new IntPtr(current), typeof(WTS_SESSION_INFO));
                    string userName = QueryString(info.SessionID, WTS_INFO_CLASS.WTSUserName);
                    string domainName = QueryString(info.SessionID, WTS_INFO_CLASS.WTSDomainName);
                    string clientName = QueryString(info.SessionID, WTS_INFO_CLASS.WTSClientName);
                    string sessionName = !String.IsNullOrEmpty(info.pWinStationName)
                        ? info.pWinStationName
                        : QueryString(info.SessionID, WTS_INFO_CLASS.WTSWinStationName);

                    bool isRemote = (!String.IsNullOrWhiteSpace(sessionName) && sessionName.StartsWith("RDP-", StringComparison.OrdinalIgnoreCase))
                        || !String.IsNullOrWhiteSpace(clientName);

                    sessions.Add(new RdpSession
                    {
                        SessionId = info.SessionID,
                        SessionName = sessionName ?? "",
                        State = info.State.ToString(),
                        UserName = userName ?? "",
                        DomainName = domainName ?? "",
                        ClientName = clientName ?? "",
                        ClientAddress = QueryClientAddress(info.SessionID),
                        IsRemote = isRemote
                    });

                    current += dataSize;
                }

                return sessions.ToArray();
            }
            finally
            {
                if (buffer != IntPtr.Zero)
                {
                    WTSFreeMemory(buffer);
                }
            }
        }

        private static string QueryString(int sessionId, WTS_INFO_CLASS infoClass)
        {
            IntPtr buffer = IntPtr.Zero;
            int bytesReturned = 0;
            if (!WTSQuerySessionInformation(WTS_CURRENT_SERVER_HANDLE, sessionId, infoClass, out buffer, out bytesReturned) || buffer == IntPtr.Zero)
            {
                return "";
            }

            try
            {
                return Marshal.PtrToStringUni(buffer) ?? "";
            }
            finally
            {
                WTSFreeMemory(buffer);
            }
        }

        private static string QueryClientAddress(int sessionId)
        {
            IntPtr buffer = IntPtr.Zero;
            int bytesReturned = 0;
            if (!WTSQuerySessionInformation(WTS_CURRENT_SERVER_HANDLE, sessionId, WTS_INFO_CLASS.WTSClientAddress, out buffer, out bytesReturned) || buffer == IntPtr.Zero)
            {
                return "";
            }

            try
            {
                WTS_CLIENT_ADDRESS address = (WTS_CLIENT_ADDRESS)Marshal.PtrToStructure(buffer, typeof(WTS_CLIENT_ADDRESS));
                if (address.AddressFamily == 2 && address.Address != null && address.Address.Length >= 6)
                {
                    return String.Format("{0}.{1}.{2}.{3}", address.Address[2], address.Address[3], address.Address[4], address.Address[5]);
                }
                return "";
            }
            finally
            {
                WTSFreeMemory(buffer);
            }
        }
    }
}
"@

    Add-Type -TypeDefinition $source -Language CSharp
    $script:RdpUsageWtsLoaded = $true
}

function Get-RdpUsageSessionMetadataMap {
    $map = @{}

    try {
        $events = Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
            Id        = 21, 25
            StartTime = (Get-Date).AddDays(-14)
        } -ErrorAction Stop

        foreach ($event in $events) {
            [xml]$xml = $event.ToXml()
            $eventData = @{}
            $eventValues = @()
            foreach ($data in $xml.Event.EventData.Data) {
                $value = [string]$data.'#text'
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $eventValues += $value
                }
                if ($data.Name) {
                    $eventData[$data.Name] = $value
                }
            }

            $sessionIdValue = $eventData['SessionID']
            if ([string]::IsNullOrWhiteSpace($sessionIdValue)) {
                $sessionIdValue = $eventData['SessionId']
            }

            if ([string]::IsNullOrWhiteSpace($sessionIdValue)) {
                continue
            }

            $key = [string]$sessionIdValue
            if (-not $map.ContainsKey($key)) {
                $clientAddress = ''
                foreach ($name in 'Address', 'ClientAddress', 'SourceNetworkAddress', 'Source Network Address', 'Client IP') {
                    if ($eventData.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($eventData[$name])) {
                        $clientAddress = [string]$eventData[$name]
                        break
                    }
                }

                if ([string]::IsNullOrWhiteSpace($clientAddress)) {
                    $addressCandidate = $eventValues | Where-Object {
                        $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -or $_ -match ':'
                    } | Select-Object -First 1
                    if ($addressCandidate) {
                        $clientAddress = [string]$addressCandidate
                    }
                }

                $eventUser = ''
                foreach ($name in 'User', 'UserName', 'TargetUserName') {
                    if ($eventData.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($eventData[$name])) {
                        $eventUser = [string]$eventData[$name]
                        break
                    }
                }

                $map[$key] = [pscustomobject]@{
                    connectionStartedUtc = $event.TimeCreated.ToUniversalTime().ToString("o", [Globalization.CultureInfo]::InvariantCulture)
                    clientAddress        = $clientAddress
                    eventUser            = $eventUser
                    sawRemoteEvent       = $true
                }
            }
        }
    }
    catch {
        return @{}
    }

    return $map
}

function Get-RdpUsageCurrentSessions {
    Ensure-RdpUsageWtsHelper

    $metadataMap = Get-RdpUsageSessionMetadataMap
    $sessions = [RdpUsage.Native.WtsReader]::GetSessions()

    return @($sessions | ForEach-Object {
        $metadata = $null
        $key = [string]$_.SessionId
        if ($metadataMap.ContainsKey($key)) {
            $metadata = $metadataMap[$key]
        }

        $clientAddress = $_.ClientAddress
        if ([string]::IsNullOrWhiteSpace($clientAddress) -and $null -ne $metadata) {
            $clientAddress = [string]$metadata.clientAddress
        }

        $isRemote = [bool]$_.IsRemote
        if ($null -ne $metadata -and $metadata.sawRemoteEvent) {
            $isRemote = $true
        }

        $sessionKind = 'Unknown'
        if ($isRemote) {
            $sessionKind = 'Remote'
        }
        elseif ([string]$_.SessionName -eq 'Console') {
            $sessionKind = 'Console'
        }

        $startValue = $null
        if ($null -ne $metadata) {
            $startValue = $metadata.connectionStartedUtc
        }

        [pscustomobject]@{
            sessionId            = $_.SessionId
            sessionName          = $_.SessionName
            state                = $_.State
            sessionKind          = $sessionKind
            userName             = $_.UserName
            domainName           = $_.DomainName
            clientName           = $_.ClientName
            clientAddress        = $clientAddress
            isRemote             = $isRemote
            connectionStartedUtc = $startValue
        }
    })
}

function Get-RdpUsageStatus {
    $sessions = @(Get-RdpUsageCurrentSessions)
    $visibleStates = @('Active', 'Connected', 'ConnectQuery', 'Shadow')
    $allRemoteUserSessions = @($sessions | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.userName) -and $_.isRemote
    })
    $allUserSessions = @($sessions | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_.userName)
    })
    $remoteSessions = @($allRemoteUserSessions | Where-Object {
        $_.state -in $visibleStates
    })
    $userSessions = @($allUserSessions | Where-Object {
        $_.state -in $visibleStates
    })

    $status = 'available'
    if ($remoteSessions.Count -gt 0 -or $userSessions.Count -gt 0) {
        $status = 'busy'
    }

    return [pscustomobject]@{
        version        = '1.0.0'
        checkedAtUtc   = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
        machineName    = $env:COMPUTERNAME
        status         = $status
        isAvailable    = ($status -eq 'available')
        remoteSessions = $remoteSessions
        userSessions   = $userSessions
        allSessions    = $sessions
    }
}

Export-ModuleMember -Function `
    Initialize-RdpUsageStore, `
    Read-RdpUsageStore, `
    Write-RdpUsageStore, `
    ConvertTo-RdpUsageUtc, `
    Format-RdpUsageUtc, `
    Test-RdpUsageReservationOverlap, `
    Add-RdpUsageReservation, `
    Remove-RdpUsageReservation, `
    Get-RdpUsageReservationsForApi, `
    Update-RdpUsageClientHeartbeat, `
    Get-RdpUsageCurrentSessions, `
    Get-RdpUsageStatus
