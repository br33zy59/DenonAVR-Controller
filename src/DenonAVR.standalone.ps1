# Global connection objects
$Global:DenonClient = $null
$Global:DenonStream = $null
$Global:DenonWriter = $null
$Global:DenonReader = $null
$Global:VolumeGuard = $false

$DenonInputMap = @{
    "SITV"     = "TV"
    "SIBD"     = "Blu-ray"
    "SISAT"    = "Satellite"
    "SIGAME"   = "Game Console"
    "SIMPLAY"  = "Media Player"
    "SIAUX1"   = "Aux 1"
    "SIAUX2"   = "Aux 2"
    "SICD"     = "CD Player"
    "SITUNER"  = "Tuner"
    "SINET"    = "Network Audio (HEOS)"
}

$DenonModeMap = @{
    "MSDOLBY DIGITAL" = "Dolby Digital"
    "MSDTS"           = "DTS"
    "MSDTS-HD"        = "DTS-HD"
    "MSDOLBY ATMOS"   = "Dolby Atmos"
    "MSSTEREO"        = "Stereo"
    "MSMCH STEREO"    = "Multi‑Channel Stereo"
    "MSAUTO"          = "Auto Surround"
    "MSPURE DIRECT"   = "Pure Direct"
}

$DenonMuteMap = @{
    "MUON"  = "Muted"
    "MUOFF" = "Unmuted"
}

$DenonPowerMap = @{
    "PWON"      = "On"
    "PWSTANDBY" = "Standby"
}

$DenonChannelMap = @{
    "FL" = "Front Left"
    "FR" = "Front Right"
    "C"  = "Center"
    "SW" = "Subwoofer"
    "SL" = "Surround Left"
    "SR" = "Surround Right"
    "SBL" = "Surround Back Left"
    "SBR" = "Surround Back Right"
}

function Connect-DenonAVR {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Address,
        [int]$Port = 23,
        [int]$TimeoutMs = 5000
    )

    if ($Global:DenonClient -and $Global:DenonClient.Connected) {
        Update-Status "Already connected."
        return
    }

    Update-Status "Connecting to ${Address}:$Port..."

    $client = New-Object System.Net.Sockets.TcpClient
    $cts = New-Object System.Threading.CancellationTokenSource
    $task = $client.ConnectAsync($Address, $Port)

    # Wait for either the connect OR the timeout
    $completed = [System.Threading.Tasks.Task]::WaitAny(@($task), $TimeoutMs)

    if ($completed -ne 0 -or -not $client.Connected) {
        # Timeout or failure
        $cts.Cancel()
        $client.Close()
        Update-Status "Connection failed or timed out"
        throw
    }

    # Connected successfully
    $Global:DenonClient = $client
    $Global:DenonStream = $client.GetStream()
    $Global:DenonWriter = New-Object System.IO.StreamWriter($Global:DenonStream)
    $Global:DenonReader = New-Object System.IO.StreamReader($Global:DenonStream)
    $Global:DenonWriter.AutoFlush = $true

    Update-Status "Connected to ${Address}:$Port"
}

function Disconnect-DenonAVR {
    if ($Global:DenonClient) {
        $Global:DenonReader.Close()
        $Global:DenonWriter.Close()
        $Global:DenonStream.Close()
        $Global:DenonClient.Close()
        $Global:DenonClient = $null
        Update-Status "Disconnected"
    }
}

function Receive-DenonLine {
    param(
        [int]$TimeoutMs = 500
    )

    if (-not $Global:DenonStream) {
        return $null
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sb = New-Object System.Text.StringBuilder

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($Global:DenonStream.DataAvailable) {
            $b = $Global:DenonStream.ReadByte()
            if ($b -eq -1) { break }

            $ch = [char]$b
            if ($ch -eq "`r") { break }

            [void]$sb.Append($ch)
        } else {
            Start-Sleep -Milliseconds 10
        }
    }

    $line = $sb.ToString().Trim()
    if ($line.Length -gt 0) { $line } else { $null }
}

