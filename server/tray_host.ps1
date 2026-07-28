# Runs essentials_app's crdt_sync server as a hidden child process and
# shows a system tray icon for it instead of a taskbar window -- see
# CLAUDE.md "Syncing at the Record Level" for the full auto-start writeup.
# Launched invisibly via launch_tray_hidden.vbs from the Startup folder;
# not meant to be run directly with a visible PowerShell window (though
# that works fine too, e.g. while testing).
#
# Deliberately two separate processes (this tray host + server.exe as its
# own child), not one process trying to be both a console server and a
# WinForms tray app: if this tray host ever crashes, the actual sync
# server keeps running unaffected, since it's a genuine child process, not
# something that depends on this script staying alive for its own function.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$serverExe = "C:\Flutter\essentials_app\server\build\cli\windows_x64\bundle\bin\server.exe"
$serverDir = "C:\Flutter\essentials_app\server\build\cli\windows_x64\bundle\bin"
$logPath = "C:\Flutter\essentials_app\server\server.log"
$errLogPath = "C:\Flutter\essentials_app\server\server.err.log"

function Start-ServerProcess {
    foreach ($p in @($logPath, $errLogPath)) {
        if (Test-Path $p) { Remove-Item $p -ErrorAction SilentlyContinue }
    }
    Start-Process -FilePath $serverExe -WorkingDirectory $serverDir -WindowStyle Hidden `
        -RedirectStandardOutput $logPath -RedirectStandardError $errLogPath -PassThru
}

$script:serverProcess = Start-ServerProcess

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = "essentials_app sync server (10.0.0.134:1340)"
$notifyIcon.Visible = $true

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$viewLogItem = $contextMenu.Items.Add("View log")
$restartItem = $contextMenu.Items.Add("Restart server")
$contextMenu.Items.Add("-") | Out-Null
$exitItem = $contextMenu.Items.Add("Exit (stops the server too)")
$notifyIcon.ContextMenuStrip = $contextMenu

$viewLog = {
    if (Test-Path $logPath) {
        $tailCommand = "Get-Content -Path '$logPath' -Wait -Tail 30"
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NoExit', '-Command', $tailCommand)
    }
}
$viewLogItem.add_Click($viewLog)
$notifyIcon.add_DoubleClick($viewLog)

$restartItem.add_Click({
    if ($script:serverProcess -and -not $script:serverProcess.HasExited) {
        Stop-Process -Id $script:serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $script:serverProcess = Start-ServerProcess
    $notifyIcon.ShowBalloonTip(2000, "essentials_app sync server", "Restarted.", [System.Windows.Forms.ToolTipIcon]::Info)
})

$exitItem.add_Click({
    if ($script:serverProcess -and -not $script:serverProcess.HasExited) {
        Stop-Process -Id $script:serverProcess.Id -Force -ErrorAction SilentlyContinue
    }
    $notifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

Start-Sleep -Milliseconds 1500
$notifyIcon.ShowBalloonTip(2500, "essentials_app sync server", "Running -- listening on 10.0.0.134:1340.", [System.Windows.Forms.ToolTipIcon]::Info)

[System.Windows.Forms.Application]::Run()
