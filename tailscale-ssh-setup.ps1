#Requires -RunAsAdministrator
<#
  tailscale-ssh-setup.ps1  -Action On | Stop | Off  [-Uninstall]
 
  On   : 只在第一次執行時拍下「動手前」的狀態快照(baseline snapshot),
         然後依序:安裝 OpenSSH Server -> 先把防火牆鎖到只剩 Tailscale
         (Tailscale 網段 + Tailscale 網路介面)-> 才啟動 sshd(只允許 key
         驗證、Shell 用 PowerShell,並用 sshd -t / sshd -T 驗證設定真的生效)
         -> 加入 Tailscale(tailscale up 失敗就整個中止,不會假裝成功)。
         成功後會印出連線端要用的連線指令。
  Stop : 輕量的暫停,不是還原。只是停掉 sshd,並執行 "tailscale down"
         (不是 logout,裝置還是保持註冊狀態)。防火牆規則、sshd_config、
         Tailscale 的註冊狀態完全不會被動到,所以之後再執行 -Action On
         可以立刻恢復,不用重新輸入、不用新的 auth key、也不用再跑
         一次 UAC 流程。想暫時關閉遠端存取、之後還會再連的時候用這個。
  Off  : 真正的還原。讀回之前存的快照,把每一項都還原成原本的樣子:
          - sshd 服務還原成原本的 StartupType/Status
          - sshd_config 從第一次執行 On 時的備份還原
          - Windows 內建的 OpenSSH 防火牆規則還原成原本的 Enabled 狀態
          - 移除我們自己加的防火牆規則
          - sshd 的 DefaultShell 登錄值還原成原本的值(或整個移除)
          - Tailscale:只有在「這支腳本自己註冊的」情況下才會登出;
            如果你執行 On 之前它本來就已經註冊過(就算當時是斷線的),
            或是找不到快照、無法判斷,就完全不會動它
        找不到快照時(例如 $Dir 被刪掉)只做保守清理:停 sshd、移除我們
        的防火牆規則和 client key;DefaultShell 只有在目前的值等於我們
        設的那個時才移除;Tailscale 不動(要登出請自己跑 tailscale logout)。
        這支腳本只負責建立遠端連線(SSH + Tailscale)本身,不管任何排程
        工作,也不處理電源設定——那些都是各自獨立的腳本在處理,跟這支
        完全無關、也不互相依賴。
        加上 -Uninstall 會再多做:只在「這支腳本自己裝的」情況下解除
        安裝 Tailscale 和 OpenSSH Server 功能,然後刪除 state.json 和
        設定檔備份。
 
  需要手動放到 $Dir(預設 C:\Exhibit\remote)的東西:
    tailscale-ssh-setup.ps1
    mac.pub       - 要連線那台裝置的 SSH public key,一行
 
  另外 $Dir\ts.authkey 是選用的手動逃生口:不會被這支腳本自動建立,
  但如果你自己把 Tailscale 的 auth key(建議用 ephemeral、one-off、
  短效期的)寫成這個檔案放在那裡,-Action On 在沒有收到
  -TailscaleAuthKey 參數時會改讀這個檔案;tailscale up 成功後這個檔案
  會立刻被刪掉(只需要用一次)。-TailscaleAuthKey 會出現在命令列和
  PowerShell 歷史紀錄裡,能用檔案就用檔案。
  On 會把 $Dir 的權限收斂成只有 Administrators 和 SYSTEM 能存取。
 
  這裡沒有任何隱藏動作;視窗會一直開著,過程全部印出來給你看。
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('On', 'Stop', 'Off')][string]$Action,
    [string]$Dir = 'C:\Exhibit\remote',
    [string]$TailscaleHostname = 'remote-host',
    [string]$TailscaleAuthKey = '',
    [switch]$Uninstall
)
 
