# 一键 SSH（Windows 远程控制一键配置）

在 Windows 上配置 SSH 远程登录，一行命令搞定。

## 为什么 Windows SSH 连不上？

Windows 自带的 OpenSSH Server 有一个隐藏的坑：

`C:\ProgramData\ssh\sshd_config` 文件末尾有这么一段：

```
Match Group administrators
       AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys
```

这段配置的意思是：**如果登录用户属于 administrators 组，就不读用户目录的 `~/.ssh/authorized_keys`，而是强制去读 `C:\ProgramData\ssh\administrators_authorized_keys`。**

问题在于——大多数 Windows 用户都是管理员。所以你辛辛苦苦把公钥放到 `~/.ssh/authorized_keys` 里，sshd 根本不看那个文件。

这是 Windows SSH 密钥认证失败的头号原因。网上大部分教程都没提到这一点。

## 使用方法

让对方在 Windows 电脑上：

1. 右键点击「开始」菜单 → 选择「终端(管理员)」或「PowerShell(管理员)」
2. 粘贴这一行命令，回车：

```powershell
irm https://raw.githubusercontent.com/Tiny-cyber/ssh-fix/main/fix-ssh.ps1 | iex
```

3. 等脚本跑完，把最后显示的连接信息截图发回来

## 脚本做了什么

一共 6 步，全自动：

1. **安装 OpenSSH Server** — 如果没装就自动装
2. **修复 sshd_config** — 启用公钥认证，注释掉 `Match Group administrators` 覆盖块（这是关键）
3. **下载并写入公钥** — 从本仓库的 `keys.txt` 下载公钥，写入 `~/.ssh/authorized_keys` 和 `C:\ProgramData\ssh\administrators_authorized_keys` 两个位置（双保险）
4. **修复文件权限** — Windows SSH 对权限要求严格，权限不对会拒绝读取
5. **开放防火墙** — 放行 TCP 22 端口入站
6. **重启 sshd** — 让所有配置生效，并设置开机自启

## 以后怎么加人

要授权新电脑连接，只需要：

1. 把新电脑的公钥加到本仓库的 `keys.txt`（一行一个）
2. 让对方重新跑一次那行命令

脚本会从 GitHub 下载最新的 `keys.txt`，自动更新。

## 文件说明

```
keys.txt      # 授权的公钥列表（一行一个）
fix-ssh.ps1   # 一键配置脚本
README.md     # 本文档
```
