param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'agent-config.json'),
    [int]$Port = 0,
    [string]$Prefix = '',
    [string]$Token = '',
    [string]$DataPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'RdpUsage.Common.psm1') -Force

function Resolve-AgentConfig {
    $defaultDataPath = Join-Path $PSScriptRoot 'data\agent-store.json'
    $config = [ordered]@{
        Port     = 8765
        Prefix   = 'http://+:8765/'
        Token    = $env:RDP_USAGE_TOKEN
        DataPath = $defaultDataPath
    }

    if (Test-Path -LiteralPath $ConfigPath) {
        $fileConfig = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($name in 'Port', 'Prefix', 'Token', 'DataPath') {
            if ((Get-Member -InputObject $fileConfig -Name $name -MemberType NoteProperty) -and $fileConfig.$name) {
                $config[$name] = [string]$fileConfig.$name
            }
        }
    }

    if ($Port -gt 0) {
        $config['Port'] = $Port
    }
    if (-not [string]::IsNullOrWhiteSpace($Prefix)) {
        $config['Prefix'] = $Prefix
    }
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $config['Token'] = $Token
    }
    if (-not [string]::IsNullOrWhiteSpace($DataPath)) {
        $config['DataPath'] = $DataPath
    }

    if ([string]::IsNullOrWhiteSpace([string]$config['Prefix'])) {
        $config['Prefix'] = "http://+:$($config['Port'])/"
    }

    if ([string]::IsNullOrWhiteSpace([string]$config['Token'])) {
        throw "No API token configured. Set RDP_USAGE_TOKEN or create server\agent-config.json."
    }

    if (-not [IO.Path]::IsPathRooted([string]$config['DataPath'])) {
        $config['DataPath'] = Join-Path $PSScriptRoot ([string]$config['DataPath'])
    }

    return [pscustomobject]$config
}