$ErrorActionPreference = 'Stop'
$ts        = "$env:ProgramFiles\Tailscale\tailscale.exe"
$sshdExe   = "$env:WINDIR\System32\OpenSSH\sshd.exe"
$psShell   = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$tsRemoteAddr = @('100.64.0.0/10', 'fd7a:115c:a1e0::/48')
$akFile    = 'C:\ProgramData\ssh\administrators_authorized_keys'
$cfg       = 'C:\ProgramData\ssh\sshd_config'
$ruleName  = 'sshd-tailscale-only'
$builtinRule = 'OpenSSH-Server-In-TCP'
$keyFile   = Join-Path $Dir 'mac.pub'
$authFile  = Join-Path $Dir 'ts.authkey'
$stateFile = Join-Path $Dir 'state.json'
$cfgBackup = Join-Path $Dir 'sshd_config.orig.bak'
 
function Step($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
 
function Get-TsInfo {
    $info = @{ Ip = '(not connected)'; Name = ''; BackendState = 'NotInstalled' }
    if (Test-Path $ts) {
        $info.BackendState = 'Unknown'   # 已安裝,但 daemon 沒回應(例如服務還沒起來)
        try {
            $st = (& $ts status --json 2>$null) | ConvertFrom-Json
            if ($st) {
                $info.BackendState = $st.BackendState
                if ($st.Self.DNSName) { $info.Name = $st.Self.DNSName.TrimEnd('.') }
                if ($st.Self.TailscaleIPs) { $info.Ip = $st.Self.TailscaleIPs[0] }
            }
        } catch {}
    }
    return $info
}
 
function Show-Status($title, $color) {
    $svc  = Get-Service sshd -ErrorAction SilentlyContinue
    $sshd = if ($svc) { "$($svc.Status) / $($svc.StartType)" } else { 'not installed' }
    $rule = if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { 'present' } else { 'absent' }
    $t    = Get-TsInfo
    Write-Host ""
    Write-Host "############################################################" -ForegroundColor $color
    Write-Host "   $title" -ForegroundColor $color
    Write-Host "############################################################" -ForegroundColor $color
    Write-Host "   sshd service     : $sshd"
    Write-Host "   firewall rule    : $rule"
    Write-Host "   Tailscale state  : $($t.BackendState)"
    Write-Host "   Tailscale IPv4   : $($t.Ip)"
    if ($t.Name) { Write-Host "   Tailscale name   : $($t.Name)" }
    if ($Action -eq 'On' -and $t.Ip -ne '(not connected)') {
        Write-Host ""
        Write-Host "   CONNECT:" -ForegroundColor Yellow
        Write-Host "     ssh $env:USERNAME@$($t.Ip)" -ForegroundColor Yellow
        if ($t.Name) { Write-Host "     ssh $env:USERNAME@$($t.Name)" -ForegroundColor Yellow }
    }
    Write-Host "############################################################" -ForegroundColor $color
    Write-Host ""
}
 
# 把 sshd_config 裡某個設定改成指定的值(含被註解掉的預設行)。只改第一個 Match
# 區塊之前的全域設定;如果整個檔案都沒有這個設定,就補在第一個 Match 之前
# (Match 之後的設定只對該區塊有效,補在後面是錯的)。
function Set-SshdOption {
    param([string[]]$Lines, [string]$Name, [string]$Value)
    $pattern = '^\s*#?\s*' + [regex]::Escape($Name) + '\s+'
    $out     = New-Object System.Collections.Generic.List[string]
    $done    = $false
    $inMatch = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*Match\s+') {
            if (-not $done) { $out.Add("$Name $Value"); $done = $true }
            $inMatch = $true
        }
        if (-not $inMatch -and $line -match $pattern) {
            $out.Add("$Name $Value"); $done = $true
        } else {
            $out.Add($line)
        }
    }
    if (-not $done) { $out.Add("$Name $Value") }
    return ,$out.ToArray()
}

# 建立/更新 sshd 的防火牆規則:來源只能是 Tailscale 網段。100.64.0.0/10 是整個
# CGNAT 保留範圍、不是 Tailscale 專屬(ISP CGNAT 或熱點網路下,同網段的其他人
# 也會落在裡面),所以只要 Tailscale 網路介面已經存在,就再加上「只限這張介面」。
# 回傳 $true 代表這次已經綁定到 Tailscale 介面。
function Set-SshFirewallRule {
    $params = @{
        Enabled       = 'True'
        Direction     = 'Inbound'
        Protocol      = 'TCP'
        Action        = 'Allow'
        LocalPort     = 22
        RemoteAddress = $tsRemoteAddr
    }
    $bound = [bool](Get-NetAdapter -Name 'Tailscale' -ErrorAction SilentlyContinue)
    if ($bound) { $params.InterfaceAlias = 'Tailscale' }
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $ruleName @params | Out-Null
    } else {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH (Tailscale only)' @params | Out-Null
    }
    return $bound
}