function Receive-DenonChannelBlock {
    param(
        [int]$TimeoutMs = 1000
    )

    $lines = @()
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {

        $line = Receive-DenonLine -TimeoutMs 200
        if (-not $line) { continue }

        # Only accept CV lines
        if ($line.StartsWith("CV")) {
            $lines += $line

            if ($line -eq "CVEND") {
                break
            }
        }
    }

    return $lines
}

function Convert-DenonFriendly {
    param(
        [string]$Raw,
        [hashtable]$Map
    )

    foreach ($key in $Map.Keys) {
        if ($Raw.StartsWith($key)) {
            return $Map[$key]
        }
    }

    return $Raw   # fallback to raw if unknown
}

function Convert-DenonChannels {
    param([string[]]$Lines)

    $output = ""

    foreach ($line in $Lines) {
        if ($line -eq "CVEND") { continue }

        # Example: "CVFL 0.0"
        if ($line -match "^CV([A-Z]+)\s+(.+)$") {
            $code = $Matches[1]
            $val  = $Matches[2]

            if ($DenonChannelMap.ContainsKey($code)) {
                $name = $DenonChannelMap[$code]
            } else {
                $name = $code
            }

            $output += ("{0}: {1} dB`r`n" -f $name, $val)
        }
    }

    return $output.Trim()
}


function Send-DenonQuery {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,

        [Parameter(Mandatory=$true)]
        [string]$ExpectedPrefix
    )

    # Flush pending data
    while ($Global:DenonStream.DataAvailable) {
        [void](Receive-DenonLine -TimeoutMs 50)
    }

    # Send command
    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Command + "`r")
    $Global:DenonStream.Write($bytes, 0, $bytes.Length)

    # Special case: channel trims (multi-line)
    if ($ExpectedPrefix -eq "CV") {
        return Receive-DenonChannelBlock
    }

    # Normal single-line response
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt 1000) {
        $line = Receive-DenonLine -TimeoutMs 200
        if (-not $line) { continue }

        if ($ExpectedPrefix -eq "MV") {
            # Accept ONLY MVxx or MVxxx (2–3 digits)
            if ($line -match "^MV\d{2,3}$") {
                return $line
            }
            continue
        }

        if ($line.StartsWith($ExpectedPrefix)) {
            return $line
        }
    }

    return ""
}


function Send-DenonCommand {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command
    )

    if (-not $Global:DenonClient -or -not $Global:DenonClient.Connected) {
        throw "Not connected. Run Connect-DenonAVR first."
    }

    $bytes = [System.Text.Encoding]::ASCII.GetBytes($Command + "`r")
    $Global:DenonStream.Write($bytes, 0, $bytes.Length)
}


function Set-DenonVolume {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateRange(0, 98)]
        [int]$Level
    )

    $cmd = "MV$Level"
    Send-DenonCommand -Command $cmd
}

function Set-DenonPower {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("On","Off")]
        [string]$State
    )

    $cmd = if ($State -eq "On") { "PWON" } else { "PWSTANDBY" }
    Send-DenonCommand -Command $cmd
}

function Set-DenonInput {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("TV","BD","SAT","GAME","MPLAY","AUX1","AUX2")]
        [string]$Input
    )

    $cmd = "SI$Input"
    Send-DenonCommand -Command $cmd
}

