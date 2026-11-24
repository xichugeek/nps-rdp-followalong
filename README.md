# 腾讯云 NPS 与 Windows 远程桌面跟做指南

用自己管理的腾讯云测试实例和两台获得授权的 Windows 电脑练习。例子里的公网地址取自文档专用网段，跟做时换成自己的地址。Linux 使用 Ubuntu 24.04 x86_64，NPS 与 NPC 固定使用实测版本 v1.1.52。先保持现有 SSH 会话，检查 8025 和 43389 均无公网宽泛放行，管理入口只允许管理员来源。如需对照既有服务，记录基线。

| 端口 | 谁发起连接 | 目标与来源控制 |
|---|---|---|
| SSH（按实例实际端口） | 管理电脑 | 云主机，仅管理员来源。面板通过 SSH 转发访问 |
| TCP 8025 | 被控电脑的 NPC | 云主机公有 TLS Bridge，仅被控端公网出口 IPv4/32 |
| TCP 43389 | 主控电脑的 mstsc | 云主机 RDP 隧道，仅主控端公网出口 IPv4/32，同时配置腾讯云和 NPS 两处白名单 |
| 18024 / 18025 / 18081 | 云主机本地 | 普通 Bridge / TLS Bridge / 管理面板，均监听回环 |
| 3389 | 被控 Windows 本机的 NPC | 连接该 Windows 自己的 127.0.0.1:3389 |

## 1. 确认被控 Windows 可用