# =============================================================== On(開啟連線)
if ($Action -eq 'On') {
 
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    # state.json、sshd_config 備份、ts.authkey 都放在這裡 - 只讓 Administrators 和 SYSTEM 存取
    # (C:\ 底下新建的資料夾預設連一般使用者都讀得到)。用 SID 避免非英文版 Windows 的群組名稱問題。
    icacls $Dir /inheritance:r /grant '*S-1-5-32-544:(OI)(CI)F' /grant '*S-1-5-18:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $Dir (exit code $LASTEXITCODE)." }
 
    if (-not (Test-Path $keyFile)) { throw "Missing $keyFile - copy the client's public key there first (one-time setup)." }
    $key = (Get-Content $keyFile -Raw).Trim()
    if ($key -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-\S+) ') { throw "$keyFile is not an OpenSSH public key." }
 
    # ---------- 拍下「動手前」的狀態快照,只在第一次執行 On 時做 ----------
    if (-not (Test-Path $stateFile)) {
        Step "Capturing baseline state (first run only)"
        $capBefore = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
        $svcBefore = Get-Service sshd -ErrorAction SilentlyContinue
        $builtinRuleBefore = Get-NetFirewallRule -Name $builtinRule -ErrorAction SilentlyContinue
        $tsInstalledBefore = Test-Path $ts
        $tsStateBefore = (Get-TsInfo).BackendState
        $defaultShellBefore = $null
        $defaultShellExistedBefore = $false
        $opensshRegKeyExistedBefore = Test-Path 'HKLM:\SOFTWARE\OpenSSH'
        if ($opensshRegKeyExistedBefore) {
            $dsProp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
            if ($dsProp -and ($dsProp.PSObject.Properties.Name -contains 'DefaultShell')) {
                $defaultShellExistedBefore = $true
                $defaultShellBefore = $dsProp.DefaultShell
            }
        }
        $akFileExistedBefore = Test-Path $akFile
 
        $state = [ordered]@{
            sshCapabilityWasInstalled  = ($capBefore.State -eq 'Installed')
            sshdExistedBefore          = [bool]$svcBefore
            sshdOriginalStartType      = if ($svcBefore) { $svcBefore.StartType.ToString() } else { $null }
            sshdOriginalStatus         = if ($svcBefore) { $svcBefore.Status.ToString() } else { $null }
            builtinRuleWasEnabled      = if ($builtinRuleBefore) { $builtinRuleBefore.Enabled -eq 'True' } else { $null }
            defaultShellExistedBefore  = $defaultShellExistedBefore
            defaultShellOriginalValue  = $defaultShellBefore
            opensshRegKeyExistedBefore = $opensshRegKeyExistedBefore
            akFileExistedBefore        = $akFileExistedBefore
            tailscaleWasInstalled      = $tsInstalledBefore
            tailscaleWasConnected      = ($tsStateBefore -eq 'Running')
            # 已登入過 tailnet(就算當時是斷線的)也算;daemon 沒回應(Unknown)時保守地當成已註冊
            tailscaleWasRegistered     = ($tsInstalledBefore -and ($tsStateBefore -notin @('NeedsLogin', 'NoState')))
        }
        $state | ConvertTo-Json -Depth 5 | Set-Content -Path $stateFile -Encoding utf8
 
        # 在還沒動到 sshd_config 之前先備份(只有在 sshd 已安裝的情況下才有意義)
        if ((Test-Path $cfg) -and -not (Test-Path $cfgBackup)) {
            Copy-Item $cfg $cfgBackup -Force
        }
    } else {
        Write-Host "(baseline already captured on a previous run - not overwriting it)" -ForegroundColor DarkGray
    }
 
    Step "OpenSSH Server (install)"
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
    if ($cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }

    # 先把防火牆鎖好,再啟動 sshd。裝完 OpenSSH Server 後,內建的 OpenSSH-Server-In-TCP
    # 規則通常是啟用的、對所有位址開放;如果先 Start-Service,在 sshd 改成只允許 key、
    # 規則收斂之前,會有一段時間是「預設設定(可用密碼登入)+ 任何網路都連得到」。
    Step "Firewall: port 22 from Tailscale only (before sshd starts)"
    Disable-NetFirewallRule -Name $builtinRule -ErrorAction SilentlyContinue
    [void](Set-SshFirewallRule)

    Step "OpenSSH Server (start)"
    Set-Service sshd -StartupType Automatic
    Start-Service sshd   # 第一次啟動時才會產生 sshd_config 和 host key
    if (-not (Test-Path $cfgBackup) -and (Test-Path $cfg)) { Copy-Item $cfg $cfgBackup -Force }  # 安全網
    if (-not (Test-Path 'HKLM:\SOFTWARE\OpenSSH')) { New-Item 'HKLM:\SOFTWARE\OpenSSH' -Force | Out-Null }
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
        -Value $psShell -PropertyType String -Force | Out-Null

    Step "Client key + key-only login"
    if (-not (Test-Path $akFile)) { New-Item $akFile -ItemType File -Force | Out-Null }
    if (-not (Select-String -Path $akFile -SimpleMatch $key -Quiet)) { Add-Content -Path $akFile -Value $key -Encoding ascii }
    # 用 SID 而不是名稱:非英文版 Windows 的群組名稱可能被本地化
    icacls $akFile /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "icacls failed on $akFile (exit code $LASTEXITCODE) - not continuing with unverified permissions." }
    $text = Get-Content $cfg
    $text = Set-SshdOption $text 'PubkeyAuthentication' 'yes'
    $text = Set-SshdOption $text 'PasswordAuthentication' 'no'
    Set-Content -Path $cfg -Value $text -Encoding ascii
    & $sshdExe -t
    if ($LASTEXITCODE -ne 0) { throw "sshd_config failed validation (sshd -t, exit code $LASTEXITCODE); sshd was NOT restarted. Run -Action Off to restore the original config." }
    Restart-Service sshd
    # 驗證「實際生效」的設定,不要只相信我們有改過檔案
    $effective = (& $sshdExe -T) -join "`n"
    if ($effective -notmatch '(?m)^passwordauthentication\s+no\s*$') { throw "sshd is NOT running with PasswordAuthentication no (inspect with: sshd -T). Not reporting REMOTE ACCESS: ON." }
    if ($effective -notmatch '(?m)^pubkeyauthentication\s+yes\s*$')  { throw "sshd is NOT running with PubkeyAuthentication yes (inspect with: sshd -T). Not reporting REMOTE ACCESS: ON." }

    Step "Tailscale"
    if (-not (Test-Path $ts)) {
        winget install --id Tailscale.Tailscale -e --silent --accept-source-agreements --accept-package-agreements
    }
    if (-not (Test-Path $ts)) { throw "Tailscale is not installed (winget missing?). Install it manually and run again." }
    # 剛裝完時 Tailscale 服務可能還沒起來;先等它 Running,不然 tailscale up 會直接失敗
    for ($i = 0; $i -lt 30; $i++) {
        $tsSvc = Get-Service Tailscale -ErrorAction SilentlyContinue
        if (-not $tsSvc -or $tsSvc.Status -eq 'Running') { break }
        if ($tsSvc.Status -eq 'Stopped') { Start-Service Tailscale -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
    }
    $usedAuthFile = $false
    $tsArgs = @('up', '--unattended', "--hostname=$TailscaleHostname")
    if ($TailscaleAuthKey) {
        # 直接當作命令列參數傳入,這支腳本不會把它寫進任何檔案
        $tsArgs += "--auth-key=$TailscaleAuthKey"
    } elseif (Test-Path $authFile) {
        $tsArgs += "--auth-key=$((Get-Content $authFile -Raw).Trim())"
        $usedAuthFile = $true
    } else {
        $tsArgs += '--qr'   # 沒有提供 auth key:改成顯示 QR code,掃描或開啟網址來核准這台裝置
    }
    & $ts @tsArgs
    # 原生指令失敗不會自動 throw;不檢查的話,auth key 錯誤、服務沒起來、或已登入節點的
    # flag 衝突都會被吞掉,然後下面還是印出 "REMOTE ACCESS: ON"。
    if ($LASTEXITCODE -ne 0) {
        throw "'tailscale up' failed (exit code $LASTEXITCODE). Check the auth key; if this device was already on a tailnet, read the error above (e.g. 'requires mentioning all non-default flags'). sshd and the firewall rule are already set up - fix the Tailscale problem and re-run -Action On."
    }
    $tsNow = Get-TsInfo
    for ($i = 0; $i -lt 10 -and $tsNow.BackendState -ne 'Running'; $i++) { Start-Sleep -Seconds 1; $tsNow = Get-TsInfo }
    if ($tsNow.BackendState -ne 'Running') {
        throw "Tailscale is not in the Running state after 'tailscale up' (state: $($tsNow.BackendState)). Not reporting REMOTE ACCESS: ON."
    }
    if ($usedAuthFile) {
        Remove-Item $authFile -Force
        Write-Host "Deleted $authFile (the auth key is only needed once)." -ForegroundColor DarkGray
    }

    # 現在 Tailscale 網路介面存在了:把防火牆規則再收緊成「只限這張介面」
    $bound = $false
    try { $bound = Set-SshFirewallRule } catch { Write-Warning "Could not bind the firewall rule to the Tailscale adapter: $($_.Exception.Message)" }
    if (-not $bound) { Write-Warning "Firewall rule is limited by source address only (100.64.0.0/10, fd7a:115c:a1e0::/48), not by network adapter." }

    Show-Status 'REMOTE ACCESS: ON' 'Green'
}
 
