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
# 修改/usr/bin/singbox-ctl.sh中SUBSCRIBE_URL
# 根据订阅链接生成sing-box配置文件
singbox-ctl.sh sub
# 启动sing-box服务
/etc/init.d/singbox start

```
## windows托盘程序编译 
download sing-box.exe from github repo, rename sing-box.exe to sing-box-latest.exe, and place it in the same path as this script.  
in powershell  
```
Install-Module -Name ps2exe -RequiredVersion 1.0.13
ps2exe .\sing-box-tray.ps1 .\sing-box-tray.exe -noConsole -icon "sing-box.ico" -requireAdmin
```