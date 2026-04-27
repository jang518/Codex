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

function Show-SettingsDialog {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'RDP Usage Settings'
    $form.StartPosition = 'CenterScreen'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(460, 190)

    $serverLabel = New-Object Windows.Forms.Label
    $serverLabel.Text = 'Server URL'
    $serverLabel.Location = New-Object Drawing.Point(16, 22)
    $serverLabel.AutoSize = $true
    $form.Controls.Add($serverLabel)

    $serverBox = New-Object Windows.Forms.TextBox
    $serverBox.Location = New-Object Drawing.Point(130, 18)
    $serverBox.Size = New-Object Drawing.Size(300, 24)
    $serverBox.Text = [string]$script:Config.serverUrl
    $form.Controls.Add($serverBox)

    $tokenLabel = New-Object Windows.Forms.Label
    $tokenLabel.Text = 'Token'
    $tokenLabel.Location = New-Object Drawing.Point(16, 62)
    $tokenLabel.AutoSize = $true
    $form.Controls.Add($tokenLabel)

    $tokenBox = New-Object Windows.Forms.TextBox
    $tokenBox.Location = New-Object Drawing.Point(130, 58)
    $tokenBox.Size = New-Object Drawing.Size(300, 24)
    $tokenBox.Text = [string]$script:Config.token
    $tokenBox.UseSystemPasswordChar = $true
    $form.Controls.Add($tokenBox)

    $nameLabel = New-Object Windows.Forms.Label
    $nameLabel.Text = 'Display Name'
    $nameLabel.Location = New-Object Drawing.Point(16, 102)
    $nameLabel.AutoSize = $true
    $form.Controls.Add($nameLabel)

    $nameBox = New-Object Windows.Forms.TextBox
    $nameBox.Location = New-Object Drawing.Point(130, 98)
    $nameBox.Size = New-Object Drawing.Size(300, 24)
    $nameBox.Text = [string]$script:Config.displayName
    $form.Controls.Add($nameBox)

    $okButton = New-Object Windows.Forms.Button
    $okButton.Text = 'Save'
    $okButton.Location = New-Object Drawing.Point(270, 145)
    $okButton.Size = New-Object Drawing.Size(75, 28)
    $okButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object Drawing.Point(355, 145)
    $cancelButton.Size = New-Object Drawing.Size(75, 28)
    $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
        if ([string]::IsNullOrWhiteSpace($serverBox.Text) -or [string]::IsNullOrWhiteSpace($tokenBox.Text) -or [string]::IsNullOrWhiteSpace($nameBox.Text)) {
            [Windows.Forms.MessageBox]::Show('Server URL, Token, and Display Name are required.', 'Settings Error', 'OK', 'Warning') | Out-Null
            return $false
        }

        $script:Config.serverUrl = $serverBox.Text.Trim().TrimEnd('/')
        $script:Config.token = $tokenBox.Text.Trim()
        $script:Config.displayName = $nameBox.Text.Trim()
        Write-ClientConfig -Config $script:Config
        return $true
    }

    return $false
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

function Get-AgentErrorBody {
    param([object]$ErrorRecord)

    try {
        if ($ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
            return $ErrorRecord.ErrorDetails.Message | ConvertFrom-Json
        }
    }
    catch {
    }

    try {
        $response = $ErrorRecord.Exception.Response
        if ($response) {
            $stream = $response.GetResponseStream()
            if ($stream) {
                $reader = New-Object IO.StreamReader($stream)
                try {
                    $text = $reader.ReadToEnd()
                    if (-not [string]::IsNullOrWhiteSpace($text)) {
                        return $text | ConvertFrom-Json
                    }
                }
                finally {
                    $reader.Dispose()
                }
            }
        }
    }
    catch {
    }

    return $null
}