function Write-AgentPidFile {
    param([string]$DataPath)

    try {
        $directory = Split-Path -Parent $DataPath
        if ($directory -and -not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        Set-Content -LiteralPath (Join-Path $directory 'agent.pid') -Value $PID -Encoding ASCII
    }
    catch {
    }
}

function Remove-AgentPidFile {
    param([string]$DataPath)

    try {
        $directory = Split-Path -Parent $DataPath
        $path = Join-Path $directory 'agent.pid'
        if (Test-Path -LiteralPath $path) {
            $value = (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ([string]$value -eq [string]$PID) {
                Remove-Item -LiteralPath $path -Force
            }
        }
    }
    catch {
    }
}

function Read-RequestJson {
    param([pscustomobject]$Request)

    if ([string]::IsNullOrWhiteSpace($Request.BodyText)) {
        return [pscustomobject]@{}
    }
    return $Request.BodyText | ConvertFrom-Json
}

function Get-HttpReasonPhrase {
    param([int]$StatusCode)

    switch ($StatusCode) {
        200 { 'OK' }
        201 { 'Created' }
        400 { 'Bad Request' }
        401 { 'Unauthorized' }
        404 { 'Not Found' }
        409 { 'Conflict' }
        500 { 'Internal Server Error' }
        default { 'OK' }
    }
}

function Write-JsonResponse {
    param(
        [System.IO.Stream]$Stream,
        [int]$StatusCode,
        [object]$Body
    )

    if ($null -eq $Body) {
        $bodyBytes = New-Object byte[] 0
    }
    else {
        $json = $Body | ConvertTo-Json -Depth 14
        $bodyBytes = [Text.Encoding]::UTF8.GetBytes($json)
    }

    $reason = Get-HttpReasonPhrase -StatusCode $StatusCode
    $headerText = "HTTP/1.1 $StatusCode $reason`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: $($bodyBytes.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headerBytes = [Text.Encoding]::ASCII.GetBytes($headerText)
    $Stream.Write($headerBytes, 0, $headerBytes.Length)
    if ($bodyBytes.Length -gt 0) {
        $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
    }
    $Stream.Flush()
}

function Test-AgentAuthorization {
    param(
        [pscustomobject]$Request,
        [string]$ExpectedToken
    )

    $provided = if ($Request.Headers.ContainsKey('X-Rdp-Token')) { $Request.Headers['X-Rdp-Token'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($provided)) {
        $authorization = if ($Request.Headers.ContainsKey('Authorization')) { $Request.Headers['Authorization'] } else { '' }
        if ($authorization -and $authorization.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) {
            $provided = $authorization.Substring(7)
        }
    }

    return (-not [string]::IsNullOrWhiteSpace($provided) -and [string]::Equals($provided, $ExpectedToken, [StringComparison]::Ordinal))
}

function Read-TcpHttpRequest {
    param([System.Net.Sockets.TcpClient]$Client)

    $stream = $Client.GetStream()
    $buffer = New-Object byte[] 4096
    $data = New-Object 'System.Collections.Generic.List[byte]'
    $headerEnd = -1

    while ($headerEnd -lt 0) {
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            throw 'Client closed the connection before sending a request.'
        }

        for ($i = 0; $i -lt $read; $i++) {
            $data.Add($buffer[$i])
        }

        if ($data.Count -gt 65536) {
            throw 'HTTP request headers are too large.'
        }

        $text = [Text.Encoding]::ASCII.GetString($data.ToArray())
        $headerEnd = $text.IndexOf("`r`n`r`n", [StringComparison]::Ordinal)
    }

    $allBytes = $data.ToArray()
    $headerLength = $headerEnd + 4
    $headerText = [Text.Encoding]::ASCII.GetString($allBytes, 0, $headerEnd)
    $lines = $headerText -split "`r`n"
    if ($lines.Count -eq 0) {
        throw 'Missing HTTP request line.'
    }

    $requestParts = $lines[0].Split(' ')
    if ($requestParts.Count -lt 2) {
        throw "Invalid HTTP request line: $($lines[0])"
    }

    $headers = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::OrdinalIgnoreCase)
    for ($lineIndex = 1; $lineIndex -lt $lines.Count; $lineIndex++) {
        $line = $lines[$lineIndex]
        $separator = $line.IndexOf(':')
        if ($separator -le 0) {
            continue
        }

        $name = $line.Substring(0, $separator).Trim()
        $value = $line.Substring($separator + 1).Trim()
        $headers[$name] = $value
    }

    $contentLength = 0
    if ($headers.ContainsKey('Content-Length')) {
        $contentLength = [int]$headers['Content-Length']
    }

    $bodyBytes = New-Object byte[] $contentLength
    $alreadyRead = [Math]::Min($contentLength, $allBytes.Length - $headerLength)
    if ($alreadyRead -gt 0) {
        [Array]::Copy($allBytes, $headerLength, $bodyBytes, 0, $alreadyRead)
    }

    $offset = $alreadyRead
    while ($offset -lt $contentLength) {
        $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
        if ($read -le 0) {
            throw 'Client closed the connection before sending the request body.'
        }
        $offset += $read
    }

    $target = [string]$requestParts[1]
    $queryStart = $target.IndexOf('?')
    $path = if ($queryStart -ge 0) { $target.Substring(0, $queryStart) } else { $target }

    return [pscustomobject]@{
        Method   = ([string]$requestParts[0]).ToUpperInvariant()
        Path     = $path
        Headers  = $headers
        BodyText = [Text.Encoding]::UTF8.GetString($bodyBytes)
        Stream   = $stream
    }
}

function Invoke-AgentRequest {
    param(
        [pscustomobject]$Request,
        [pscustomobject]$Config
    )

    $path = $Request.Path.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($path)) {
        $path = '/'
    }

    if ($Request.Method -eq 'GET' -and $path -eq '/health') {
        Write-JsonResponse -Stream $Request.Stream -StatusCode 200 -Body ([pscustomobject]@{
            ok           = $true
            version      = '1.0.0'
            machineName  = $env:COMPUTERNAME
            checkedAtUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
        })
        return
    }

    if (-not (Test-AgentAuthorization -Request $Request -ExpectedToken $Config.Token)) {
        Write-JsonResponse -Stream $Request.Stream -StatusCode 401 -Body ([pscustomobject]@{
            error   = 'unauthorized'
            message = 'Missing or invalid API token.'
        })
        return
    }

    switch -Regex ("$($Request.Method) $path") {
        '^GET /status$' {
            Write-JsonResponse -Stream $Request.Stream -StatusCode 200 -Body (Get-RdpUsageStatus)
            return
        }

        '^GET /reservations$' {
            $store = Read-RdpUsageStore -Path $Config.DataPath
            Write-JsonResponse -Stream $Request.Stream -StatusCode 200 -Body ([pscustomobject]@{
                reservations = @(Get-RdpUsageReservationsForApi -Store $store)
                checkedAtUtc = Format-RdpUsageUtc ([DateTimeOffset]::UtcNow)
            })
            return
        }

        '^POST /reservations$' {
            $body = Read-RequestJson -Request $Request
            $store = Read-RdpUsageStore -Path $Config.DataPath

            try {
                $reservation = Add-RdpUsageReservation `
                    -Store $store `
                    -Owner ([string]$body.owner) `
                    -StartUtc (ConvertTo-RdpUsageUtc $body.startUtc) `
                    -EndUtc (ConvertTo-RdpUsageUtc $body.endUtc) `
                    -Note ([string]$body.note) `
                    -ClientId ([string]$body.clientId)

                Write-RdpUsageStore -Path $Config.DataPath -Store $store
                Write-JsonResponse -Stream $Request.Stream -StatusCode 201 -Body $reservation
            }
            catch {
                $message = $_.Exception.Message
                if ($message.StartsWith('ReservationConflict:', [StringComparison]::OrdinalIgnoreCase)) {
                    $conflict = [pscustomobject]@{
                        id       = [string]$_.Exception.Data['conflictId']
                        owner    = [string]$_.Exception.Data['conflictOwner']
                        startUtc = [string]$_.Exception.Data['conflictStartUtc']
                        endUtc   = [string]$_.Exception.Data['conflictEndUtc']
                        note     = [string]$_.Exception.Data['conflictNote']
                    }
                    Write-JsonResponse -Stream $Request.Stream -StatusCode 409 -Body ([pscustomobject]@{
                        error   = 'reservation_conflict'
                        message = 'The requested reservation time overlaps an existing reservation.'
                        conflict = $conflict
                    })
                }
                else {
                    Write-JsonResponse -Stream $Request.Stream -StatusCode 400 -Body ([pscustomobject]@{
                        error   = 'invalid_reservation'
                        message = $message
                    })
                }
            }
            return
        }

        '^DELETE /reservations/([^/]+)$' {
            $id = $Matches[1]
            $store = Read-RdpUsageStore -Path $Config.DataPath
            if (Remove-RdpUsageReservation -Store $store -Id $id) {
                Write-RdpUsageStore -Path $Config.DataPath -Store $store
                Write-JsonResponse -Stream $Request.Stream -StatusCode 200 -Body ([pscustomobject]@{ deleted = $true; id = $id })
            }
            else {
                Write-JsonResponse -Stream $Request.Stream -StatusCode 404 -Body ([pscustomobject]@{
                    error   = 'not_found'
                    message = "Reservation '$id' was not found."
                })
            }
            return
        }

        '^POST /clients/heartbeat$' {
            $body = Read-RequestJson -Request $Request
            $store = Read-RdpUsageStore -Path $Config.DataPath
            $client = Update-RdpUsageClientHeartbeat `
                -Store $store `
                -ClientId ([string]$body.clientId) `
                -DisplayName ([string]$body.displayName) `
                -ComputerName ([string]$body.computerName)

            Write-RdpUsageStore -Path $Config.DataPath -Store $store
            Write-JsonResponse -Stream $Request.Stream -StatusCode 200 -Body ([pscustomobject]@{
                ok     = $true
                client = $client
            })
            return
        }

        default {
            Write-JsonResponse -Stream $Request.Stream -StatusCode 404 -Body ([pscustomobject]@{
                error   = 'not_found'
                message = "No route for $($Request.Method) $path."
            })
        }
    }
}

$config = Resolve-AgentConfig
Initialize-RdpUsageStore -Path $config.DataPath
Write-AgentPidFile -DataPath $config.DataPath

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, [int]$config.Port)

try {
    $listener.Start()
    Write-Host "RDP Usage Agent listening on port $($config.Port)"
    Write-Host "Data path: $($config.DataPath)"

    while ($true) {
        $client = $listener.AcceptTcpClient()
        try {
            $request = Read-TcpHttpRequest -Client $client
            Invoke-AgentRequest -Request $request -Config $config
        }
        catch {
            try {
                Write-JsonResponse -Stream $client.GetStream() -StatusCode 500 -Body ([pscustomobject]@{
                    error   = 'server_error'
                    message = $_.Exception.Message
                })
            }
            catch {
            }
        }
        finally {
            if ($client) {
                $client.Close()
            }
        }
    }
}
finally {
    $listener.Stop()
    Remove-AgentPidFile -DataPath $config.DataPath
}
