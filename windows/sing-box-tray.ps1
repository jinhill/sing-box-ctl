# ps2exe .\sing-box-tray.ps1 .\sing-box-tray.exe -noConsole -icon "sing-box.ico" -requireAdmin

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$global:ProgressPreference = "SilentlyContinue"

# 定义全局变量
#$workDirectory = [System.IO.Path]::GetDirectoryName([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$workDirectory = ".\"
$appName = "Sing-Box Tray"
$jobName = "SingBoxJob"
$appPath = Join-Path $workDirectory "sing-box-latest.exe"
$configPath = Join-Path $workDirectory "config.json"
$iconPathRunning = Join-Path $workDirectory "sing-box.ico"
$iconPathStopped = Join-Path $workDirectory "sing-box-stop.ico"

# 获取版本信息
function Get-Version {
    param([string]$source)
    if ($source -eq "local") {
        return (& $appPath version).Split("`n")[0].Split(" ")[2]
    } elseif ($source -eq "latest") {
        $apiUrl = "https://api.github.com/repos/SagerNet/sing-box/tags"
        $response = Invoke-WebRequest -Uri $apiUrl -UseBasicParsing -ErrorAction SilentlyContinue
        if ($response.StatusCode -eq 200) {
            return ($response.Content | ConvertFrom-Json)[0].name -replace "^v"
        }
        return $null
    }
}

# 比较版本号，返回布尔值表示是否需要更新
function Compare-Version {
    param(
        [string]$localVersion,
        [string]$remoteVersion
    )

    # 去掉所有字母和横杠
    $localVersion = $localVersion -replace '[a-zA-Z-]', ''
    $remoteVersion = $remoteVersion -replace '[a-zA-Z-]', ''

    # 转换为System.Version对象进行比较
    $localVerObj = [System.Version]::Parse($localVersion)
    $remoteVerObj = [System.Version]::Parse($remoteVersion)

    # 比较版本号
    if ($localVerObj -lt $remoteVerObj) {
        return $true  # 本地版本较低
    } else {
        return $false # 本地版本较高或相同
    }
}

# 更新操作
function Update {
    $localVersion = Get-Version -source "local"
    $latestVersion = Get-Version -source "latest"
    if ($null -eq $latestVersion) {
        [System.Windows.Forms.MessageBox]::Show("无法获取最新版本信息", $appName)
        return
    }

    if (Compare-Version $localVersion $latestVersion) {
        if ([System.Windows.Forms.MessageBox]::Show("新版本可用 ($latestVersion)，是否要升级？", "更新提示", [System.Windows.Forms.MessageBoxButtons]::YesNo) -eq "Yes") {
            try {
                $downloadUrl = "https://github.com/SagerNet/sing-box/releases/download/v$latestVersion/sing-box-$latestVersion-windows-amd64.zip"
                $zipFile = Join-Path $workDirectory "sing-box.zip"
                Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -ErrorAction Stop
				
                JobAction -action "Stop"
                
                $tempDir = Join-Path $workDirectory "temp"
                Expand-Archive -Path $zipFile -DestinationPath $tempDir -Force -ErrorAction Stop
                
                Copy-Item -Path (Join-Path $tempDir "sing-box-$latestVersion-windows-amd64\sing-box.exe") -Destination $appPath -Force
                
                Remove-Item -Path $tempDir -Recurse -Force
                Remove-Item -Path $zipFile -Force
                JobAction -action "Start" -message "服务已成功更新"
            } catch {
                [System.Windows.Forms.MessageBox]::Show("更新失败：$_", $appName)
            }
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("当前版本: $localVersion, 已是最新", $appName)
    }
}

# 服务操作
function JobAction {
    param($action, $message)
    $process = Get-Process -Name "sing-box-latest" -ErrorAction SilentlyContinue
    switch ($action) {
        "Start" {
            if ($process) {
                Stop-Process -Id $process.Id -Force
                Start-Sleep -Seconds 1 # Wait for 1 seconds
            }
            Start-Process -FilePath $appPath -ArgumentList "run", "-c", $configPath, "-D", $workDirectory -WindowStyle Hidden
            if ($message) { [System.Windows.Forms.MessageBox]::Show($message, $appName) }
        }
        "Stop" {
            if ($process) {
                Stop-Process -Id $process.Id -Force
                if ($message) { [System.Windows.Forms.MessageBox]::Show($message, $appName) }
            }
        }
    }
    UpdateTrayAndMenu
}

# 定义一个函数来更新托盘图标和菜单项状态
function UpdateTrayAndMenu {
    $process = Get-Process -Name "sing-box-latest" -ErrorAction SilentlyContinue
    $iconPath = if ($process) { $iconPathRunning } else { $iconPathStopped }
    $notifyIcon.Icon = [System.Drawing.Icon]::new($iconPath)
    
    $startItem = $contextMenu.Items | Where-Object {  $_.Text -eq "启动服务" -or $_.Text -eq "重启服务" }
    $stopItem = $contextMenu.Items | Where-Object { $_.Text -eq "停止服务" }
    
    if ($process) {
        # 如果服务正在运行
		$startItem.Text = "重启服务"
        $stopItem.Enabled = $true
    } else {
        # 如果服务停止
		$startItem.Text = "启动服务"
        $stopItem.Enabled = $false
    }
}

# 获取当前脚本的进程名
$currentProcessName = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName

# 检查是否有两个或以上的进程在运行
$processes = Get-Process -Name $currentProcessName -ErrorAction SilentlyContinue
if ($processes.Count -ge 2) {
    exit
}

# 创建托盘图标
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
# 初始化托盘图标
$notifyIcon.Visible = $true
$notifyIcon.Text = "$appName Control"

# 添加鼠标点击事件处理
$notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Process "http://127.0.0.1:9095"
    }
})

# 创建上下文菜单
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
@(
    @{Text="控制面板"; Action={Start-Process "http://127.0.0.1:9095"}},
    @{Text="启动服务"; Action={JobAction -action "Start" -message "服务已启动"}},
    @{Text="停止服务"; Action={JobAction -action "Stop" -message "服务已停止"}},
	@{Text="配置文件"; Action={
        if (Test-Path $configPath) {
            Start-Process $configPath
        } else {
            [System.Windows.Forms.MessageBox]::Show("配置文件不存在。", "错误", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
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
# 保持脚本运行以保持托盘图标可见
[System.Windows.Forms.Application]::Run()