function Get-ReservationFailureMessage {
    param([object]$ErrorRecord)

    $body = Get-AgentErrorBody -ErrorRecord $ErrorRecord
    if ($body -and [string]$body.error -eq 'reservation_conflict') {
        $title = Get-ClientMessage -Name 'reservationConflictTitle' -Fallback 'Reservation Conflict'
        $range = 'Unknown'
        $owner = 'Unknown'

        if ($body.conflict) {
            $start = ConvertFrom-UtcStringToLocalText ([string]$body.conflict.startUtc)
            $end = ConvertFrom-UtcStringToLocalText ([string]$body.conflict.endUtc)
            if (-not [string]::IsNullOrWhiteSpace($start) -and -not [string]::IsNullOrWhiteSpace($end)) {
                $range = "$start - $end"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$body.conflict.owner)) {
                $owner = [string]$body.conflict.owner
            }
        }

        $template = Get-ClientMessage `
            -Name 'reservationConflictMessage' `
            -Fallback "The selected time overlaps an existing reservation.`n`nExisting reservation: {0}`nOwner: {1}`n`nPlease choose a different time."

        return [pscustomobject]@{
            Title   = $title
            Message = [string]::Format($template, $range, $owner)
        }
    }

    $message = $ErrorRecord.Exception.Message
    if ($body -and -not [string]::IsNullOrWhiteSpace([string]$body.message)) {
        $message = [string]$body.message
    }

    $failedTemplate = Get-ClientMessage `
        -Name 'reservationFailedMessage' `
        -Fallback "The reservation could not be saved.`n`n{0}"

    return [pscustomobject]@{
        Title   = Get-ClientMessage -Name 'reservationFailedTitle' -Fallback 'Reservation Failed'
        Message = [string]::Format($failedTemplate, $message)
    }
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

