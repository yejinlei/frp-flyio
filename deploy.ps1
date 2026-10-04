#Requires -Version 5.1
<#
.SYNOPSIS
    一键把 frps 发布到 fly.io。

.DESCRIPTION
    依次完成：检查 flyctl → 检查登录 → 应用不存在则创建 → 交互式补齐三个密钥
    （FRP_AUTH_TOKEN / FRP_DASHBOARD_USER / FRP_DASHBOARD_PWD）→ 检查 UDP 所需的独立 IPv4
    → fly deploy → 查看状态。所有步骤都在本脚本所在目录（fly.toml 所在目录）执行。

    密钥用 `fly secrets set --stage` 写入：只暂存、不立刻重启机器，避免卡在
    "Waiting for xxx to become healthy"（旧机器健康检查不过时会永远等下去），
    真正的生效发生在随后的 fly deploy。

.EXAMPLE
    ./deploy.ps1
        常规发布；缺失的密钥会逐个提示输入（Token 直接回车 = 自动生成随机值）。

    ./deploy.ps1 -RemoteOnly -Logs
        用 fly.io 远程构建（本机没装 Docker 时用），发布完顺便看日志。

    ./deploy.ps1 -NoWait
        不等机器 healthy 就返回（健康检查一直不过时用这个先发布上去）。

    ./deploy.ps1 -Token 'abc123' -DashboardUser 'admin' -DashboardPwd 'StrongPwd123!'
        全程非交互，直接指定三个值。
#>
[CmdletBinding()]
param(
    # 应用名，默认从 fly.toml 的 app = 'xxx' 读取
    [string] $AppName,

    # 用 fly.io 远程构建，本机不需要 Docker
    [switch] $RemoteOnly,

    # FRP_AUTH_TOKEN；不传会提示输入，直接回车则自动生成随机值
    [string] $Token,

    # 强制自动生成随机 Token，不提示
    [switch] $GenerateToken,

    # 仪表盘用户名；不传会提示输入（默认 admin）
    [string] $DashboardUser,

    # 仪表盘密码；不传会提示输入（隐藏输入）
    [string] $DashboardPwd,

    # 跳过「独立 IPv4」检查
    [switch] $SkipIpCheck,

    # fly deploy 不等机器 healthy 就返回
    [switch] $NoWait,

    # 部署完成后跟随日志
    [switch] $Logs
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    $m" -ForegroundColor Yellow }
function Write-Err  { param($m) Write-Host "    $m" -ForegroundColor Red }
function Write-Tip  { param($m) Write-Host "    $m" -ForegroundColor DarkGray }

# ---------------------------------------------------------------- 1. flyctl
Write-Step '检查 flyctl'
if (-not (Get-Command fly -ErrorAction SilentlyContinue)) {
    Write-Err '没找到 flyctl，先安装：'
    Write-Tip  'iwr https://fly.io/install.ps1 -useb | iex'
    exit 1
}
Write-Ok ('flyctl ' + ((fly version | Select-Object -First 1) -join ''))

# ---------------------------------------------------------------- 2. 应用名
if (-not $AppName) {
    $flyTomlPath = Join-Path $root 'fly.toml'
    if (-not (Test-Path $flyTomlPath)) { Write-Err "找不到 $flyTomlPath"; exit 1 }
    $m = [regex]::Match((Get-Content $flyTomlPath -Raw), "(?m)^\s*app\s*=\s*['""](.+?)['""]")
    if (-not $m.Success) { Write-Err 'fly.toml 里没解析到 app 名，请用 -AppName 指定'; exit 1 }
    $AppName = $m.Groups[1].Value
}
Write-Ok ("应用名: $AppName")

# ---------------------------------------------------------------- 3. 登录
Write-Step '检查 fly.io 登录状态'
try { $who = (fly auth whoami 2>$null | Out-String).Trim() } catch { $who = '' }
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($who)) {
    Write-Err '未登录或登录已失效，请先执行：fly auth login'
    exit 1
}
Write-Ok ("已登录: $who")

