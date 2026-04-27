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
    try { Set-Content -LiteralPath (Join-Path (Get-NotifierStateDirectory) 'server-notifier.pid') -Value $PID -Encoding ASCII } catch {}
}

function Remove-NotifierPidFile {
    try {
        $path = Join-Path (Get-NotifierStateDirectory) 'server-notifier.pid'
        if (Test-Path -LiteralPath $path) {
            $value = (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ([string]$value -eq [string]$PID) { Remove-Item -LiteralPath $path -Force }
        }
    } catch {}
}

function Read-NotifierConfig {
    $config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $port = 8765
    if ($config.Port) { $port = [int]$config.Port }
    return [pscustomobject]@{ serverUrl = "http://localhost:$port"; token = [string]$config.Token }
}

function Show-NotifierBalloon {
    param([string]$Title,[string]$Message,[System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info)
    $script:NotifyIcon.BalloonTipTitle = $Title
    $script:NotifyIcon.BalloonTipText = $Message
    $script:NotifyIcon.BalloonTipIcon = $Icon
    $script:NotifyIcon.ShowBalloonTip(7000)
}

$script:Config = Read-NotifierConfig
Write-NotifierPidFile
$script:NotifyIcon = New-Object Windows.Forms.NotifyIcon
$script:NotifyIcon.Visible = $true
$script:NotifyIcon.Text = 'RDP Reservation Notifier'
[Windows.Forms.Application]::Run()
Remove-NotifierPidFile
