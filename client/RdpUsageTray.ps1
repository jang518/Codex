param(
    [string]$ConfigPath = (Join-Path $env:APPDATA 'RdpUsageTool\client-config.json'),
    [int]$PollSeconds = 15
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:Config = $null
$script:MainForm = $null
$script:NotifyIcon = $null
$script:StatusLabel = $null
$script:SessionList = $null
$script:ReservationList = $null
$script:LastAvailable = $null
$script:IconCache = @{}
$script:ReallyExit = $false
$script:Messages = $null

function Read-ClientMessages {
    $fallback = [pscustomobject]@{
        reservationConflictTitle   = 'Reservation Conflict'
        reservationConflictMessage = "The selected time overlaps an existing reservation.`n`nExisting reservation: {0}`nOwner: {1}`n`nPlease choose a different time."
        reservationFailedTitle     = 'Reservation Failed'
        reservationFailedMessage   = "The reservation could not be saved.`n`n{0}"
    }

    $messagesPath = Join-Path $PSScriptRoot 'messages-ko.json'
    if (-not (Test-Path -LiteralPath $messagesPath)) {
        return $fallback
    }

    try {
        return Get-Content -LiteralPath $messagesPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $fallback
    }
}

function Get-ClientMessage {
    param(
        [string]$Name,
        [string]$Fallback
    )

    if ($script:Messages -and (Get-Member -InputObject $script:Messages -Name $Name -MemberType NoteProperty)) {
        return [string]$script:Messages.$Name
    }

    return $Fallback
}

function Get-ClientStateDirectory {
    $directory = Join-Path $env:APPDATA 'RdpUsageTool'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function Write-ClientPidFile {
    try {
        Set-Content -LiteralPath (Join-Path (Get-ClientStateDirectory) 'client.pid') -Value $PID -Encoding ASCII
    }
    catch {
    }
}

function Remove-ClientPidFile {
    try {
        $path = Join-Path (Get-ClientStateDirectory) 'client.pid'
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

function Get-DefaultClientConfig {
    return [pscustomobject]@{
        serverUrl   = 'http://SERVER-PC:8765'
        token       = ''
        displayName = $env:USERNAME
        clientId    = [guid]::NewGuid().ToString('N')
        pollSeconds = $PollSeconds
    }
}

function Read-ClientConfig {
    if (Test-Path -LiteralPath $ConfigPath) {
        $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    else {
        $config = Get-DefaultClientConfig
    }

    if (-not (Get-Member -InputObject $config -Name clientId -MemberType NoteProperty) -or [string]::IsNullOrWhiteSpace($config.clientId)) {
        $config | Add-Member -NotePropertyName clientId -NotePropertyValue ([guid]::NewGuid().ToString('N')) -Force
    }
    if (-not (Get-Member -InputObject $config -Name pollSeconds -MemberType NoteProperty) -or -not $config.pollSeconds) {
        $config | Add-Member -NotePropertyName pollSeconds -NotePropertyValue $PollSeconds -Force
    }

    return $config
}

function Write-ClientConfig {
    param([pscustomobject]$Config)

    $directory = Split-Path -Parent $ConfigPath
    if ($directory -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

function New-StatusIcon {
    param([System.Drawing.Color]$Color)

    $bitmap = New-Object Drawing.Bitmap 16, 16
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)

    $brush = New-Object Drawing.SolidBrush($Color)
    $border = New-Object Drawing.Pen([Drawing.Color]::White, 1.5)
    $graphics.FillEllipse($brush, 2, 2, 12, 12)
    $graphics.DrawEllipse($border, 2, 2, 12, 12)

    $handle = $bitmap.GetHicon()
    $icon = [Drawing.Icon]::FromHandle($handle)

    $border.Dispose()
    $brush.Dispose()
    $graphics.Dispose()
    $bitmap.Dispose()

    return $icon
}

function Get-CachedStatusIcon {
    param(
        [string]$Key,
        [System.Drawing.Color]$Color
    )

    if (-not $script:IconCache.ContainsKey($Key)) {
        $script:IconCache[$Key] = New-StatusIcon -Color $Color
    }

    return $script:IconCache[$Key]
}

function Set-TrayState {
    param(
        [string]$State,
        [string]$Text
    )

    $color = [Drawing.Color]::Gray
    switch ($State) {
        'available' { $color = [Drawing.Color]::ForestGreen }
        'busy' { $color = [Drawing.Color]::Firebrick }
        'disconnected' { $color = [Drawing.Color]::DarkOrange }
        'reservation' { $color = [Drawing.Color]::RoyalBlue }
        default { $color = [Drawing.Color]::Gray }
    }

    $script:NotifyIcon.Icon = Get-CachedStatusIcon -Key $State -Color $color
    $script:NotifyIcon.Text = if ($Text.Length -gt 63) { $Text.Substring(0, 63) } else { $Text }
    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
    }
}

function Show-Balloon {
    param(
        [string]$Title,
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )

    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText = $Message
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(5000)
}

function Invoke-AgentApi {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [object]$Body = $null
    )

    $uri = "$($script:Config.serverUrl.TrimEnd('/'))$Path"
    $headers = @{ 'X-Rdp-Token' = [string]$script:Config.token }

    if ($null -ne $Body) {
        $json = $Body | ConvertTo-Json -Depth 8
        return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -Body $json -ContentType 'application/json; charset=utf-8' -TimeoutSec 5
    }

    return Invoke-RestMethod -Uri $uri -Method $Method -Headers $headers -TimeoutSec 5
}

function ConvertFrom-UtcStringToLocalText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $dto = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    return $dto.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Update-SessionList {
    param([object[]]$Sessions)

    $script:SessionList.Items.Clear()
    foreach ($session in @($Sessions)) {
        $user = if ($session.domainName) { "$($session.domainName)\$($session.userName)" } else { [string]$session.userName }
        $clientDisplay = [string]$session.clientName
        if ([string]::IsNullOrWhiteSpace($clientDisplay)) {
            if ($session.sessionKind) {
                $clientDisplay = [string]$session.sessionKind
            }
            elseif ($session.sessionName) {
                $clientDisplay = [string]$session.sessionName
            }
        }
        $item = New-Object Windows.Forms.ListViewItem($user)
        [void]$item.SubItems.Add([string]$session.state)
        [void]$item.SubItems.Add($clientDisplay)
        [void]$item.SubItems.Add([string]$session.clientAddress)
        [void]$item.SubItems.Add((ConvertFrom-UtcStringToLocalText ([string]$session.connectionStartedUtc)))
        [void]$script:SessionList.Items.Add($item)
    }
}

function Update-ReservationList {
    param([object[]]$Reservations)

    $script:ReservationList.Items.Clear()
    foreach ($reservation in @($Reservations)) {
        $item = New-Object Windows.Forms.ListViewItem((ConvertFrom-UtcStringToLocalText ([string]$reservation.startUtc)))
        [void]$item.SubItems.Add((ConvertFrom-UtcStringToLocalText ([string]$reservation.endUtc)))
        [void]$item.SubItems.Add([string]$reservation.owner)
        [void]$item.SubItems.Add([string]$reservation.note)
        $item.Tag = [string]$reservation.id
        [void]$script:ReservationList.Items.Add($item)
    }
}

function Send-Heartbeat {
    try {
        Invoke-AgentApi -Method POST -Path '/clients/heartbeat' -Body ([pscustomobject]@{
            clientId     = [string]$script:Config.clientId
            displayName  = [string]$script:Config.displayName
            computerName = $env:COMPUTERNAME
        }) | Out-Null
    }
    catch {
    }
}

function Refresh-RdpUsageState {
    try {
        $status = Invoke-AgentApi -Method GET -Path '/status'
        $reservationResponse = Invoke-AgentApi -Method GET -Path '/reservations'
        Send-Heartbeat

        $sessionsToShow = @($status.remoteSessions)
        if ((Get-Member -InputObject $status -Name userSessions -MemberType NoteProperty) -and @($status.userSessions).Count -gt 0) {
            $sessionsToShow = @($status.userSessions)
        }

        Update-SessionList -Sessions $sessionsToShow
        Update-ReservationList -Reservations @($reservationResponse.reservations)

        $stateText = switch ([string]$status.status) {
            'busy' {
                if (@($sessionsToShow).Count -gt 0) {
                    $first = @($sessionsToShow)[0]
                    $where = [string]$first.clientName
                    if ([string]::IsNullOrWhiteSpace($where)) {
                        $where = [string]$first.sessionKind
                    }
                    if (-not [string]::IsNullOrWhiteSpace([string]$first.clientAddress)) {
                        $where = "$where $($first.clientAddress)"
                    }
                    "Busy: $($first.userName) / $where"
                }
                else {
                    'Busy'
                }
            }
            'disconnected' { 'Disconnected RDP session exists' }
            default { 'Available' }
        }

        Set-TrayState -State ([string]$status.status) -Text $stateText

        $isAvailable = [bool]$status.isAvailable
        if ($null -ne $script:LastAvailable -and -not $script:LastAvailable -and $isAvailable) {
            Show-Balloon -Title 'RDP Available' -Message 'The target PC is available now.'
        }
        $script:LastAvailable = $isAvailable

    }
    catch {
        Set-TrayState -State 'error' -Text 'Cannot check status'
        if ($script:StatusLabel) {
            $script:StatusLabel.Text = "Cannot check status: $($_.Exception.Message)"
        }
    }
}

$script:Messages = Read-ClientMessages
$script:Config = Read-ClientConfig
Write-ClientPidFile

$script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Icon = Get-CachedStatusIcon -Key 'initial' -Color ([Drawing.Color]::Gray)
$script:NotifyIcon.Text = 'RDP Usage'

$contextMenu = New-Object Windows.Forms.ContextMenuStrip
$openItem = $contextMenu.Items.Add('Open')
$openItem.Add_Click({ if (-not $script:MainForm.Visible) { $script:MainForm.Show() }; $script:MainForm.Activate() })
$refreshItem = $contextMenu.Items.Add('Refresh')
$refreshItem.Add_Click({ Refresh-RdpUsageState })
$settingsItem = $contextMenu.Items.Add('Settings')
$settingsItem.Add_Click({ })
[void]$contextMenu.Items.Add('-')
$exitItem = $contextMenu.Items.Add('Exit')
$exitItem.Add_Click({
    $script:ReallyExit = $true
    $script:NotifyIcon.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$script:NotifyIcon.ContextMenuStrip = $contextMenu

$script:MainForm = New-Object Windows.Forms.Form
$script:MainForm.Text = 'RDP Usage'
$script:MainForm.StartPosition = 'CenterScreen'
$script:MainForm.ClientSize = New-Object Drawing.Size(760, 520)

$statusLabel = New-Object Windows.Forms.Label
$statusLabel.Text = 'Checking status...'
$statusLabel.Location = New-Object Drawing.Point(16, 16)
$statusLabel.Size = New-Object Drawing.Size(720, 28)
$script:MainForm.Controls.Add($statusLabel)
$script:StatusLabel = $statusLabel

$sessionList = New-Object Windows.Forms.ListView
$sessionList.Location = New-Object Drawing.Point(16, 78)
$sessionList.Size = New-Object Drawing.Size(720, 135)
$sessionList.View = [Windows.Forms.View]::Details
$sessionList.FullRowSelect = $true
$sessionList.GridLines = $true
[void]$sessionList.Columns.Add('User', 150)
[void]$sessionList.Columns.Add('State', 90)
[void]$sessionList.Columns.Add('Client PC', 160)
[void]$sessionList.Columns.Add('IP', 130)
[void]$sessionList.Columns.Add('Connected At', 160)
$script:MainForm.Controls.Add($sessionList)
$script:SessionList = $sessionList

$reservationList = New-Object Windows.Forms.ListView
$reservationList.Location = New-Object Drawing.Point(16, 251)
$reservationList.Size = New-Object Drawing.Size(720, 185)
$reservationList.View = [Windows.Forms.View]::Details
$reservationList.FullRowSelect = $true
$reservationList.GridLines = $true
[void]$reservationList.Columns.Add('Start', 150)
[void]$reservationList.Columns.Add('End', 150)
[void]$reservationList.Columns.Add('Owner', 130)
[void]$reservationList.Columns.Add('Note', 270)
$script:MainForm.Controls.Add($reservationList)
$script:ReservationList = $reservationList

$timer = New-Object Windows.Forms.Timer
$timer.Interval = [Math]::Max(5, [int]$script:Config.pollSeconds) * 1000
$timer.Add_Tick({ Refresh-RdpUsageState })
$timer.Start()

Refresh-RdpUsageState
[Windows.Forms.Application]::Run()

$timer.Stop()
$script:NotifyIcon.Visible = $false
$script:NotifyIcon.Dispose()
foreach ($icon in $script:IconCache.Values) {
    $icon.Dispose()
}
Remove-ClientPidFile