function Get-DenonFullStatus {

    if (-not $Global:DenonClient -or -not $Global:DenonClient.Connected) {
        return "Not connected."
    }

    $rawPower   = Send-DenonQuery "PW?" "PW"
    $rawVolume  = Send-DenonQuery "MV?" "MV"
    $rawInput   = Send-DenonQuery "SI?" "SI"
    $rawMute    = Send-DenonQuery "MU?" "MU"
    $rawMode    = Send-DenonQuery "MS?" "MS"
    $rawChannelBlock = Send-DenonQuery "CV?" "CV"

    # Convert to friendly names
    $power  = Convert-DenonFriendly $rawPower  $DenonPowerMap
    $input  = Convert-DenonFriendly $rawInput  $DenonInputMap
    $mute   = Convert-DenonFriendly $rawMute   $DenonMuteMap
    $mode   = Convert-DenonFriendly $rawMode   $DenonModeMap

    # Volume conversion (MV40 -> 40.0 dB, MV405 -> 40.5 dB)
    $vol = ""
    if ($rawVolume -match "^MV(\d{2,3})$") {

        $num = $Matches[1]

        if ($num.Length -eq 2) {
            # Example: 40 -> 40.0 dB
            $volValue = [int]$num
            $vol = ("{0:0.0} dB" -f $volValue)
        }
        elseif ($num.Length -eq 3) {
            # Example: 405 -> 40.5 dB
            $whole = [int]($num.Substring(0, $num.Length - 1))
            $half  = [int]($num.Substring($num.Length - 1, 1)) * 0.1
            $volValue = $whole + $half
            $vol = ("{0:0.1} dB" -f $volValue)
        }
    }
    else {
        $vol = $rawVolume
    }


    # Channel levels (raw CV... strings)
    $channel = Convert-DenonChannels $rawChannelBlock

    return (
        "Power:   $power`r`n" +
        "Volume:  $vol`r`n" +
        "Input:   $input`r`n" +
        "Mute:    $mute`r`n" +
        "Mode:    $mode`r`n" +
        "`r`nChannel Levels:`r`n" +
        "$channel"
    )
}

function Update-Status {
    param(
        [string]$Message
    )

    # GUI output (only if GUI is loaded)
    if ($script:lblStatus -ne $null) {
        $script:lblStatus.Text = "Status: $Message"
    }
}