在被控端打开「设置 → 系统 → 远程桌面」，启用远程桌面，保留网络级别身份验证，确认账号获准远程登录。Windows Home 可作主控端。被控端须使用支持作为 RDP 主机的版本，如 Windows Pro。保持被控机联网且不休眠，记录两台 Windows 在准备使用的各自网络上的公网出口。 [微软远程桌面设置](https://learn.microsoft.com/windows-server/remote/remote-desktop-services/remotepc/remote-desktop-allow-access)

```powershell
Test-NetConnection -ComputerName 127.0.0.1 -Port 3389
```

输出 `TcpTestSucceeded : True` 后继续。

## 2. 安装 NPS 并打开管理面板

用终端或腾讯云控制台登录一台新的 Linux 实例。检查操作系统、架构和端口。若 Linux 没有 curl 等依赖，先安装。

```bash
cat /etc/os-release
uname -m
sudo ss -lntp
sudo apt-get update
sudo apt-get install -y curl openssl ca-certificates
```

从管理机上把同目录的 `setup-nps.sh` 传到测试实例。将示例的 `ubuntu` 和公网地址换成自己的 SSH 账号和实例地址。自定义 SSH 端口时，scp 用 `-P`，ssh 用 `-p`。首次 SSH 登录前从自己信任的云端控制台核对该实例的 SSH 主机指纹。

```powershell
scp .\setup-nps.sh ubuntu@192.0.2.10:~/
ssh ubuntu@192.0.2.10
```

在云主机上输入以下命令，按脚本提示输入自己的公网 IPv4。脚本校验下载包、创建专用服务和证书，检查端口冲突，并等待本机面板响应。

```bash
sudo bash ~/setup-nps.sh
systemctl is-active xichuremote-nps.service xichuremote-nps-tls.socket
sudo ss -lntp '( sport = :8025 or sport = :18024 or sport = :18025 or sport = :18081 )'
sudo /opt/xichuremote-nps/bin/nps -version
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/login/index
```

上面的探测直接请求面板登录页。访问根路径时，未登录状态下可能先看到 HTTP 302 跳转，这属于正常流程。

预期为两个 `active`、三个回环监听、一个 8025 监听、版本 1.1.52 和面板 HTTP 200。密码只在你自己的屏幕停录时查看，管理员为 `npsadmin`。

```bash
sudo sed -n 's/^web_password=//p' /var/lib/xichuremote-nps/conf/nps.conf
```

在管理机新开 PowerShell 运行下面的 SSH 隧道，保持窗口打开，然后浏览器访问 `http://127.0.0.1:18081/`。如果管理机本地 18081 已占用，可换左侧端口，同时修改浏览器地址。

```powershell
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:18081:127.0.0.1:18081 ubuntu@192.0.2.10
```

在面板的「客户端」中新增一条，备注填「被控 Windows」，使用该客户端单独生成的 VerifyKey。记录客户端列表中的 ID。仅通过私有渠道交付这条密钥及后面的公开证书。

## 3. 开通 Bridge 并启动 Windows NPC

腾讯云 CVM 使用「安全组 → 入站规则 → 添加规则」，轻量应用服务器在实例详情的「防火墙」中添加。允许 TCP 8025，来源为被控端当前公网出口的 IPv4/32。有 Linux 主机防火墙时加相同范围的入站规则。检查所有绑定规则，确认没有更宽的 IPv4/IPv6 规则重新放行本教程入口。 [腾讯云 CVM 安全组](https://cloud.tencent.com/document/product/213/112614) · [腾讯云轻量实例防火墙](https://cloud.tencent.com/document/product/1207/44577)

在云主机把公开证书复制到 SSH 用户私有目录，传回管理机，再通过现有私有渠道给被控端。

```bash
sudo install -o "$(id -u)" -g "$(id -g)" -m 0600 /var/lib/xichuremote-nps/conf/bridge.pem "$HOME/nps-bridge-ca.pem"
openssl x509 -in "$HOME/nps-bridge-ca.pem" -noout -fingerprint -sha256
```

```powershell
scp ubuntu@192.0.2.10:~/nps-bridge-ca.pem .
```

从 [ZiDuNet v1.1.52](https://github.com/ZiDuNet/nps/releases/tag/v1.1.52) 下载 `windows_amd64_client.tar.gz`。核对 SHA-256 为 `e1bb4abc33c365943f489862787d712375264833b856829647f470ab9c6acf21`。解压得到 `npc.exe`，放入单独目录，旁边放 `nps-bridge-ca.pem`。Linux 包 SHA-256 为 `93f3d1410fb38f8a32e228ddbb79775ca7b02cd37dcfad60b59cefb5f4693171`。

在下载目录打开 PowerShell，校验后解压。把已从云主机私下取得的公开证书放进新目录，文件指纹可与云主机输出比较。

```powershell
Get-FileHash .\windows_amd64_client.tar.gz -Algorithm SHA256
New-Item -ItemType Directory -Path .\npc-lab
tar.exe -xzf .\windows_amd64_client.tar.gz -C .\npc-lab
Copy-Item .\nps-bridge-ca.pem .\npc-lab\
Set-Location .\npc-lab
```

先测 TCP 和版本，再以隐藏字符提示输入本次进程需要的 VerifyKey。键入密钥时暂停录制。

```powershell
Test-NetConnection -ComputerName 192.0.2.10 -Port 8025
.\npc.exe -version
$env:NPC_SERVER_VKEY = [System.Net.NetworkCredential]::new('', (Read-Host '输入该客户端的 VerifyKey' -AsSecureString)).Password
try {
    .\npc.exe -server=192.0.2.10:8025 -tls_enable=true -tls_ca_file=nps-bridge-ca.pem -disable_remote_update=true
} finally {
    Remove-Item Env:NPC_SERVER_VKEY -ErrorAction SilentlyContinue
}
```

保留该窗口，管理面板中这条客户端出现在线状态后继续。 [NPS 客户端配置与证书校验](https://zidunet.github.io/nps/client_config.html)

## 4. 映射 RDP 并限制访问来源

先在腾讯云及已启用的主机防火墙准备 TCP 43389，只允许主控端出口 IPv4/32。在 NPS 面板进入对应客户端的隧道列表，新增 TCP。服务端端口填 `43389`，服务端监听设为 IPv4 的 `0.0.0.0`，目标填 `127.0.0.1:3389`，隧道 IP 白名单填主控端公网出口 IPv4/32。保存后重新打开规则核对。 [NPS TCP 隧道](https://zidunet.github.io/nps/start.html#_5-添加-tcp-隧道) · [NPS 访问控制](https://zidunet.github.io/nps/extend/access-control.html)

若面板的来源字段难定位，可直接在云主机用已核验的 `npsctl` 创建同一条映射。示例假设面板中看到的客户端 ID 是 1，主控来源是示例地址 `198.51.100.20/32`。替换两者；面板已创建规则时用面板编辑，避免重复占用端口。

```bash
sudo bash <<'NPSCTL'
set -eu
export NPS_KEY="$(sed -n 's/^auth_key=//p' /var/lib/xichuremote-nps/conf/nps.conf)"
/opt/xichuremote-nps/bin/npsctl --server http://127.0.0.1:18081 --timeout 5s \
  tunnel create --data '{"type":"tcp","remark":"RDP lab","port":43389,"client_id":1,"server_ip":"0.0.0.0","target":"127.0.0.1:3389","whiteiplist":"198.51.100.20/32"}'
NPSCTL
sudo ss -lntp '( sport = :43389 )'
```

## 5. 用不同网络验收

在主控电脑上执行，随后用自己的被控机账号登录。核对远程主机的身份或证书，在远端的空白记事本输入 `NPS RDP OK`。

```powershell
Test-NetConnection -ComputerName 192.0.2.10 -Port 43389
mstsc.exe /v:192.0.2.10:43389
```

用另一条自己控制、未被云防火墙放行的网络检查 43389 无法接通，回到已放行来源复核可以登录。若需验证 NPS 白名单本身，在与公网隔离的网络中做允许和拒绝对照，核对远程桌面实际结果与 NPS 拒绝日志。NPS 可先接受 TCP 再拒绝转发，端口探测结果不能单独证明 NPS 白名单已生效。客户端离线时，先验证内侧监听，再从被控端核对 8025 的 TCP。TCP 超时先查实际出站地址、安全组或防火墙及套接字状态。TCP 能通而 TLS 或 NPC 失败，再检查证书地址、有效期、证书文件和 VerifyKey。客户端在线但 43389 超时，查主控出口地址及两处白名单。端口通但登录失败，查被控端本机 3389、账号权限与主机认证信号。

## 6. 可选的开机自启和停用

前台方式先跑通。需开机自启时，退出前台副本，将 `npc.exe` 和证书放在稳定目录，如 `C:\NPS\`，先在本机服务列表确认没有现有的 Npc 服务，再用管理员权限为实验创建 Npc 服务。已有该名称时，请换独立试验机或参照官方说明为独立实例保留专门服务名。在真实被控电脑重启后、控制台登录前，通过面板核对在线，再次做 RDP 登录。注册服务时参数会写入服务启动配置，服务宿主应为本人管理，密钥不要截图或共享。 [官方 NPC 系统服务命令](https://zidunet.github.io/nps/client_config.html)

```powershell
Set-Location C:\NPS
$npcKey = [System.Net.NetworkCredential]::new('', (Read-Host '输入 VerifyKey' -AsSecureString)).Password
try {
    .\npc.exe install -server=192.0.2.10:8025 "-vkey=$npcKey" -tls_enable=true -tls_ca_file=C:\NPS\nps-bridge-ca.pem -disable_remote_update=true
    .\npc.exe start
    Get-Service -Name Npc
} finally {
    Remove-Variable npcKey -ErrorAction SilentlyContinue
}
```

临时停用时先在面板禁用这条隧道，再撤掉云端和主机的 43389 入站规则。要连 Bridge 一起关闭时，停止并取消这次新增的 NPS 服务与套接字，撤掉对应 8025 入站规则。Windows 若安装了 NPC 服务，按同版官方命令停止和卸载。复核原来已有的网站和服务。

```bash
sudo systemctl disable --now xichuremote-nps-tls.socket xichuremote-nps.service
sudo systemctl stop xichuremote-nps-tls.service
```