Push-Location $root
try {
    # ------------------------------------------------------------ 4. 应用是否存在
    Write-Step '检查应用是否已创建'
    try { fly status -a $AppName 2>$null | Out-Null; $appExists = ($LASTEXITCODE -eq 0) } catch { $appExists = $false }
    if (-not $appExists) {
        Write-Warn "应用 $AppName 还不存在，正在创建..."
        fly apps create $AppName
        if ($LASTEXITCODE -ne 0) { Write-Err '创建应用失败'; exit 1 }
        Write-Ok '已创建'
    } else {
        Write-Ok '已存在'
    }

    # ------------------------------------------------------------ 5. 密钥
    Write-Step '检查密钥（缺失的会逐个提示输入）'
    $secrets = (fly secrets list -a $AppName 2>$null | Out-String)
    $hasToken = $secrets -match 'FRP_AUTH_TOKEN'
    $hasUser  = $secrets -match 'FRP_DASHBOARD_USER'
    $hasPwd   = $secrets -match 'FRP_DASHBOARD_PWD'
    Write-Ok ("FRP_AUTH_TOKEN    : " + $(if ($hasToken) { '已设置' } else { '缺失' }))
    Write-Ok ("FRP_DASHBOARD_USER: " + $(if ($hasUser)  { '已设置' } else { '缺失' }))
    Write-Ok ("FRP_DASHBOARD_PWD : " + $(if ($hasPwd)   { '已设置' } else { '缺失' }))

    function New-RandomToken {
        $bytes = New-Object byte[] 16
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
    }

    $pairs = New-Object System.Collections.Generic.List[string]

    # --- FRP_AUTH_TOKEN ---
    if (-not $hasToken -or $GenerateToken -or $Token) {
        $val = $Token
        if ([string]::IsNullOrWhiteSpace($val)) {
            if ($GenerateToken) {
                $val = New-RandomToken
                Write-Host '    已自动生成随机 Token' -ForegroundColor Yellow
            } else {
                $val = (Read-Host '    请输入 FRP_AUTH_TOKEN（frpc 连接凭证，直接回车 = 自动生成随机值）').Trim()
                if ([string]::IsNullOrWhiteSpace($val)) { $val = New-RandomToken; Write-Host '    已自动生成随机 Token' -ForegroundColor Yellow }
            }
        }
        $pairs.Add("FRP_AUTH_TOKEN=$val")
        $script:AuthToken = $val
    }

    # --- FRP_DASHBOARD_USER ---
    if (-not $hasUser -or $DashboardUser) {
        $val = $DashboardUser
        if ([string]::IsNullOrWhiteSpace($val)) {
            $val = (Read-Host '    请输入 FRP_DASHBOARD_USER（仪表盘用户名，直接回车 = admin）').Trim()
            if ([string]::IsNullOrWhiteSpace($val)) { $val = 'admin' }
        }
        $pairs.Add("FRP_DASHBOARD_USER=$val")
    }

    # --- FRP_DASHBOARD_PWD ---
    if (-not $hasPwd -or $DashboardPwd) {
        $val = $DashboardPwd
        if ([string]::IsNullOrWhiteSpace($val)) {
            $sec = Read-Host '    请输入 FRP_DASHBOARD_PWD（仪表盘密码，输入不可见）' -AsSecureString
            $val = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                   [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
        }
        if ([string]::IsNullOrWhiteSpace($val)) { Write-Err '仪表盘密码不能为空'; exit 1 }
        $pairs.Add("FRP_DASHBOARD_PWD=$val")
    }

    if ($pairs.Count -gt 0) {
        Write-Host '    正在写入密钥（--stage：只暂存，下次部署生效，不会卡在健康检查）...' -ForegroundColor Yellow
        fly secrets set $pairs --stage -a $AppName
        if ($LASTEXITCODE -ne 0) {
            Write-Warn '--stage 不可用（flyctl 版本较旧），改为直接写入...'
            fly secrets set $pairs -a $AppName
            if ($LASTEXITCODE -ne 0) { Write-Err '设置密钥失败'; exit 1 }
        }
        Write-Ok ('已写入: ' + (($pairs | ForEach-Object { $_.Split('=')[0] }) -join ', '))
        if ($script:AuthToken) {
            Write-Host ('    Token: ' + $script:AuthToken) -ForegroundColor Green
            Write-Warn '客户端 frpc.toml / frpc-udp.toml 的 auth.token 要改成这个值'
        }
    } else {
        Write-Ok '三个密钥都已设置，无需改动'
    }

    # ------------------------------------------------------------ 6. IPv4（UDP 需要）
    if (-not $SkipIpCheck) {
        Write-Step '检查 IP（UDP 需要独立 IPv4）'
        $ips = (fly ips list -a $AppName 2>$null | Out-String)
        $dedicatedV4 = ($ips -split "`n") | Where-Object { $_ -match '\bv4\b' -and $_ -notmatch 'shared' }
        if ($dedicatedV4) {
            Write-Ok '已有独立 IPv4，UDP 可用'
            Write-Tip ($dedicatedV4 -join '; ').Trim()
        } else {
            Write-Warn '没有独立 IPv4，UDP 端口（6100-6104）会不通；TCP/HTTP/HTTPS 不受影响'
            Write-Tip  '需要 UDP 就执行：fly ips allocate-v4  （约 $2/月）'
        }
    }

    # ------------------------------------------------------------ 7. 部署
    Write-Step '开始部署（fly deploy）'
    $args = @('deploy', '-a', $AppName)
    if ($RemoteOnly) { $args += '--remote-only' }
    if ($NoWait)     { $args += '--detach'; Write-Warn '已加 --detach：不等机器 healthy 就返回' }
    fly @args
    if ($LASTEXITCODE -ne 0) {
        Write-Err '部署失败'
        Write-Tip '若卡在 "Waiting for ... to become healthy"，重新运行：./deploy.ps1 -NoWait'
        Write-Tip '然后用 fly status / fly logs 确认；健康检查走的是仪表盘的 /healthz（7500 端口）'
        exit 1
    }
    Write-Ok '部署完成'

    # ------------------------------------------------------------ 8. 状态
    Write-Step '部署后状态'
    fly status -a $AppName

    Write-Host @"

------------------------------------------------------------------
  仪表盘 : https://$AppName.fly.dev
  frpc   : serverAddr = "$AppName.fly.dev"
           TCP/HTTP/HTTPS -> serverPort 7000
           UDP            -> serverPort 7001
  端口组 : TCP 6000-6004 / UDP 6100-6104 / HTTP 8080-8084 / HTTPS 8443-8447
------------------------------------------------------------------
"@ -ForegroundColor Cyan

    if ($Logs) {
        Write-Step '跟随日志（Ctrl+C 退出）'
        fly logs -a $AppName
    }
}
finally {
    Pop-Location
}
