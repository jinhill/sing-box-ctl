## openwrt安装配置
```
# 安装依赖
opkg update
opkg install curl jq coreutils-base64

# copy脚本到相应的目录
mv singbox.init /etc/init.d/singbox
chmod +x /etc/init.d/singbox
/etc/init.d/singbox enable
mv singbox-ctl.sh /usr/bin/
chmod +x /usr/bin/singbox-ctl.sh

# 下载最新版本sing-box,默认从github下载
# 如果没有代理环境需要手动下载sing-box到/usr/bin/sing-box
/etc/init.d/singbox update

# 根据订阅链接生成sing-box配置文件，首次运行根据提示输入自己的订阅链接
singbox-ctl.sh sub

# 启动sing-box服务
/etc/init.d/singbox start

```
## windows托盘程序编译 
手动从github下载sing-box.exe, 重命名为sing-box-latest.exe, 保存在与脚本相同目录.  
默认加载当前目录下的配置文件config.json  
in powershell  
```
Install-Module -Name ps2exe -RequiredVersion 1.0.13
ps2exe .\sing-box-tray.ps1 .\sing-box-tray.exe -noConsole -icon "sing-box.ico" -requireAdmin
```