param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'agent-config.json'),
    [int]$PollSeconds = 10,
    [int]$SoonMinutes = 10
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

$script:Config = $null
$script:NotifyIcon = $null
$script:KnownReservationIds = @{}
$script:SoonNoticeIds = @{}
$script:FirstPoll = $true
$script:LastErrorMessage = ''

function Get-NotifierStateDirectory {
    $directory = Join-Path $env:APPDATA 'RdpUsageTool'
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function Write-NotifierPidFile {
    try {
        Set-Content -LiteralPath (Join-Path (Get-NotifierStateDirectory) 'server-notifier.pid') -Value $PID -Encoding ASCII
    }
    catch {
    }
}

function Remove-NotifierPidFile {
    try {
        $path = Join-Path (Get-NotifierStateDirectory) 'server-notifier.pid'
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

function Read-NotifierConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Agent config was not found: $ConfigPath"
    }

    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.Token) {
        throw "Agent config does not contain a Token."
    }

    $port = 8765
    if ($config.Port) {
        $port = [int]$config.Port
    }

    return [pscustomobject]@{
        serverUrl = "http://localhost:$port"
        token     = [string]$config.Token
    }
}

function New-NotifierIcon {
    $bitmap = New-Object Drawing.Bitmap 16, 16
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::Transparent)

    $brush = New-Object Drawing.SolidBrush([Drawing.Color]::RoyalBlue)
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

function Show-NotifierBalloon {
    param(
        [string]$Title,
        [string]$Message,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )

    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText = $Message
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(7000)
}

function Invoke-AgentApi {
    param([string]$Path)

    $headers = @{ 'X-Rdp-Token' = [string]$script:Config.token }
    return Invoke-RestMethod -Uri "$($script:Config.serverUrl)$Path" -Method GET -Headers $headers -TimeoutSec 5
}

function ConvertTo-LocalTimeText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $dto = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
    return $dto.ToLocalTime().ToString('yyyy-MM-dd HH:mm')
}

function Get-ReservationMessage {
    param([object]$Reservation)

    $start = ConvertTo-LocalTimeText ([string]$Reservation.startUtc)
    $end = ConvertTo-LocalTimeText ([string]$Reservation.endUtc)
    $owner = [string]$Reservation.owner
    $note = [string]$Reservation.note

    $message = "$owner reserved $start - $end"
    if (-not [string]::IsNullOrWhiteSpace($note)) {
        $message = "$message`n$note"
    }

    return $message
}

function Refresh-Reservations {
    try {
        $response = Invoke-AgentApi -Path '/reservations'
        $now = [DateTimeOffset]::Now

        foreach ($reservation in @($response.reservations)) {
            $id = [string]$reservation.id
            if ([string]::IsNullOrWhiteSpace($id)) {
                continue
            }

            if (-not $script:KnownReservationIds.ContainsKey($id)) {
                $script:KnownReservationIds[$id] = $true
                if (-not $script:FirstPoll) {
                    Show-NotifierBalloon -Title 'New RDP Reservation' -Message (Get-ReservationMessage -Reservation $reservation)
                }
            }

            $start = [DateTimeOffset]::Parse([string]$reservation.startUtc, [Globalization.CultureInfo]::InvariantCulture).ToLocalTime()
            $minutes = ($start - $now).TotalMinutes
            if ($minutes -ge 0 -and $minutes -le $SoonMinutes -and -not $script:SoonNoticeIds.ContainsKey($id)) {
                $script:SoonNoticeIds[$id] = $true
                Show-NotifierBalloon -Title 'RDP Reservation Soon' -Message (Get-ReservationMessage -Reservation $reservation)
            }
        }

        $script:FirstPoll = $false
        $script:LastErrorMessage = ''
        $script:NotifyIcon.Text = 'RDP Reservation Notifier'
    }
    catch {
        $message = $_.Exception.Message
        $script:NotifyIcon.Text = 'RDP Notifier: connection issue'
        if ($script:LastErrorMessage -ne $message) {
            $script:LastErrorMessage = $message
            Show-NotifierBalloon -Title 'RDP Notifier Error' -Message $message -Icon ([System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
}

$script:Config = Read-NotifierConfig
Write-NotifierPidFile

$script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Icon = New-NotifierIcon
$script:NotifyIcon.Text = 'RDP Reservation Notifier'

$contextMenu = New-Object Windows.Forms.ContextMenuStrip
$refreshItem = $contextMenu.Items.Add('Refresh')
$refreshItem.Add_Click({ Refresh-Reservations })
$testItem = $contextMenu.Items.Add('Test Notification')
$testItem.Add_Click({ Show-NotifierBalloon -Title 'RDP Reservation Notifier' -Message 'Server reservation notifications are running.' })
[void]$contextMenu.Items.Add('-')
$exitItem = $contextMenu.Items.Add('Exit')
$exitItem.Add_Click({
    $script:NotifyIcon.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$script:NotifyIcon.ContextMenuStrip = $contextMenu

$timer = New-Object Windows.Forms.Timer
$timer.Interval = [Math]::Max(5, $PollSeconds) * 1000
$timer.Add_Tick({ Refresh-Reservations })
$timer.Start()

Refresh-Reservations
[Windows.Forms.Application]::Run()

$timer.Stop()
$script:NotifyIcon.Visible = $false
$script:NotifyIcon.Dispose()
Remove-NotifierPidFile
