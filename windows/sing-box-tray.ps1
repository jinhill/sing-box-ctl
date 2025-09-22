# ps2exe .\sing-box-tray.ps1 .\sing-box-tray.exe -noConsole -icon "sing-box.ico" -requireAdmin

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$global:ProgressPreference = "SilentlyContinue"

# 定义全局变量
$workDirectory = ".\"
$appName = "Sing-Box Tray"
$jobName = "SingBoxJob"
$appPath = Join-Path $workDirectory "sing-box.exe"
$configPath = Join-Path $workDirectory "config.json"
$iconPathRunning = Join-Path $workDirectory "sing-box.ico"
$iconPathStopped = Join-Path $workDirectory "sing-box-stop.ico"

# 托盘气泡提示函数
function Show-NotifyTip {
    param(
        [string]$title,
        [string]$message,
        [System.Windows.Forms.ToolTipIcon]$icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    $notifyIcon.BalloonTipTitle = $title
    $notifyIcon.BalloonTipText  = $message
    $notifyIcon.BalloonTipIcon  = $icon
    $notifyIcon.ShowBalloonTip(3000)  # 显示 3 秒
}

# 获取版本信息
function Get-Version {
    param([string]$source)
    if ($source -eq "local") {
        if (Test-Path $appPath) {
            return (& $appPath version).Split("`n")[0].Split(" ")[2]
        }
        return "0.0.0"
    } elseif ($source -eq "latest") {
        $apiUrl = "https://api.github.com/repos/SagerNet/sing-box/tags"
        $response = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            return ($response.Content | ConvertFrom-Json)[0].name -replace "^v"
        }
        return $null
    }
}

# 比较版本号
function Compare-Version {
    param(
        [string]$localVersion,
        [string]$remoteVersion
    )
    return $localVersion -ne $remoteVersion
}

# 检查更新
function Check-For-Update {
    $localVersion = Get-Version -source "local"
    $latestVersion = Get-Version -source "latest"
    if ($null -eq $latestVersion) {
        return
    }

    if (Compare-Version $localVersion $latestVersion) {
        Show-NotifyTip $appName "新版本可用 ($latestVersion)，当前版本: $localVersion"
    }
}

# 更新操作
function Update {
    $localVersion = Get-Version -source "local"
    $latestVersion = Get-Version -source "latest"
    if ($null -eq $latestVersion) {
        Show-NotifyTip $appName "无法获取最新版本信息" ([System.Windows.Forms.ToolTipIcon]::Error)
        return
    }

    if (Compare-Version $localVersion $latestVersion) {
        Show-NotifyTip "更新提示" "正在升级到版本 $latestVersion..."
        try {
            $downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/v$latestVersion/sing-box-$latestVersion-windows-amd64.zip"
            $zipFile = Join-Path $workDirectory "sing-box.zip"
            Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -ErrorAction Stop

            JobAction -action "Stop"

            if (Test-Path $appPath) {
                $backupPath = Join-Path $workDirectory "sing-box_$localVersion.exe"
                Rename-Item -Path $appPath -NewName $backupPath -Force
            }

            $tempDir = Join-Path $workDirectory "temp"
            Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force -ErrorAction Stop
            Copy-Item -Path (Join-Path $tempDir "sing-box-$latestVersion-windows-amd64\sing-box.exe") -Destination $appPath -Force

            Remove-Item -Path $tempDir -Recurse -Force
            Remove-Item -Path $zipFile -Force
            JobAction -action "Start" -message "服务已成功更新"
        } catch {
            Show-NotifyTip $appName "更新失败：$_" ([System.Windows.Forms.ToolTipIcon]::Error)
        }
    } else {
        Show-NotifyTip $appName "当前版本: $localVersion, 已是最新"
    }
}

# 服务操作
function JobAction {
    param($action, $message)
    $process = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    switch ($action) {
        "Start" {
            if ($process) {
                Stop-Process -Id $process.Id -Force
                Start-Sleep -Seconds 1
            }
            Start-Process -FilePath $appPath -ArgumentList "run", "-c", $configPath, "-D", $workDirectory -WindowStyle Hidden
            if ($message) { Show-NotifyTip $appName $message }
        }
        "Stop" {
            if ($process) {
                Stop-Process -Id $process.Id -Force
                if ($message) { Show-NotifyTip $appName $message }
            }
        }
    }
    UpdateTrayAndMenu
}

# 更新托盘图标和菜单
function UpdateTrayAndMenu {
    $process = Get-Process -Name "sing-box" -ErrorAction SilentlyContinue
    $iconPath = if ($process) { $iconPathRunning } else { $iconPathStopped }
    $notifyIcon.Icon = [System.Drawing.Icon]::new($iconPath)

    $startItem = $contextMenu.Items | Where-Object { $_.Text -eq "启动服务" -or $_.Text -eq "重启服务" }
    $stopItem = $contextMenu.Items | Where-Object { $_.Text -eq "停止服务" }

    if ($process) {
        $startItem.Text = "重启服务"
        $stopItem.Enabled = $true
    } else {
        $startItem.Text = "启动服务"
        $stopItem.Enabled = $false
    }
}

# 获取当前脚本的进程名，防止多开
$currentProcessName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName
$processes = Get-Process -Name $currentProcessName -ErrorAction SilentlyContinue
if ($processes.Count -ge 2) {
    exit
}

# 创建托盘图标
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Visible = $true
$notifyIcon.Text = "$appName Control"

# 左键单击打开控制面板
$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "http://127.0.0.1:9095"
    }
})

# 创建右键菜单
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
@(
    @{Text="控制面板"; Action={Start-Process "http://127.0.0.1:9095"}},
    @{Text="启动服务"; Action={JobAction -action "Start" -message "服务已启动"}},
    @{Text="停止服务"; Action={JobAction -action "Stop" -message "服务已停止"}},
    @{Text="配置文件"; Action={
        if (Test-Path $configPath) {
            Start-Process $configPath
        } else {
            Show-NotifyTip "错误" "配置文件不存在。" ([System.Windows.Forms.ToolTipIcon]::Error)
        }
    }},
    @{Text="检查更新"; Action={Update}},
    @{Text="退出"; Action={
        JobAction -action "Stop"
        $notifyIcon.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    }}
) | ForEach-Object {
    $menuItem = New-Object System.Windows.Forms.ToolStripMenuItem
    $menuItem.Text = $_.Text
    $menuItem.Add_Click($_.Action)
    $contextMenu.Items.Add($menuItem) | Out-Null
}

$notifyIcon.ContextMenuStrip = $contextMenu
JobAction -action "Start"
Check-For-Update
[System.Windows.Forms.Application]::Run()