function Show-NewReservationDialog {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'New Reservation'
    $form.StartPosition = 'CenterParent'
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object Drawing.Size(430, 240)

    $ownerLabel = New-Object Windows.Forms.Label
    $ownerLabel.Text = 'Owner'
    $ownerLabel.Location = New-Object Drawing.Point(16, 22)
    $ownerLabel.AutoSize = $true
    $form.Controls.Add($ownerLabel)

    $ownerBox = New-Object Windows.Forms.TextBox
    $ownerBox.Location = New-Object Drawing.Point(120, 18)
    $ownerBox.Size = New-Object Drawing.Size(280, 24)
    $ownerBox.Text = [string]$script:Config.displayName
    $form.Controls.Add($ownerBox)

    $startLabel = New-Object Windows.Forms.Label
    $startLabel.Text = 'Start'
    $startLabel.Location = New-Object Drawing.Point(16, 62)
    $startLabel.AutoSize = $true
    $form.Controls.Add($startLabel)

    $startPicker = New-Object Windows.Forms.DateTimePicker
    $startPicker.Location = New-Object Drawing.Point(120, 58)
    $startPicker.Size = New-Object Drawing.Size(180, 24)
    $startPicker.Format = [Windows.Forms.DateTimePickerFormat]::Custom
    $startPicker.CustomFormat = 'yyyy-MM-dd HH:mm'
    $startPicker.Value = (Get-Date).AddMinutes(10)
    $form.Controls.Add($startPicker)

    $endLabel = New-Object Windows.Forms.Label
    $endLabel.Text = 'End'
    $endLabel.Location = New-Object Drawing.Point(16, 102)
    $endLabel.AutoSize = $true
    $form.Controls.Add($endLabel)

    $endPicker = New-Object Windows.Forms.DateTimePicker
    $endPicker.Location = New-Object Drawing.Point(120, 98)
    $endPicker.Size = New-Object Drawing.Size(180, 24)
    $endPicker.Format = [Windows.Forms.DateTimePickerFormat]::Custom
    $endPicker.CustomFormat = 'yyyy-MM-dd HH:mm'
    $endPicker.Value = (Get-Date).AddHours(1)
    $form.Controls.Add($endPicker)

    $noteLabel = New-Object Windows.Forms.Label
    $noteLabel.Text = 'Note'
    $noteLabel.Location = New-Object Drawing.Point(16, 142)
    $noteLabel.AutoSize = $true
    $form.Controls.Add($noteLabel)

    $noteBox = New-Object Windows.Forms.TextBox
    $noteBox.Location = New-Object Drawing.Point(120, 138)
    $noteBox.Size = New-Object Drawing.Size(280, 24)
    $form.Controls.Add($noteBox)

    $okButton = New-Object Windows.Forms.Button
    $okButton.Text = 'Reserve'
    $okButton.Location = New-Object Drawing.Point(240, 195)
    $okButton.Size = New-Object Drawing.Size(75, 28)
    $okButton.DialogResult = [Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object Windows.Forms.Button
    $cancelButton.Text = 'Cancel'
    $cancelButton.Location = New-Object Drawing.Point(325, 195)
    $cancelButton.Size = New-Object Drawing.Size(75, 28)
    $cancelButton.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    if ($form.ShowDialog($script:MainForm) -eq [Windows.Forms.DialogResult]::OK) {
        try {
            $startUtc = ([DateTimeOffset]$startPicker.Value).ToUniversalTime().ToString('o')
            $endUtc = ([DateTimeOffset]$endPicker.Value).ToUniversalTime().ToString('o')

            Invoke-AgentApi -Method POST -Path '/reservations' -Body ([pscustomobject]@{
                owner    = $ownerBox.Text.Trim()
                startUtc = $startUtc
                endUtc   = $endUtc
                note     = $noteBox.Text.Trim()
                clientId = [string]$script:Config.clientId
            }) | Out-Null

            Refresh-RdpUsageState
        }
        catch {
            $failure = Get-ReservationFailureMessage -ErrorRecord $_
            [Windows.Forms.MessageBox]::Show($failure.Message, $failure.Title, 'OK', 'Warning') | Out-Null
        }
    }
}

function Remove-SelectedReservation {
    if ($script:ReservationList.SelectedItems.Count -eq 0) {
        return
    }

    $item = $script:ReservationList.SelectedItems[0]
    $id = [string]$item.Tag
    if ([Windows.Forms.MessageBox]::Show('Delete the selected reservation?', 'Delete Reservation', 'YesNo', 'Question') -ne [Windows.Forms.DialogResult]::Yes) {
        return
    }

    try {
        Invoke-AgentApi -Method DELETE -Path "/reservations/$id" | Out-Null
        Refresh-RdpUsageState
    }
    catch {
        [Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Delete Failed', 'OK', 'Warning') | Out-Null
    }
}

function Show-MainWindow {
    if (-not $script:MainForm.Visible) {
        $script:MainForm.Show()
    }
    if ($script:MainForm.WindowState -eq [Windows.Forms.FormWindowState]::Minimized) {
        $script:MainForm.WindowState = [Windows.Forms.FormWindowState]::Normal
    }
    $script:MainForm.Activate()
}

function New-MainForm {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'RDP Usage'
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object Drawing.Size(760, 520)
    $form.MinimumSize = New-Object Drawing.Size(700, 460)

    $statusLabel = New-Object Windows.Forms.Label
    $statusLabel.Text = 'Checking status...'
    $statusLabel.Location = New-Object Drawing.Point(16, 16)
    $statusLabel.Size = New-Object Drawing.Size(720, 28)
    $statusLabel.Font = New-Object Drawing.Font($statusLabel.Font.FontFamily, 11, [Drawing.FontStyle]::Bold)
    $form.Controls.Add($statusLabel)
    $script:StatusLabel = $statusLabel

    $sessionLabel = New-Object Windows.Forms.Label
    $sessionLabel.Text = 'Current RDP Sessions'
    $sessionLabel.Location = New-Object Drawing.Point(16, 55)
    $sessionLabel.AutoSize = $true
    $form.Controls.Add($sessionLabel)

    $sessionList = New-Object Windows.Forms.ListView
    $sessionList.Location = New-Object Drawing.Point(16, 78)
    $sessionList.Size = New-Object Drawing.Size(720, 135)
    $sessionList.Anchor = 'Top,Left,Right'
    $sessionList.View = [Windows.Forms.View]::Details
    $sessionList.FullRowSelect = $true
    $sessionList.GridLines = $true
    [void]$sessionList.Columns.Add('User', 150)
    [void]$sessionList.Columns.Add('State', 90)
    [void]$sessionList.Columns.Add('Client PC', 160)
    [void]$sessionList.Columns.Add('IP', 130)
    [void]$sessionList.Columns.Add('Connected At', 160)
    $form.Controls.Add($sessionList)
    $script:SessionList = $sessionList

    $reservationLabel = New-Object Windows.Forms.Label
    $reservationLabel.Text = 'Reservations'
    $reservationLabel.Location = New-Object Drawing.Point(16, 228)
    $reservationLabel.AutoSize = $true
    $form.Controls.Add($reservationLabel)

    $reservationList = New-Object Windows.Forms.ListView
    $reservationList.Location = New-Object Drawing.Point(16, 251)
    $reservationList.Size = New-Object Drawing.Size(720, 185)
    $reservationList.Anchor = 'Top,Bottom,Left,Right'
    $reservationList.View = [Windows.Forms.View]::Details
    $reservationList.FullRowSelect = $true
    $reservationList.GridLines = $true
    [void]$reservationList.Columns.Add('Start', 150)
    [void]$reservationList.Columns.Add('End', 150)
    [void]$reservationList.Columns.Add('Owner', 130)
    [void]$reservationList.Columns.Add('Note', 270)
    $form.Controls.Add($reservationList)
    $script:ReservationList = $reservationList

    $refreshButton = New-Object Windows.Forms.Button
    $refreshButton.Text = 'Refresh'
    $refreshButton.Location = New-Object Drawing.Point(16, 455)
    $refreshButton.Size = New-Object Drawing.Size(90, 30)
    $refreshButton.Anchor = 'Bottom,Left'
    $refreshButton.Add_Click({ Refresh-RdpUsageState })
    $form.Controls.Add($refreshButton)

    $newButton = New-Object Windows.Forms.Button
    $newButton.Text = 'New'
    $newButton.Location = New-Object Drawing.Point(116, 455)
    $newButton.Size = New-Object Drawing.Size(90, 30)
    $newButton.Anchor = 'Bottom,Left'
    $newButton.Add_Click({ Show-NewReservationDialog })
    $form.Controls.Add($newButton)

    $deleteButton = New-Object Windows.Forms.Button
    $deleteButton.Text = 'Delete'
    $deleteButton.Location = New-Object Drawing.Point(216, 455)
    $deleteButton.Size = New-Object Drawing.Size(90, 30)
    $deleteButton.Anchor = 'Bottom,Left'
    $deleteButton.Add_Click({ Remove-SelectedReservation })
    $form.Controls.Add($deleteButton)

    $settingsButton = New-Object Windows.Forms.Button
    $settingsButton.Text = 'Settings'
    $settingsButton.Location = New-Object Drawing.Point(646, 455)
    $settingsButton.Size = New-Object Drawing.Size(90, 30)
    $settingsButton.Anchor = 'Bottom,Right'
    $settingsButton.Add_Click({
        if (Show-SettingsDialog) {
            Refresh-RdpUsageState
        }
    })
    $form.Controls.Add($settingsButton)

    $form.Add_FormClosing({
        if (-not $script:ReallyExit) {
            $_.Cancel = $true
            $script:MainForm.Hide()
        }
    })

    return $form
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
$openItem.Add_Click({ Show-MainWindow })
$refreshItem = $contextMenu.Items.Add('Refresh')
$refreshItem.Add_Click({ Refresh-RdpUsageState })
$settingsItem = $contextMenu.Items.Add('Settings')
$settingsItem.Add_Click({
    if (Show-SettingsDialog) {
        Refresh-RdpUsageState
    }
})
[void]$contextMenu.Items.Add('-')
$exitItem = $contextMenu.Items.Add('Exit')
$exitItem.Add_Click({
    $script:ReallyExit = $true
    $script:NotifyIcon.Visible = $false
    [Windows.Forms.Application]::Exit()
})
$script:NotifyIcon.ContextMenuStrip = $contextMenu
$script:NotifyIcon.Add_DoubleClick({ Show-MainWindow })

$script:MainForm = New-MainForm

$initialSetupCompleted = $false
if ([string]::IsNullOrWhiteSpace($script:Config.token) -or [string]$script:Config.serverUrl -eq 'http://SERVER-PC:8765') {
    $initialSetupCompleted = Show-SettingsDialog
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = [Math]::Max(5, [int]$script:Config.pollSeconds) * 1000
$timer.Add_Tick({ Refresh-RdpUsageState })
$timer.Start()

Refresh-RdpUsageState
if ($initialSetupCompleted) {
    Show-MainWindow
    Show-Balloon -Title 'RDP Usage' -Message 'Settings saved. The status window is open.'
}

[Windows.Forms.Application]::Run()

$timer.Stop()
$script:NotifyIcon.Visible = $false
$script:NotifyIcon.Dispose()
foreach ($icon in $script:IconCache.Values) {
    $icon.Dispose()
}
Remove-ClientPidFile