# =============================================================== Stop(輕量暫停,可逆)
if ($Action -eq 'Stop') {
 
    Step "Stop sshd (config and firewall rule are left untouched)"
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Manual -ErrorAction SilentlyContinue
 
    Step "Tailscale: disconnect without logging out (stays registered)"
    if (Test-Path $ts) {
        try { & $ts down 2>$null } catch {}
    }
 
    Show-Status 'REMOTE ACCESS: STOPPED (paused - run -Action On to resume instantly)' 'Yellow'
}
 
# =============================================================== Off(完整還原)
if ($Action -eq 'Off') {
 
    if (-not (Test-Path $stateFile)) {
        Write-Warning "No state.json found - this script was never run with -Action On on this machine (or $Dir was deleted). Doing best-effort cleanup only."
        $state = $null
    } else {
        $state = Get-Content $stateFile -Raw | ConvertFrom-Json
    }
 
    Step "Stop SSH, restore sshd_config"
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    if (Test-Path $cfgBackup) { Copy-Item $cfgBackup $cfg -Force }
    # 先確認 sshd 服務真的存在再去動它的 StartupType - 如果這支腳本是在
    # sshd 根本沒裝(例如還沒 On 過,或先前 -Uninstall 已經移除過)的機器
    # 上被叫來做 best-effort cleanup,Set-Service 對不存在的服務會丟出
    # terminating error,把後面防火牆/DefaultShell/Tailscale 的還原都卡住。
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        if ($state -and $state.sshdExistedBefore) {
            Set-Service sshd -StartupType $state.sshdOriginalStartType -ErrorAction SilentlyContinue
            if ($state.sshdOriginalStatus -eq 'Running') { Start-Service sshd -ErrorAction SilentlyContinue }
        } else {
            Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue
        }
    }
 
    Step "Remove firewall rule, restore built-in rule, remove client key"
    Remove-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue
    if ($state -and $state.builtinRuleWasEnabled -ne $null) {
        if ($state.builtinRuleWasEnabled) { Enable-NetFirewallRule -Name $builtinRule -ErrorAction SilentlyContinue }
        else { Disable-NetFirewallRule -Name $builtinRule -ErrorAction SilentlyContinue }
    }
    if ((Test-Path $akFile) -and (Test-Path $keyFile)) {
        $key = (Get-Content $keyFile -Raw).Trim()
        $left = @(Get-Content $akFile | Where-Object { $_.Trim() -ne $key })
        Set-Content -Path $akFile -Value $left -Encoding ascii
        # 如果這個檔案是 On 自己從零建立的(之前不存在),拿掉我們那行之後
        # 不要留一個空檔案在那邊 - 整個刪掉,回到「原本沒有這個檔案」。
        if (-not ($state -and $state.akFileExistedBefore)) {
            $remaining = @(Get-Content $akFile | Where-Object { $_.Trim() -ne '' })
            if ($remaining.Count -eq 0) { Remove-Item $akFile -Force -ErrorAction SilentlyContinue }
        }
    }
 
    Step "Restore sshd DefaultShell registry value"
    # On 一定會把這個值設成 PowerShell;如果之前這台機器本來就有設過
    # (理論上少見),就還原成原本的值,否則整個移除,恢復成「沒有這個
    # registry 值」的狀態(等於 sshd 走系統預設 shell)。
    # 找不到快照時不知道原本有沒有設過:只有在目前的值剛好等於我們設的那個
    # 才移除,否則留著,避免把使用者自己設的 DefaultShell(例如 pwsh 7)刪掉。
    if (Test-Path 'HKLM:\SOFTWARE\OpenSSH') {
        if ($state -and $state.defaultShellExistedBefore) {
            New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell `
                -Value $state.defaultShellOriginalValue -PropertyType String -Force | Out-Null
        } else {
            $curShell = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue).DefaultShell
            if ($state -or $curShell -eq $psShell) {
                Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -ErrorAction SilentlyContinue
                # 這個 registry 機碼本身也是 On 自己建的(之前不存在)就整個刪掉;
                # 如果裡面還有其他值(理論上不會是我們加的)就保留,不要動。
                if (-not ($state -and $state.opensshRegKeyExistedBefore)) {
                    $remainingProps = (Get-Item 'HKLM:\SOFTWARE\OpenSSH' -ErrorAction SilentlyContinue).Property
                    if (-not $remainingProps -or $remainingProps.Count -eq 0) {
                        Remove-Item 'HKLM:\SOFTWARE\OpenSSH' -Force -ErrorAction SilentlyContinue
                    }
                }
            } elseif ($curShell) {
                Write-Host "No baseline, and DefaultShell is '$curShell' (not the value this script sets) - leaving it as-is." -ForegroundColor Yellow
            }
        }
    }

    Step "Tailscale"
    if (-not $state) {
        Write-Host "No baseline - can't tell whether this script registered Tailscale, so it is left untouched." -ForegroundColor Yellow
        Write-Host "(To remove this device from your tailnet yourself, run: tailscale logout)" -ForegroundColor Yellow
    } elseif (Test-Path $ts) {
        # tailscaleWasRegistered 是「On 之前就已經登入過這個 tailnet」(就算當時是斷線的);
        # 舊版快照沒有這個欄位,退回看 tailscaleWasConnected。
        if ($state.tailscaleWasRegistered -or $state.tailscaleWasConnected) {
            Write-Host "Tailscale was already registered before -Action On ran - leaving it as-is." -ForegroundColor DarkGray
        } else {
            try { & $ts down 2>$null } catch {}
            try { & $ts logout 2>$null } catch {}
        }
    }

    Step "Delete per-run auth key file"
    if (Test-Path $authFile) { Remove-Item $authFile -Force }
 
    if ($Uninstall) {
        Step "Uninstall what THIS script installed"
        if ($state -and -not $state.tailscaleWasInstalled) {
            winget uninstall --id Tailscale.Tailscale -e --silent 2>$null
        }
        if ($state -and -not $state.sshCapabilityWasInstalled) {
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*'
            if ($cap.State -eq 'Installed') { Remove-WindowsCapability -Online -Name $cap.Name | Out-Null }
        }
        Remove-Item $stateFile, $cfgBackup -Force -ErrorAction SilentlyContinue
        Write-Host "state.json and sshd_config backup removed - next -Action On will capture a fresh baseline."
    }
 
    Show-Status 'REMOTE ACCESS: OFF (restored)' 'Red'
}