function Show-DenonGUI {

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Main form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Denon AVR Controller"
    $form.Size = New-Object System.Drawing.Size(550, 750)
    $form.StartPosition = "CenterScreen"
    try {
        $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } catch {}

    # IP / Hostname label
    $lblHost = New-Object System.Windows.Forms.Label
    $lblHost.Text = "AVR Address:"
    $lblHost.Location = New-Object System.Drawing.Point(20,22)
    $lblHost.Size = New-Object System.Drawing.Size(100,25)
    $form.Controls.Add($lblHost)

    # IP / Hostname textbox
    $txtHost = New-Object System.Windows.Forms.TextBox
    $txtHost.Location = New-Object System.Drawing.Point(120,20)
    $txtHost.Size = New-Object System.Drawing.Size(200,25)
    $txtHost.Text = "192.168.1.68"   # default value
    $form.Controls.Add($txtHost)

    # Connect button
    $btnConnect = New-Object System.Windows.Forms.Button
    $btnConnect.Text = "Connect"
    $btnConnect.Location = New-Object System.Drawing.Point(20,55)
    $btnConnect.Size = New-Object System.Drawing.Size(200,40)
    $form.Controls.Add($btnConnect)

    # Disconnect button
    $btnDisconnect = New-Object System.Windows.Forms.Button
    $btnDisconnect.Text = "Disconnect"
    $btnDisconnect.Location = New-Object System.Drawing.Point(240,55)
    $btnDisconnect.Size = New-Object System.Drawing.Size(200,40)
    $btnDisconnect.Enabled = $false
    $form.Controls.Add($btnDisconnect)

    # Power On
    $btnPowerOn = New-Object System.Windows.Forms.Button
    $btnPowerOn.Text = "Power On"
    $btnPowerOn.Location = New-Object System.Drawing.Point(20,110)
    $btnPowerOn.Size = New-Object System.Drawing.Size(200,40)
    $btnPowerOn.Enabled = $false
    $form.Controls.Add($btnPowerOn)

    # Power Off
    $btnPowerOff = New-Object System.Windows.Forms.Button
    $btnPowerOff.Text = "Standby"
    $btnPowerOff.Location = New-Object System.Drawing.Point(240,110)
    $btnPowerOff.Size = New-Object System.Drawing.Size(200,40)
    $btnPowerOff.Enabled = $false
    $form.Controls.Add($btnPowerOff)

    # Volume slider label
    $lblVolSlider = New-Object System.Windows.Forms.Label
    $lblVolSlider.Text = "Volume:"
    $lblVolSlider.Location = New-Object System.Drawing.Point(20,185)
    $lblVolSlider.Size = New-Object System.Drawing.Size(80,25)
    $form.Controls.Add($lblVolSlider)

    # Volume slider (0-100 UI range)
    $trackVolume = New-Object System.Windows.Forms.TrackBar
    $trackVolume.Location = New-Object System.Drawing.Point(100,180)
    $trackVolume.Size = New-Object System.Drawing.Size(340,45)
    $trackVolume.Minimum = 0
    $trackVolume.Maximum = 100
    $trackVolume.TickFrequency = 5
    $trackVolume.SmallChange = 1
    $trackVolume.LargeChange = 5
    $trackVolume.Value = 40
    $form.Controls.Add($trackVolume)

    # Red zone panel (Max->100, under slider)
    $redZone = New-Object System.Windows.Forms.Panel
    $redZone.BackColor = [System.Drawing.Color]::FromArgb(200, 255, 80, 80)
    $redZone.Height = 6
    $redZone.Top = $trackVolume.Top + 30
    $redZone.Left = $trackVolume.Left
    $redZone.Width = 0
    $form.Controls.Add($redZone)

    # IMPORTANT: ensure it is above the TrackBar
    $redZone.BringToFront()

    # Live volume readout (under slider)
    $lblVolValue = New-Object System.Windows.Forms.Label
    $lblVolValue.Text = "Volume: $($trackVolume.Value)"
    $lblVolValue.Size = New-Object System.Drawing.Size(118,25)
    $lblVolValue.Left = $trackVolume.Left
    $lblVolValue.Top  = $trackVolume.Top + 52
    $form.Controls.Add($lblVolValue)

    # Mute (narrow, between volume readout and max cap — does not overlap Input row below)
    $btnMute = New-Object System.Windows.Forms.Button
    $btnMute.Text = "Mute"
    $btnMute.Size = New-Object System.Drawing.Size(68,26)
    $btnMute.Left = $trackVolume.Left + 120
    $btnMute.Top  = $trackVolume.Top + 50
    $btnMute.Enabled = $false
    $form.Controls.Add($btnMute)

    # Max volume label / textbox (under slider, right-aligned)
    $lblMaxVol = New-Object System.Windows.Forms.Label
    $lblMaxVol.Text = "Max:"
    $lblMaxVol.Size = New-Object System.Drawing.Size(40,25)
    $lblMaxVol.Top  = $trackVolume.Top + 52
    $lblMaxVol.Left = $trackVolume.Left + $trackVolume.Width - 85
    $form.Controls.Add($lblMaxVol)

    $txtMaxVol = New-Object System.Windows.Forms.TextBox
    $txtMaxVol.Size = New-Object System.Drawing.Size(40,25)
    $txtMaxVol.Top  = $trackVolume.Top + 50
    $txtMaxVol.Left = $trackVolume.Left + $trackVolume.Width - 45
    $txtMaxVol.Text = "60"
    $form.Controls.Add($txtMaxVol)

    # Input label
    $lblInput = New-Object System.Windows.Forms.Label
    $lblInput.Text = "Input:"
    $lblInput.Location = New-Object System.Drawing.Point(20,265)
    $lblInput.Size = New-Object System.Drawing.Size(80,30)
    $form.Controls.Add($lblInput)

    # Input dropdown
    $cmbInput = New-Object System.Windows.Forms.ComboBox
    $cmbInput.Location = New-Object System.Drawing.Point(100,265)
    $cmbInput.Size = New-Object System.Drawing.Size(340,30)
    $cmbInput.DropDownStyle = "DropDownList"
    $cmbInput.Items.AddRange(@("TV","BD","SAT","GAME","MPLAY","AUX1","AUX2","HEOS / Streaming"))
    $form.Controls.Add($cmbInput)

    # Set Input button
    $btnSetInput = New-Object System.Windows.Forms.Button
    $btnSetInput.Text = "Set Input"
    $btnSetInput.Location = New-Object System.Drawing.Point(20,305)
    $btnSetInput.Size = New-Object System.Drawing.Size(320,40)
    $form.Controls.Add($btnSetInput)

    # Status label
    $lblStatusHeader = New-Object System.Windows.Forms.Label
    $lblStatusHeader.Text = "Receiver Status:"
    $lblStatusHeader.Location = New-Object System.Drawing.Point(20,350)
    $lblStatusHeader.Size = New-Object System.Drawing.Size(200,30)
    $form.Controls.Add($lblStatusHeader)

    # Status box
    $txtStatus = New-Object System.Windows.Forms.TextBox
    $txtStatus.Location = New-Object System.Drawing.Point(20,380)
    $txtStatus.Size = New-Object System.Drawing.Size(500,220)
    $txtStatus.Multiline = $true
    $txtStatus.ScrollBars = "Vertical"
    $txtStatus.ReadOnly = $true
    $txtStatus.BackColor = [System.Drawing.Color]::FromArgb(242, 242, 242)
    $form.Controls.Add($txtStatus)

    # Status line
    $script:lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Status: Not connected"
    $lblStatus.Location = New-Object System.Drawing.Point(20,610)
    $lblStatus.Size = New-Object System.Drawing.Size(400,30)
    $form.Controls.Add($lblStatus)

    # Refresh button
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh Status"
    $btnRefresh.Location = New-Object System.Drawing.Point(20,640)
    $btnRefresh.Size = New-Object System.Drawing.Size(500,40)
    $form.Controls.Add($btnRefresh)

    # Helper: update red zone based on Max
    $updateRedZone = {
        $limit = 0
        if (-not [int]::TryParse($txtMaxVol.Text, [ref]$limit)) {
            $limit = 0
        }

        if ($limit -lt $trackVolume.Minimum) { $limit = $trackVolume.Minimum }
        if ($limit -gt $trackVolume.Maximum) { $limit = $trackVolume.Maximum }

        $range = $trackVolume.Maximum - $trackVolume.Minimum
        if ($range -le 0) {
            $redZone.Width = 0
            return
        }

        $percent = ($limit - $trackVolume.Minimum) / $range
        $redZone.Width = [int]($trackVolume.Width * (1 - $percent))
        $redZone.Left  = $trackVolume.Left + [int]($trackVolume.Width * $percent)
    }

    & $updateRedZone

    # Apply full status text to UI (receiver text box, volume slider position, mute, grey out slider when muted)
    $applyReceiverStatusUi = {
        param([string]$statusText)
        $txtStatus.Text = $statusText
        if ($statusText -match "Volume:\s+([0-9]+\.[0-9])") {
            $volInt = [int][math]::Round([double]$Matches[1])
            $limit = 0
            if (-not [int]::TryParse($txtMaxVol.Text, [ref]$limit)) {
                $limit = 0
            }
            if ($limit -lt $trackVolume.Minimum) { $limit = $trackVolume.Minimum }
            if ($limit -gt $trackVolume.Maximum) { $limit = $trackVolume.Maximum }
            $trackVolume.Value = [Math]::Min($volInt, $limit)
            $lblVolValue.Text = "Volume: $($trackVolume.Value)"
        }
        if ($Global:DenonClient -and $Global:DenonClient.Connected -and ($statusText -notmatch '^Not connected\.')) {
            $btnMute.Enabled = $true
            $mutedLine = ([regex]::Match($statusText, '(?m)^Mute:\s*(.+)$')).Groups[1].Value.Trim()
            if ($mutedLine) {
                $muted = ($mutedLine -eq "Muted")
                $trackVolume.Enabled = -not $muted
                $btnMute.Text = if ($muted) { "Unmute" } else { "Mute" }
            }
            else {
                $trackVolume.Enabled = $true
                $btnMute.Text = "Mute"
            }
        }
        else {
            $btnMute.Enabled = $false
            $trackVolume.Enabled = $true
            $btnMute.Text = "Mute"
        }

        # Connect / Disconnect toolbar
        $isConnectedUi = (
            ($Global:DenonClient -and $Global:DenonClient.Connected) `
            -and ($statusText -notmatch '^Not connected\.')
        )
        $btnDisconnect.Enabled = $isConnectedUi
        $btnConnect.Enabled = (-not $isConnectedUi)

        # Power buttons: mutually exclusive enabled state when connected; both off when disconnected
        if (-not $isConnectedUi) {
            $btnPowerOn.Enabled = $false
            $btnPowerOff.Enabled = $false
        }
        else {
            $pwrLine = ([regex]::Match($statusText, '(?m)^Power:\s*(.+)$')).Groups[1].Value.Trim()
            $isStandbyLike = (($pwrLine -match '(?i)standby') -or ($pwrLine -match '(?i)off\b'))
            if ($pwrLine -eq "On") {
                $btnPowerOn.Enabled = $false
                $btnPowerOff.Enabled = $true
            }
            elseif ($isStandbyLike) {
                $btnPowerOn.Enabled = $true
                $btnPowerOff.Enabled = $false
            }
            elseif (-not [string]::IsNullOrWhiteSpace($pwrLine)) {
                # Fallback: conservative—allow power-on only unless line clearly indicates standby
                $btnPowerOn.Enabled = $true
                $btnPowerOff.Enabled = $false
            }
            else {
                # Could not parse power row; safest default is standby-style (wake allowed)
                $btnPowerOn.Enabled = $true
                $btnPowerOff.Enabled = $false
            }
        }

        & $updateRedZone
    }

    # Helper: apply volume to AVR (on commit)
    $applyVolume = {
        if (-not ($Global:DenonClient -and $Global:DenonClient.Connected)) { return }
        if (-not $trackVolume.Enabled) { return }

        $limit = 0
        if (-not [int]::TryParse($txtMaxVol.Text, [ref]$limit)) {
            $limit = 0
        }
        if ($limit -lt $trackVolume.Minimum) { $limit = $trackVolume.Minimum }
        if ($limit -gt $trackVolume.Maximum) { $limit = $trackVolume.Maximum }

        $val = $trackVolume.Value
        if ($val -gt $limit) { $val = $limit }

        # Denon max is 98
        $denonVal = [Math]::Min($val, 98)

        Send-DenonCommand ("MV" + $denonVal)

        & $applyReceiverStatusUi (Get-DenonFullStatus)
    }

    # Power (refresh UI after telnet settles)
    $btnPowerOn.Add_Click({
        if (-not ($Global:DenonClient -and $Global:DenonClient.Connected)) { return }
        try {
            Send-DenonCommand "PWON"
            Start-Sleep -Milliseconds 280
            & $applyReceiverStatusUi (Get-DenonFullStatus)
        }
        catch { }
    })
    $btnPowerOff.Add_Click({
        if (-not ($Global:DenonClient -and $Global:DenonClient.Connected)) { return }
        try {
            Send-DenonCommand "PWSTANDBY"
            Start-Sleep -Milliseconds 280
            & $applyReceiverStatusUi (Get-DenonFullStatus)
        }
        catch { }
    })

    # Mute / Unmute toggle
    $btnMute.Add_Click({
        if (-not ($Global:DenonClient -and $Global:DenonClient.Connected)) { return }
        try {
            $raw = Send-DenonQuery "MU?" "MU"
            $mutedNow = ($raw -match '^MUON')
            if ($mutedNow) {
                Send-DenonCommand "MUOFF"
            } else {
                Send-DenonCommand "MUON"
            }
            Start-Sleep -Milliseconds 120
            & $applyReceiverStatusUi (Get-DenonFullStatus)
        }
        catch { }
    })

    # Slider scroll: smooth feel, local only
    $trackVolume.Add_Scroll({
        if (-not $trackVolume.Enabled) { return }
        $limit = 0
        if (-not [int]::TryParse($txtMaxVol.Text, [ref]$limit)) {
            $limit = 0
        }
        if ($trackVolume.Value -gt $limit) {
            $trackVolume.Value = $limit
        }
        $lblVolValue.Text = "Volume: $($trackVolume.Value)"
    })

    # Mouse release: commit to AVR
    $trackVolume.Add_MouseUp({
        if (-not $trackVolume.Enabled) { return }
        $lblVolValue.Text = "Volume: $($trackVolume.Value)"
        & $applyVolume
    })

    # Keyboard navigation: commit on key up
    $trackVolume.Add_KeyUp({
        if (-not $trackVolume.Enabled) { return }
        if ($_.KeyCode -in @("Left","Right","Up","Down","PageUp","PageDown","Home","End")) {
            $lblVolValue.Text = "Volume: $($trackVolume.Value)"
            & $applyVolume
        }
    })

    # Max volume textbox logic
    $txtMaxVol.Add_TextChanged({
        $text = $txtMaxVol.Text.Trim()

        # Allow empty or single digit while typing
        if ($text -eq "" -or $text -match "^\d$") { return }

        $val = 0
        if ([int]::TryParse($text, [ref]$val)) {

            if ($val -lt 0)   { $val = 0 }
            if ($val -gt 100) { $val = 100 }

            if ($txtMaxVol.Text -ne "$val") {
                $txtMaxVol.Text = "$val"
            }

            if ($trackVolume.Value -gt $val) {
                $trackVolume.Value = $val
                $lblVolValue.Text = "Volume: $($trackVolume.Value)"
            }

            & $updateRedZone
        }
    })

    # Set Input button
    $btnSetInput.Add_Click({
        if ($cmbInput.SelectedItem) {
            switch ($cmbInput.SelectedItem) {
                "HEOS / Streaming" { Send-DenonCommand "SINET" }
                default { Send-DenonCommand ("SI" + $cmbInput.SelectedItem) }
            }
        }
    })

    # Connect button
    $btnConnect.Add_Click({
        try {
            $target = $txtHost.Text.Trim()
            if (-not $target) {
                $lblStatus.Text = "Status: No address entered"
                return
            }

            Connect-DenonAVR -Address $target
            Update-Status "Connected"

            & $applyReceiverStatusUi (Get-DenonFullStatus)
        } catch {
            Update-Status ("Failed to connect: " + $_.Exception.Message)
            & $applyReceiverStatusUi "Not connected."
        }
    })


    # Disconnect button
    $btnDisconnect.Add_Click({
        Disconnect-DenonAVR
        $lblStatus.Text = "Status: Disconnected"
        & $applyReceiverStatusUi "Not connected."
    })

    # Refresh button
    $btnRefresh.Add_Click({
        & $applyReceiverStatusUi (Get-DenonFullStatus)
    })

    # Auto-populate on startup if already connected
    $form.Add_Shown({
        if ($Global:DenonClient -and $Global:DenonClient.Connected) {
            & $applyReceiverStatusUi (Get-DenonFullStatus)
        }
    })

    [void]$form.ShowDialog()
}

# Script entrypoint for standalone use / ps2exe build.
Show-DenonGUI
