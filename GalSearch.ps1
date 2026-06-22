param()

$ErrorActionPreference = 'Stop'

# 启用 TLS 1.2（PS 5.1 默认没有）
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web

# ============ 全局变量 ============
$AppName = 'GalSearchMVP'
$AppDir = Join-Path $env:LOCALAPPDATA $AppName
$DataFile = Join-Path $AppDir 'index.json'
$script:gQuery = ""       # 全局搜索词，所有函数从这里读
$script:gSource = "全部"   # 全局来源筛选
$script:gSort = "相关性"   # 全局排序
$script:queryLimit = 50    # 每次搜索显示上限
$script:lastQuery = ""     # 上次搜索词（用于判断是否同词搜索）
$script:gActiveProfile = "Default"   # 当前激活的用户配置名
$script:gViewMode = "search"        # 视图模式: "search" 或 "favorites"
$script:gPrefs = $null              # 当前配置的偏好设置缓存
$script:pollTickCount = 0           # 图片轮询计数器
$script:imgCachePaths = @()         # 图片缓存文件路径列表（供左右切换）
$script:imgCurrentIndex = 0         # 当前显示的图片索引
$script:imgLoadedForTitle = ""      # 当前图片对应的标题，切结果时不重复加载
$script:imgLoadingTitle = ""        # 正在加载的图片标题
function Set-DefaultLimit { $script:queryLimit = 50 }  # 重置为默认50条
# ============ 用户配置/偏好/收藏/历史 ============
function Migrate-V1ToV2 {
    param([Parameter(Mandatory)]$State)
    if ($State.Version -ge 2) { return $State }
    # 添加 IsFavorite 到每个项目
    if ($State.Items) {
        foreach ($item in $State.Items) {
            if ($null -eq $item.IsFavorite) { $item | Add-Member -NotePropertyName IsFavorite -NotePropertyValue $false -Force }
        }
    }
    # 创建默认配置
    $defaultPrefs = [pscustomobject]@{ PerPage = 20; SortMode = "相关性"; SourceFilter = "全部"; AutoScanOnStartup = $false; OnlineSearchEnabled = $true }
    $defaultProfile = [pscustomobject]@{ Preferences = $defaultPrefs; Favorites = @(); History = @() }
    $State | Add-Member -NotePropertyName Profiles -NotePropertyValue ([ordered]@{ "Default" = $defaultProfile }) -Force
    $State | Add-Member -NotePropertyName ActiveProfile -NotePropertyValue "Default" -Force
    $State.Version = 2
    Save-State -State $State
    return $State
}
function Get-ActiveProfileName { return $script:gActiveProfile }
function Get-ProfileList {
    param([Parameter(Mandatory)]$State)
    if ($null -eq $State.Profiles) { return @("Default") }
    return @($State.Profiles.PSObject.Properties.Name)
}
function Get-ProfileData {
    param([Parameter(Mandatory)]$State, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Default" }
    $p = $State.Profiles
    if ($null -eq $p) { return $null }
    return $p.$Name
}
function Set-ActiveProfile {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = "Default" }
    $script:gActiveProfile = $Name
    $state = Load-State
    $state.ActiveProfile = $Name
    Save-State -State $state
    # 刷新偏好缓存
    $pd = Get-ProfileData -State $state -Name $Name
    if ($pd -and $pd.Preferences) { $script:gPrefs = $pd.Preferences } else { $script:gPrefs = $null }
}
function Initialize-UserModule {
    $state = Load-State
    if ($state.Version -lt 2) { $state = Migrate-V1ToV2 -State $state }
    $active = $state.ActiveProfile
    if ([string]::IsNullOrWhiteSpace($active)) { $active = "Default" }
    $script:gActiveProfile = $active
    $pd = Get-ProfileData -State $state -Name $active
    if ($pd -and $pd.Preferences) { $script:gPrefs = $pd.Preferences }
}
# ============ 收藏/历史核心函数 ============
function Toggle-Favorite {
    param([Parameter(Mandatory)]$Item)
    $state = Load-State
    if ($null -eq $state.Items) { return $false }
    $found = $false
    foreach ($ci in $state.Items) {
        if ($ci.Url -eq $Item.Url) {
            $newVal = if ($ci.IsFavorite) { $false } else { $true }
            $ci.IsFavorite = $newVal
            $Item.IsFavorite = $newVal   # 同步内存中的条目
            $found = $true
            break
        }
    }
    if (-not $found) {
        # 条目不在缓存中（如本地扫描），直接设
        $Item | Add-Member -NotePropertyName IsFavorite -NotePropertyValue $true -Force
        $state.Items += $Item
    }
    Save-State -State $state
    Write-DiagLog "Fav: $($Item.Title) -> $($Item.IsFavorite)"
    return $Item.IsFavorite
}
function Get-Favorites {
    $state = Load-State
    if ($null -eq $state.Items) { return @() }
    return @($state.Items | Where-Object { $_.IsFavorite })
}
function Add-HistoryEntry {
    param([Parameter(Mandatory)]$Item)
    $state = Load-State
    if ($null -eq $state.Items) { return }
    $name = Get-ActiveProfileName
    $pd = Get-ProfileData -State $state -Name $name
    if ($null -eq $pd) { return }
    if ($null -eq $pd.History) { $pd.History = @() }
    # 去重：同一 URL 不重复添加
    $exists = @($pd.History | Where-Object { $_.Url -eq $Item.Url })
    if ($exists.Count -gt 0) { return }
    $pd.History += [pscustomobject]@{ Url = $Item.Url; Title = $Item.Title; VisitedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
    Save-State -State $state
    Write-DiagLog "Hist: $($Item.Url)"
}
function Get-HistoryEntries {
    $state = Load-State
    $name = Get-ActiveProfileName
    $pd = Get-ProfileData -State $state -Name $name
    if ($null -eq $pd -or $null -eq $pd.History) { return @() }
    return @($pd.History | Sort-Object @{E = { $_.VisitedAt }; Descending = $true })
}
# ============ 存储 ============
function Ensure-Storage {
    if (-not (Test-Path $AppDir)) { New-Item -ItemType Directory -Path $AppDir | Out-Null }
    if (-not (Test-Path $DataFile)) {
        $defaultPrefs = [pscustomobject]@{ PerPage = 20; SortMode = "相关性"; SourceFilter = "全部"; AutoScanOnStartup = $false; OnlineSearchEnabled = $true }
        $defaultProfile = [pscustomobject]@{ Preferences = $defaultPrefs; Favorites = @(); History = @() }
        $seed = [ordered]@{ Version = 2; Items = @(); Profiles = [ordered]@{ "Default" = $defaultProfile }; ActiveProfile = "Default" }
        $seed | ConvertTo-Json -Depth 16 | Set-Content -Path $DataFile -Encoding UTF8
    }
}

function Load-State {
    Ensure-Storage
    try { $raw = Get-Content -Path $DataFile -Raw -Encoding UTF8; if ([string]::IsNullOrWhiteSpace($raw)) { return [ordered]@{ Version = 1; Items = @() } }; $state = $raw | ConvertFrom-Json; if ($null -eq $state.Items) { $state | Add-Member -NotePropertyName Items -NotePropertyValue @() -Force }; if ($state.Version -lt 2) { return Migrate-V1ToV2 -State $state }; return $state } catch { return [ordered]@{ Version = 1; Items = @() } }
}

function Save-State { param([Parameter(Mandatory)]$State) $State | ConvertTo-Json -Depth 16 | Set-Content -Path $DataFile -Encoding UTF8 }

# ============ 工具函数 ============
function Get-TextValue { param($V) if ($null -eq $V) { return '' }; return [string]$V }

function New-ResultObject {
    param([string]$T, [string]$U, [string]$Sn, [string]$Sr, [string]$Q)
    [pscustomobject]@{ Id = ([guid]::NewGuid()).ToString(); Title = $T; Url = $U; Snippet = $Sn; Source = $Sr; Query = $Q; Tags = @(); IsFavorite = $false; CachedAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); LastSeenAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"); SeenCount = 1 }
}

function Get-SearchTerms {
    param([string]$Q)
    if ([string]::IsNullOrWhiteSpace($Q)) { return @() }
    $s = [regex]::Split($Q.ToLowerInvariant(), "[\s,;/\|]+")
    return @($s | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
}

# ============ 缓存合并 ============
function Merge-Items {
    param([Parameter(Mandatory)]$E, [Parameter(Mandatory)]$N)
    $m = @{}; foreach ($i in $E) { if ($i.Url) { $m[$i.Url] = $i } }
    foreach ($i in $N) {
        if ([string]::IsNullOrWhiteSpace($i.Url)) { continue }
        if ($m.ContainsKey($i.Url)) {
            $c = $m[$i.Url]
            # 保留现有收藏状态
            $fav = if ($null -ne $c.IsFavorite) { $c.IsFavorite } else { $false }
            if (-not [string]::IsNullOrWhiteSpace($i.Title)) { $c.Title = $i.Title }
            if (-not [string]::IsNullOrWhiteSpace($i.Snippet)) { $c.Snippet = $i.Snippet }
            $c.Source = $i.Source; $c.Query = $i.Query
            $c.LastSeenAt = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
            $c.SeenCount = [int]$c.SeenCount + 1
            $c.IsFavorite = $fav
        } else {
            # 新条目确保有 IsFavorite
            if ($null -eq $i.IsFavorite) { $i | Add-Member -NotePropertyName IsFavorite -NotePropertyValue $false -Force }
            $m[$i.Url] = $i
        }
    }
    return @($m.Values)
}

function Update-Index { param([Parameter(Mandatory)]$Items) $s = Load-State; $e = @(); if ($s.Items) { $e = @($s.Items) }; $s.Items = Merge-Items -E $e -N $Items; Save-State -State $s }

function Write-DiagLog {
    param([string]$M)
    $logFile = Join-Path $AppDir 'diag.log'
    $ts = (Get-Date).ToString("HH:mm:ss.fff")
    try { [System.IO.File]::AppendAllText($logFile, "$ts $M`r`n", [System.Text.UTF8Encoding]::new($false)) } catch {}
}

function Score-Item {
    param([Parameter(Mandatory)]$I, [string[]]$T)
    if (-not $T -or $T.Count -eq 0) { return 1 }
    $ti = (Get-TextValue $I.Title).ToLowerInvariant(); $sn = (Get-TextValue $I.Snippet).ToLowerInvariant(); $u = (Get-TextValue $I.Url).ToLowerInvariant(); $sr = (Get-TextValue $I.Source).ToLowerInvariant(); $sc = 0
    foreach ($t in $T) { if ([string]::IsNullOrWhiteSpace($t)) { continue }; if ($ti.Contains($t)) { $sc += 100 }; if ($sn.Contains($t)) { $sc += 25 }; if ($u.Contains($t)) { $sc += 15 }; if ($sr.Contains($t)) { $sc += 5 } }
    return $sc
}

function Test-ItemMatches {
    param([Parameter(Mandatory)]$I, [string[]]$T)
    if (-not $T -or $T.Count -eq 0) { return $true }
    $h = (Get-TextValue $I.Title) + " " + (Get-TextValue $I.Snippet) + " " + (Get-TextValue $I.Url) + " " + (Get-TextValue ($I.Tags -join " "))
    $h = $h.ToLowerInvariant(); foreach ($t in $T) { if (-not $h.Contains($t)) { return $false } }; return $true
}

# ============ 百度搜索（纯IndexOf，不从参数读中文）============中文）============
function Invoke-BaiduSearch {
    param([int]$M = 20)
    # 从全局变量读搜索词
    $q = $script:gQuery
    if ([string]::IsNullOrWhiteSpace($q)) { return @() }
    $e = [uri]::EscapeDataString($q)
    $url = "https://www.baidu.com/s?wd=$e&rn=$M&ie=utf-8"
    $h = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"; "Accept-Language" = "zh-CN,zh;q=0.9,en;q=0.8"; "Accept" = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }
    try { $r = Invoke-WebRequest -Uri $url -Headers $h -TimeoutSec 20 -UseBasicParsing } catch { return @() }
    $html = [System.Web.HttpUtility]::HtmlDecode($r.Content)
    $res = New-Object System.Collections.Generic.List[object]

    $pos = 0
    while ($pos -lt $html.Length) {
        $h3s = $html.IndexOf('<h3 class="t', $pos)
        if ($h3s -lt 0) { break }
        $h3e = $html.IndexOf('</h3>', $h3s)
        if ($h3e -lt 0) { break }

        $blen = $h3e - $h3s + 6
        if ($blen -gt 2000) { $pos = $h3s + 6; continue }

        $hrefPos = $html.IndexOf('href="', $h3s, $blen)
        if ($hrefPos -lt 0) { $pos = $h3s + 6; continue }
        $hrefStart = $hrefPos + 6
        $hrefEnd = $html.IndexOf('"', $hrefStart)
        if ($hrefEnd -lt 0) { $pos = $h3s + 6; continue }
        $urlVal = $html.Substring($hrefStart, $hrefEnd - $hrefStart)

        $block = $html.Substring($h3s, $blen)
        $title = ""
        $ti = 0; $inTag = $false
        while ($ti -lt $block.Length) { if ($block[$ti] -eq '<') { $inTag = $true } elseif ($block[$ti] -eq '>') { $inTag = $false } elseif (-not $inTag) { $title += $block[$ti] }; $ti++ }
        $title = $title.Trim()
        while ($title.Contains("  ")) { $title = $title.Replace("  ", " ") }

        if ($title.Length -ge 3 -and $title.Length -le 300) {
            $snip = ""
            $absPos = $html.IndexOf('c-abstract', $h3e)
            if ($absPos -gt 0 -and $absPos -lt $h3e + 2000) {
                $absEnd = $html.IndexOf('</div>', $absPos)
                if ($absEnd -gt 0 -and $absEnd - $absPos -lt 1000) {
                    $raw = $html.Substring($absPos, $absEnd - $absPos)
                    $snip = ""; $si = 0; $inTag2 = $false
                    while ($si -lt $raw.Length) { if ($raw[$si] -eq '<') { $inTag2 = $true } elseif ($raw[$si] -eq '>') { $inTag2 = $false } elseif (-not $inTag2) { $snip += $raw[$si] }; $si++ }
                    $snip = $snip.Trim()
                    while ($snip.Contains("  ")) { $snip = $snip.Replace("  ", " ") }
                }
            }
            $res.Add((New-ResultObject -T $title -U $urlVal -Sn $snip -Sr "Baidu" -Q $q))
        }
        $pos = $h3e + 6
    }
    return $res.ToArray()
}

# ============ Bing搜索 ============
function Invoke-BingSearch {
    param([int]$M = 10)
    $q = $script:gQuery
    if ([string]::IsNullOrWhiteSpace($q)) { return @() }
    $e = [uri]::EscapeDataString($q)
    $url = "https://www.bing.com/search?q=$e&count=$M"
    $h = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"; "Accept-Language" = "zh-CN,zh;q=0.9,en;q=0.8" }
    try { $r = Invoke-WebRequest -Uri $url -Headers $h -TimeoutSec 20 -UseBasicParsing } catch { return @() }
    $html = [System.Web.HttpUtility]::HtmlDecode($r.Content)
    $res = New-Object System.Collections.Generic.List[object]

    $pos = 0
    while ($pos -lt $html.Length) {
        $liPos = $html.IndexOf('<li class="b_algo', $pos)
        if ($liPos -lt 0) { break }
        $h2Pos = $html.IndexOf('<h2', $liPos)
        if ($h2Pos -lt 0) { $pos = $liPos + 1; continue }
        $h2End = $html.IndexOf('</h2>', $h2Pos)
        if ($h2End -lt 0) { break }

        $hrefPos = $html.IndexOf('href="', $h2Pos, [Math]::Min(1000, $h2End - $h2Pos))
        if ($hrefPos -lt 0) { $pos = $h2Pos + 1; continue }
        $hrefStart = $hrefPos + 6; $hrefEnd = $html.IndexOf('"', $hrefStart)
        if ($hrefEnd -lt 0) { $pos = $h2Pos + 1; continue }
        $urlVal = $html.Substring($hrefStart, $hrefEnd - $hrefStart)

        $block = $html.Substring($h2Pos, $h2End - $h2Pos + 6)
        $title = ""; $inTag = $false
        for ($ti = 0; $ti -lt $block.Length; $ti++) { if ($block[$ti] -eq '<') { $inTag = $true } elseif ($block[$ti] -eq '>') { $inTag = $false } elseif (-not $inTag) { $title += $block[$ti] } }
        $title = $title.Trim()
        while ($title.Contains("  ")) { $title = $title.Replace("  ", " ") }

        if ($title.Length -ge 2 -and $title.Length -le 300) {
            $res.Add((New-ResultObject -T $title -U $urlVal -Sn "" -Sr "Bing" -Q $q))
        }
        $pos = $h2End + 6
    }
    return $res.ToArray()
}

# ============ 本地搜索 ============
function Search-LocalIndex {
    $Q = $script:gQuery; $Sf = $script:gSource; $Sm = $script:gSort
    if ($null -eq $Q) { $Q = "" }
    $s = Load-State; $t = Get-SearchTerms $Q; $items = @(); if ($s.Items) { $items = @($s.Items) }
    if ($Sf -and $Sf -ne "全部") {
        $items = @($items | Where-Object { $_.Source -eq $Sf })
    }
    if (-not [string]::IsNullOrWhiteSpace($Q) -and $t.Count -gt 0) {
        $matched = New-Object System.Collections.Generic.List[object]
        foreach ($item in $items) {
            $h = (Get-TextValue $item.Title) + " " + (Get-TextValue $item.Snippet) + " " + (Get-TextValue $item.Url) + " " + (Get-TextValue ($item.Tags -join " "))
            $hLow = $h.ToLowerInvariant()
            $allMatch = $true
            foreach ($term in $t) {
                if (-not $hLow.Contains($term)) { $allMatch = $false; break }
            }
            if ($allMatch) { $matched.Add($item) }
        }
        $items = @($matched.ToArray())
    }
    foreach ($i in $items) { $i | Add-Member -NotePropertyName SearchScore -NotePropertyValue (Score-Item -I $i -T $t) -Force }
    switch ($Sm) {
        "时间" { $items = @($items | Sort-Object @{E = { [datetime]$_.CachedAt }; Descending = $true }, @{E = "SearchScore"; Descending = $true }) }
        "标题" { $items = @($items | Sort-Object Title, @{E = "SearchScore"; Descending = $true }) }
        default { $items = @($items | Sort-Object @{E = "SearchScore"; Descending = $true }, @{E = { [datetime]$_.CachedAt }; Descending = $true }) }
    }
    return @($items)
}

# ============ 搜索入口 ============
function Search-Data {
    $q = $script:gQuery; $Sf = $script:gSource; $Sm = $script:gSort
    $c = Search-LocalIndex; $items = @($c)

    if (-not [string]::IsNullOrWhiteSpace($q)) {
        $onlineItems = New-Object System.Collections.Generic.List[object]
        if ($Sf -eq "全部" -or $Sf -eq "百度") {
            try { $o = Invoke-BaiduSearch; if ($o -and $o.Count -gt 0) { foreach ($i in $o) { $onlineItems.Add($i) } } } catch {}
        }
        if ($Sf -eq "全部" -or $Sf -eq "Bing") {
            try { $o = Invoke-BingSearch; if ($o -and $o.Count -gt 0) { foreach ($i in $o) { $onlineItems.Add($i) } } } catch {}
        }
        if ($onlineItems.Count -gt 0) {
            try { Update-Index -Items ($onlineItems.ToArray()) } catch {}
            $items = @(Search-LocalIndex)
        }
    }
    return [pscustomobject]@{ Items = $items; Status = "找到 $($items.Count) 条结果" }
}

# ============ 对话框 ============
function Show-PreferencesDialog {
    $state = Load-State
    $name = Get-ActiveProfileName
    $pd = Get-ProfileData -State $state -Name $name
    if ($null -eq $pd) { return }
    $prefs = $pd.Preferences
    if ($null -eq $prefs) {
        $prefs = [pscustomobject]@{ PerPage = 20; SortMode = "相关性"; SourceFilter = "全部"; AutoScanOnStartup = $false; OnlineSearchEnabled = $true }
        $pd.Preferences = $prefs
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "偏好设置 - $name"; $dlg.Size = New-Object System.Drawing.Size(380, 320)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $DarkBg; $dlg.ForeColor = $DarkText

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = "Fill"; $tbl.Padding = New-Object System.Windows.Forms.Padding(16)
    $tbl.RowCount = 6; $tbl.ColumnCount = 2
    for ($i = 0; $i -lt 6; $i++) { $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null }
    $tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 140)))
    $tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))

    $lbl1 = New-Object System.Windows.Forms.Label; $lbl1.Text = "每页结果"; $lbl1.AutoSize = $true; $lbl1.ForeColor = $DarkText; $lbl1.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $numPerPage = New-Object System.Windows.Forms.NumericUpDown; $numPerPage.Minimum = 5; $numPerPage.Maximum = 200; $numPerPage.Value = if ($null -ne $prefs.PerPage) { [int]$prefs.PerPage } else { 20 }
    $numPerPage.BackColor = $DarkInput; $numPerPage.ForeColor = $DarkText

    $lbl2 = New-Object System.Windows.Forms.Label; $lbl2.Text = "默认排序"; $lbl2.AutoSize = $true; $lbl2.ForeColor = $DarkText; $lbl2.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $cboSortPref = New-Object System.Windows.Forms.ComboBox; $cboSortPref.DropDownStyle = "DropDownList"
    $cboSortPref.Items.AddRange(@("相关性", "时间", "标题"))
    $cboSortPref.SelectedItem = if ($null -ne $prefs.SortMode) { $prefs.SortMode } else { "相关性" }
    $cboSortPref.BackColor = $DarkInput; $cboSortPref.ForeColor = $DarkText

    $lbl3 = New-Object System.Windows.Forms.Label; $lbl3.Text = "默认来源"; $lbl3.AutoSize = $true; $lbl3.ForeColor = $DarkText; $lbl3.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 4)
    $cboSrcPref = New-Object System.Windows.Forms.ComboBox; $cboSrcPref.DropDownStyle = "DropDownList"
    $cboSrcPref.Items.AddRange(@("全部", "百度", "Bing"))
    $cboSrcPref.SelectedItem = if ($null -ne $prefs.SourceFilter) { $prefs.SourceFilter } else { "全部" }
    $cboSrcPref.BackColor = $DarkInput; $cboSrcPref.ForeColor = $DarkText

    $chkAuto = New-Object System.Windows.Forms.CheckBox; $chkAuto.Text = "启动时自动扫描"
    $chkAuto.Checked = if ($null -ne $prefs.AutoScanOnStartup) { [bool]$prefs.AutoScanOnStartup } else { $false }
    $chkAuto.ForeColor = $DarkText
    $tbl.SetColumnSpan($chkAuto, 2)

    $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $btnPanel.AutoSize = $true; $btnPanel.FlowDirection = "RightToLeft"
    $tbl.SetColumnSpan($btnPanel, 2)

    $btnCancel = New-Object System.Windows.Forms.Button; $btnCancel.Text = "取消"
    $btnCancel.BackColor = $DarkInput; $btnCancel.ForeColor = $DarkText; $btnCancel.FlatStyle = "Flat"
    $btnCancel.Add_Click({ $dlg.Close() })
    $btnSave = New-Object System.Windows.Forms.Button; $btnSave.Text = "保存"
    $btnSave.BackColor = $AccentBlue; $btnSave.ForeColor = [System.Drawing.Color]::White; $btnSave.FlatStyle = "Flat"
    $btnSave.Add_Click({
        $prefs.PerPage = [int]$numPerPage.Value
        $prefs.SortMode = [string]$cboSortPref.SelectedItem
        $prefs.SourceFilter = [string]$cboSrcPref.SelectedItem
        $prefs.AutoScanOnStartup = $chkAuto.Checked
        $script:gPrefs = $prefs
        Save-State -State $state
        $stL.Text = "偏好设置已保存"
        $dlg.Close()
    })
    $btnPanel.Controls.AddRange(@($btnSave, $btnCancel))

    $tbl.Controls.Add($lbl1, 0, 0); $tbl.Controls.Add($numPerPage, 1, 0)
    $tbl.Controls.Add($lbl2, 0, 1); $tbl.Controls.Add($cboSortPref, 1, 1)
    $tbl.Controls.Add($lbl3, 0, 2); $tbl.Controls.Add($cboSrcPref, 1, 2)
    $tbl.Controls.Add($chkAuto, 0, 3)
    $tbl.Controls.Add($btnPanel, 0, 5)
    $dlg.Controls.Add($tbl)
    $dlg.ShowDialog($form)
}
function Show-ProfileManager {
    $state = Load-State
    $profiles = Get-ProfileList -State $state
    $active = Get-ActiveProfileName

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "配置管理"; $dlg.Size = New-Object System.Drawing.Size(400, 320)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $DarkBg; $dlg.ForeColor = $DarkText

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = "Fill"; $tbl.Padding = New-Object System.Windows.Forms.Padding(12)
    $tbl.RowCount = 4; $tbl.ColumnCount = 2; $tbl.RowStyles.Clear()
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

    $lb = New-Object System.Windows.Forms.ListBox; $lb.Dock = "Fill"; $lb.BackColor = $DarkInput; $lb.ForeColor = $DarkText
    $tbl.SetColumnSpan($lb, 2)
    $profileMap = @{}  # display text -> real profile name
    foreach ($pn in $profiles) {
        $display = if ($pn -eq $active) { "$pn [当前]" } else { $pn }
        $profileMap[$display] = $pn
        $lb.Items.Add($display) | Out-Null
    }
    if ($lb.Items.Count -gt 0) { $lb.SelectedIndex = 0 }

    $txtNewProfile = New-Object System.Windows.Forms.TextBox; $txtNewProfile.BackColor = $DarkInput; $txtNewProfile.ForeColor = $DarkText; $txtNewProfile.BorderStyle = "FixedSingle"
    $txtNewProfile.Text = "新配置名称"
    $txtNewProfile.Add_Enter({ if ($txtNewProfile.Text -eq "新配置名称") { $txtNewProfile.Text = "" } })

    $btnNew = New-Object System.Windows.Forms.Button; $btnNew.Text = "新建"; $btnNew.AutoSize = $true
    $btnNew.BackColor = $AccentGreen; $btnNew.ForeColor = [System.Drawing.Color]::White; $btnNew.FlatStyle = "Flat"
    $btnNew.Add_Click({
        $newName = $txtNewProfile.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($newName) -or $newName -eq "新配置名称") { return }
        $st = Load-State
        if ($null -ne $st.Profiles.$newName) { [System.Windows.Forms.MessageBox]::Show($dlg, "配置 '$newName' 已存在", "提示", "OK", "Warning") | Out-Null; return }
        $defPrefs = [pscustomobject]@{ PerPage = 20; SortMode = "相关性"; SourceFilter = "全部"; AutoScanOnStartup = $false; OnlineSearchEnabled = $true }
        $st.Profiles | Add-Member -NotePropertyName $newName -NotePropertyValue ([pscustomobject]@{ Preferences = $defPrefs; Favorites = @(); History = @() }) -Force
        Save-State -State $st
        $lb.Items.Add($newName)
        # 同步主窗体组合框
        $cboProfile.Items.Add($newName)
        $txtNewProfile.Text = "新配置名称"
        $stL.Text = "已创建配置：$newName"
    })

    $btnSwitch = New-Object System.Windows.Forms.Button; $btnSwitch.Text = "切换到此配置"; $btnSwitch.AutoSize = $true
    $btnSwitch.BackColor = $AccentBlue; $btnSwitch.ForeColor = [System.Drawing.Color]::White; $btnSwitch.FlatStyle = "Flat"
    $btnSwitch.Add_Click({
        if ($lb.SelectedIndex -lt 0) { return }
        $selName = $profileMap[[string]$lb.SelectedItem]
        if ([string]::IsNullOrWhiteSpace($selName) -or $selName -eq (Get-ActiveProfileName)) { $dlg.Close(); return }
        Set-ActiveProfile -Name $selName
        # 同步 cboProfile 选择
        $cboProfile.SelectedItem = $selName
        $stL.Text = "已切换到配置：$selName"
        $dlg.Close()
    })

    $btnDelete = New-Object System.Windows.Forms.Button; $btnDelete.Text = "删除"; $btnDelete.AutoSize = $true
    $btnDelete.BackColor = $DarkInput; $btnDelete.ForeColor = $DarkText; $btnDelete.FlatStyle = "Flat"
    $btnDelete.Add_Click({
        if ($lb.SelectedIndex -lt 0) { return }
        $selName = $profileMap[[string]$lb.SelectedItem]
        if ($selName -eq "Default") { [System.Windows.Forms.MessageBox]::Show($dlg, "不能删除默认配置", "提示", "OK", "Warning") | Out-Null; return }
        if ($selName -eq $active) { [System.Windows.Forms.MessageBox]::Show($dlg, "请先切换到其他配置再删除", "提示", "OK", "Warning") | Out-Null; return }
        $confirm = [System.Windows.Forms.MessageBox]::Show($dlg, "确定要删除配置 '$selName'？`n关联的收藏和历史将丢失。", "确认删除", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
        $st = Load-State
        $st.Profiles.PSObject.Properties.Remove($selName)
        Save-State -State $st
        $lb.Items.RemoveAt($lb.SelectedIndex)
        # 同步主窗体组合框
        $idx = $cboProfile.Items.IndexOf($selName)
        if ($idx -ge 0) { $cboProfile.Items.RemoveAt($idx) }
        $stL.Text = "已删除配置：$selName"
    })

    $btnClose = New-Object System.Windows.Forms.Button; $btnClose.Text = "关闭"; $btnClose.AutoSize = $true
    $btnClose.BackColor = $DarkInput; $btnClose.ForeColor = $DarkText; $btnClose.FlatStyle = "Flat"
    $btnClose.Add_Click({ $dlg.Close() })

    $tbl.Controls.Add($lb, 0, 0)
    $tbl.Controls.Add($txtNewProfile, 0, 1); $tbl.Controls.Add($btnNew, 1, 1)
    $tbl.Controls.Add($btnSwitch, 0, 2); $tbl.Controls.Add($btnDelete, 1, 2)
    $tbl.Controls.Add($btnClose, 0, 3)
    $dlg.Controls.Add($tbl)
    $dlg.ShowDialog($form)
}
function Show-HistoryDialog {
    $entries = Get-HistoryEntries
    if ($entries.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show($form, "暂无浏览历史", "历史记录", "OK", "Information") | Out-Null; return }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "历史记录"; $dlg.Size = New-Object System.Drawing.Size(550, 400)
    $dlg.StartPosition = "CenterParent"; $dlg.BackColor = $DarkBg; $dlg.ForeColor = $DarkText

    $tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = "Fill"; $tbl.RowCount = 2; $tbl.ColumnCount = 1
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
    $tbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
    $tbl.BackColor = $DarkBg

    $lv = New-Object System.Windows.Forms.ListView; $lv.Dock = "Fill"
    $lv.View = "Details"; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.BackColor = $DarkGrid; $lv.ForeColor = $DarkText
    $lv.Columns.Add("标题", 300); $lv.Columns.Add("时间", 160)
    $entries | ForEach-Object {
        $item = New-Object System.Windows.Forms.ListViewItem($_.Title)
        $item.SubItems.Add($_.VisitedAt)
        $item.Tag = $_
        $lv.Items.Add($item) | Out-Null
    }

    $btnPanel = New-Object System.Windows.Forms.FlowLayoutPanel; $btnPanel.AutoSize = $true; $btnPanel.FlowDirection = "RightToLeft"; $btnPanel.BackColor = $DarkBg

    $btnOpen = New-Object System.Windows.Forms.Button; $btnOpen.Text = "打开"; $btnOpen.BackColor = $AccentBlue; $btnOpen.ForeColor = [System.Drawing.Color]::White; $btnOpen.FlatStyle = "Flat"
    $btnOpen.Add_Click({
        if ($lv.SelectedItems.Count -gt 0 -and $null -ne $lv.SelectedItems[0].Tag) {
            $h = $lv.SelectedItems[0].Tag
            Start-Process $h.Url | Out-Null
        }
    })
    $btnClear = New-Object System.Windows.Forms.Button; $btnClear.Text = "清空历史"; $btnClear.BackColor = $DarkInput; $btnClear.ForeColor = $DarkText; $btnClear.FlatStyle = "Flat"
    $btnClear.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show($dlg, "确定要清空所有历史记录？", "确认", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
        $st = Load-State; $name = Get-ActiveProfileName; $pd = Get-ProfileData -State $st -Name $name
        if ($pd) { $pd.History = @() }; Save-State -State $st; $lv.Items.Clear(); $stL.Text = "历史已清空"
    })
    $btnCloseHist = New-Object System.Windows.Forms.Button; $btnCloseHist.Text = "关闭"; $btnCloseHist.BackColor = $DarkInput; $btnCloseHist.ForeColor = $DarkText; $btnCloseHist.FlatStyle = "Flat"
    $btnCloseHist.Add_Click({ $dlg.Close() })

    $btnPanel.Controls.AddRange(@($btnOpen, $btnClear, $btnCloseHist))
    $tbl.Controls.Add($lv, 0, 0); $tbl.Controls.Add($btnPanel, 0, 1)
    $dlg.Controls.Add($tbl)
    $dlg.ShowDialog($form)
}

# ============ UI事件 ============
function Open-ResultUrl { param([Parameter(Mandatory)]$I) if ($null -eq $I) { return }; $u = Get-TextValue $I.Url; if ([string]::IsNullOrWhiteSpace($u)) { return }; Start-Process $u | Out-Null; Add-HistoryEntry -Item $I }
function Copy-ResultUrl { param([Parameter(Mandatory)]$I) $u = Get-TextValue $I.Url; if ([string]::IsNullOrWhiteSpace($u)) { return }; [System.Windows.Forms.Clipboard]::SetText($u) }

Ensure-Storage; Initialize-UserModule

# ============ 图片获取（萌娘百科 API - 后台作业） ============
$imgCacheDir = Join-Path $AppDir 'imgcache'
$script:imgJob = $null
function Start-ImageFetchJob {
    param([string]$Title)
    # 重置轮询计数
    $script:pollTickCount = 0
    # 停掉之前的作业（任何未结束状态都要停）
    if ($script:imgJob) {
        $prevState = $script:imgJob.State
        if ($prevState -eq 'Running' -or $prevState -eq 'NotStarted' -or $prevState -eq 'Stopping') {
            try { $script:imgJob.StopJob() | Out-Null } catch { Write-DiagLog "ImgJob: 停旧作业失败: $_" }
        }
    }
    $script:imgJob = $null
    $jobTitles = @($Title)
    Write-DiagLog "ImgJob: 开始获取 $Title 的萌百图片"
    $script:imgJob = Start-Job -ScriptBlock {
        param($titles, $diagLogPath)
        $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
        $result = @()
        function Write-JobLog {
            param([string]$M)
            $ts = (Get-Date).ToString("HH:mm:ss.fff")
            try { [System.IO.File]::AppendAllText($diagLogPath, "$ts $M`r`n", [System.Text.UTF8Encoding]::new($false)) } catch {}
        }
        try {
            # 启用 TLS 1.2
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            foreach ($title in $titles) {
                $et = [uri]::EscapeDataString($title.Trim())
                Write-JobLog "ImgJob: opensearch '$title' -> $et"
                # opensearch 找精确标题
                try {
                    $os = Invoke-WebRequest -Uri "https://zh.moegirl.org.cn/api.php?action=opensearch&search=$et&limit=1&namespace=0&format=json" -TimeoutSec 10 -UseBasicParsing -Headers @{ "User-Agent" = $ua }
                    Write-JobLog "ImgJob: opensearch 状态=$($os.StatusCode) 长度=$($os.Content.Length)"
                } catch { Write-JobLog "ImgJob: opensearch 失败: $_"; continue }
                $osJ = $null
                try { $osJ = $os.Content | ConvertFrom-Json } catch { Write-JobLog "ImgJob: opensearch JSON 解析失败: $_"; continue }
                $realTitle = ""
                if ($osJ -and $osJ.Count -ge 2 -and $osJ[1]) { $arr = @($osJ[1]); if ($arr.Count -gt 0) { $realTitle = [string]$arr[0] } }
                if ([string]::IsNullOrWhiteSpace($realTitle)) { Write-JobLog "ImgJob: opensearch 未找到精确标题"; continue }
                Write-JobLog "ImgJob: opensearch 找到精确标题=$realTitle"
                $ret = [uri]::EscapeDataString($realTitle)
                # pageimages 拿缩略图
                try {
                    $pi = Invoke-WebRequest -Uri "https://zh.moegirl.org.cn/api.php?action=query&titles=$ret&prop=pageimages&pithumbsize=600&format=json" -TimeoutSec 10 -UseBasicParsing -Headers @{ "User-Agent" = $ua }
                    Write-JobLog "ImgJob: pageimages 状态=$($pi.StatusCode) 长度=$($pi.Content.Length)"
                } catch { Write-JobLog "ImgJob: pageimages 失败: $_"; continue }
                $piJ = $null
                try { $piJ = $pi.Content | ConvertFrom-Json } catch { Write-JobLog "ImgJob: pageimages JSON 解析失败: $_"; continue }
                if ($piJ.query -and $piJ.query.pages) {
                    $pageCount = 0
                    foreach ($pg in $piJ.query.pages.PSObject.Properties) {
                        $pageCount++
                        Write-JobLog "ImgJob: 页面 '$($pg.Value.title)' id=$($pg.Value.pageid)"
                        if ($pg.Value.thumbnail -and $pg.Value.thumbnail.source) {
                            $src = [string]$pg.Value.thumbnail.source
                            Write-JobLog "ImgJob: 找到缩略图 $src"
                            $result += $src
                        } else { Write-JobLog "ImgJob: 页面无 thumbnail 属性" }
                    }
                    Write-JobLog "ImgJob: 共 $pageCount 个页面"
                } else { Write-JobLog "ImgJob: query.pages 为空或不存在" }
                if ($result.Count -gt 0) { Write-JobLog "ImgJob: 已找到 $($result.Count) 个图片，停止"; break }
            }
        } catch { Write-JobLog "ImgJob: 未处理异常: $_" }
        Write-JobLog "ImgJob: 返回 $($result.Count) 个 URL"
        return $result
    } -ArgumentList $jobTitles, (Join-Path $AppDir 'diag.log')
}

# 图片加载轮询定时器（在 UI 初始化后创建）
$script:imgPollTimer = $null
function Get-CachedImage {
    param([string]$ImageUrl)
    if ([string]::IsNullOrWhiteSpace($ImageUrl)) { Write-DiagLog "GetImg: URL为空"; return $null }
    # 处理协议相对 URL ("//...")
    if ($ImageUrl -match '^//') { $ImageUrl = "https:$ImageUrl"; Write-DiagLog "GetImg: 协议相对URL -> $ImageUrl" }
    if (-not (Test-Path $imgCacheDir)) { New-Item -ItemType Directory -Path $imgCacheDir -Force | Out-Null }
    # 用 SHA256 保证跨会话缓存一致
    try {
        $shaBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ImageUrl.ToLowerInvariant()))
        $sb = New-Object System.Text.StringBuilder; foreach ($b in $shaBytes) { $sb.Append(('{0:x2}' -f $b)) | Out-Null }
        $hash = $sb.ToString().Substring(0, 16)
    } catch { $hash = [string]::Format("{0:X8}", $ImageUrl.GetHashCode()) }
    $ext = 'jpg'
    try { $ext = ([System.IO.Path]::GetExtension(($ImageUrl -split '\?')[0])).TrimStart('.'); if ([string]::IsNullOrWhiteSpace($ext)) { $ext = 'jpg' } } catch {}
    $cf = Join-Path $imgCacheDir "$hash.$ext"
    if (-not (Test-Path $cf)) {
        try {
            Write-DiagLog "GetImg: 下载 $ImageUrl -> $cf"
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
            $wc = New-Object System.Net.WebClient
            $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36')
            $wc.DownloadFile($ImageUrl, $cf)
            Write-DiagLog "GetImg: 下载完成 $( (Get-Item $cf).Length ) 字节"
        } catch { Write-DiagLog "GetImg: 下载失败: $_"; return $null }
    } else { Write-DiagLog "GetImg: 缓存命中 $cf" }
    return $cf
}

# ============ 萌娘百科建议 ============
$script:suggestTimer = $null
function Get-MoegirlSuggestions {
    param([string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    try {
        $e = [uri]::EscapeDataString($Query)
        $url = "https://zh.moegirl.org.cn/api.php?action=opensearch&search=$e&limit=10&namespace=0&format=json"
        $r = Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing -Headers @{ "User-Agent" = "Mozilla/5.0" }
        $json = $r.Content | ConvertFrom-Json
        if ($null -eq $json -or $json.Count -lt 2) { return @() }
        $titles = $json[1]
        $urls = if ($json.Count -ge 4) { $json[3] } else { @() }
        $result = New-Object System.Collections.Generic.List[object]
        for ($i = 0; $i -lt $titles.Count; $i++) {
            $title = $titles[$i]
            $link = if ($i -lt $urls.Count) { $urls[$i] } else { "https://zh.moegirl.org.cn/$([uri]::EscapeDataString($title))" }
            $result.Add([pscustomobject]@{ Title = $title; Url = $link })
        }
        return @($result.ToArray())
    } catch { return @() }
}

# ============ 暗色主题 ============
$DarkBg = [System.Drawing.Color]::FromArgb(26, 26, 30)
$DarkPanel = [System.Drawing.Color]::FromArgb(35, 35, 42)
$DarkInput = [System.Drawing.Color]::FromArgb(48, 48, 56)
$DarkGrid = [System.Drawing.Color]::FromArgb(32, 32, 38)
$DarkGridAlt = [System.Drawing.Color]::FromArgb(40, 40, 48)
$DarkSelected = [System.Drawing.Color]::FromArgb(60, 90, 170)
$DarkText = [System.Drawing.Color]::FromArgb(225, 225, 230)
$DimText = [System.Drawing.Color]::FromArgb(150, 150, 165)
$DarkBorder = [System.Drawing.Color]::FromArgb(60, 60, 72)
$AccentBlue = [System.Drawing.Color]::FromArgb(80, 130, 220)
$AccentGreen = [System.Drawing.Color]::FromArgb(70, 175, 100)
$AccentOrange = [System.Drawing.Color]::FromArgb(220, 160, 60)

# ============ 窗体 ============
$form = New-Object System.Windows.Forms.Form
$form.Text = "Gal Search MVP - 资源搜索"; $form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1440, 900); $form.MinimumSize = New-Object System.Drawing.Size(1100, 700)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.KeyPreview = $true
$form.BackColor = $DarkBg
$form.ForeColor = $DarkText

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"; $root.RowCount = 4; $root.ColumnCount = 2
$root.BackColor = $DarkBg
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 70))) | Out-Null
$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$form.Controls.Add($root)

# MenuStrip
$m = New-Object System.Windows.Forms.MenuStrip; $m.Dock = "Top"
$m.BackColor = $DarkPanel; $m.ForeColor = $DarkText

function Set-MenuColors {
    param($Item)
    $Item.ForeColor = $DarkText
    $Item.BackColor = $DarkPanel
    foreach ($child in $Item.DropDownItems) {
        $child.ForeColor = $DarkText
        $child.BackColor = $DarkPanel
    }
}

$fm = New-Object System.Windows.Forms.ToolStripMenuItem; $fm.Text = "文件(&F)"
$rm = New-Object System.Windows.Forms.ToolStripMenuItem; $rm.Text = "扫描本地游戏(&G)"; $rm.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::R; $rm.Add_Click({ $btnNavLocal.PerformClick() })
$ps = New-Object System.Windows.Forms.ToolStripMenuItem; $ps.Text = "偏好设置(&P)"; $ps.Add_Click({ Show-PreferencesDialog })
$cm = New-Object System.Windows.Forms.ToolStripMenuItem; $cm.Text = "配置管理(&M)"; $cm.Add_Click({ Show-ProfileManager })
$ex = New-Object System.Windows.Forms.ToolStripMenuItem; $ex.Text = "退出(&X)"; $ex.Add_Click({ $form.Close() })
$fm.DropDownItems.AddRange(@($rm, $ps, $cm, $ex)) | Out-Null; Set-MenuColors $fm

$em = New-Object System.Windows.Forms.ToolStripMenuItem; $em.Text = "编辑(&E)"
$sm = New-Object System.Windows.Forms.ToolStripMenuItem; $sm.Text = "搜索(&S)"; $sm.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::F; $sm.Add_Click({ $queryBox.Focus(); $queryBox.SelectAll() })
$cu = New-Object System.Windows.Forms.ToolStripMenuItem; $cu.Text = "复制 URL(&C)"; $cu.ShortcutKeys = [System.Windows.Forms.Keys]::Control -bor [System.Windows.Forms.Keys]::C
$cu.Add_Click({ if ($grid.SelectedRows.Count -gt 0) { Copy-ResultUrl -I $grid.SelectedRows[0].Tag } })
$em.DropDownItems.AddRange(@($sm, $cu)) | Out-Null; Set-MenuColors $em

$vm = New-Object System.Windows.Forms.ToolStripMenuItem; $vm.Text = "查看(&V)"
$srt = New-Object System.Windows.Forms.ToolStripMenuItem; $srt.Text = "排序(&S)"
$s1 = New-Object System.Windows.Forms.ToolStripMenuItem; $s1.Text = "相关性(&R)"; $s1.Checked = $true
$s1.Add_Click({ $script:cboSort.SelectedIndex = 0; $s1.Checked = $true; $s2.Checked = $false; $s3.Checked = $false })
$s2 = New-Object System.Windows.Forms.ToolStripMenuItem; $s2.Text = "时间(&T)"
$s2.Add_Click({ $script:cboSort.SelectedIndex = 1; $s1.Checked = $false; $s2.Checked = $true; $s3.Checked = $false })
$s3 = New-Object System.Windows.Forms.ToolStripMenuItem; $s3.Text = "标题(&T)"
$s3.Add_Click({ $script:cboSort.SelectedIndex = 2; $s1.Checked = $false; $s2.Checked = $false; $s3.Checked = $true })
$srt.DropDownItems.AddRange(@($s1, $s2, $s3)) | Out-Null; $vm.DropDownItems.Add($srt) | Out-Null; Set-MenuColors $vm

# 收藏菜单
$favMenu = New-Object System.Windows.Forms.ToolStripMenuItem; $favMenu.Text = "收藏(&F)"
$favList = New-Object System.Windows.Forms.ToolStripMenuItem; $favList.Text = "收藏夹(&L)"
$favList.Add_Click({ $btnShowFav.PerformClick() })
$favMenu.DropDownItems.Add($favList) | Out-Null; Set-MenuColors $favMenu

# 历史菜单
$histMenu = New-Object System.Windows.Forms.ToolStripMenuItem; $histMenu.Text = "历史(&H)"
$histShow = New-Object System.Windows.Forms.ToolStripMenuItem; $histShow.Text = "历史记录(&R)"
$histShow.Add_Click({ Show-HistoryDialog })
$histMenu.DropDownItems.Add($histShow) | Out-Null; Set-MenuColors $histMenu

$hm = New-Object System.Windows.Forms.ToolStripMenuItem; $hm.Text = "帮助(&H)"
$ab = New-Object System.Windows.Forms.ToolStripMenuItem; $ab.Text = "关于(&A)"
$ab.Add_Click({ [System.Windows.Forms.MessageBox]::Show($form, "Gal Search MVP v1.0`nGal 资源搜索工具。仅搜索和导航。", "关于", "OK", "Information") | Out-Null })
$hm.DropDownItems.Add($ab) | Out-Null; Set-MenuColors $hm
$m.Items.AddRange(@($fm, $em, $vm, $favMenu, $histMenu, $hm)) | Out-Null

# 工具栏
$tb = New-Object System.Windows.Forms.FlowLayoutPanel
$tb.Dock = "Top"; $tb.AutoSize = $true; $tb.WrapContents = $true
$tb.Padding = New-Object System.Windows.Forms.Padding(16, 14, 16, 10); $tb.FlowDirection = "LeftToRight"
$tb.BackColor = $DarkPanel

$queryLabel = New-Object System.Windows.Forms.Label; $queryLabel.Text = "关键词"; $queryLabel.AutoSize = $true; $queryLabel.Margin = New-Object System.Windows.Forms.Padding(0, 10, 4, 0)
$queryLabel.ForeColor = $DarkText; $queryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# 搜索框 + 萌百科建议下拉
$queryPanel = New-Object System.Windows.Forms.Panel; $queryPanel.Width = 480; $queryPanel.Height = 28
$queryBox = New-Object System.Windows.Forms.TextBox; $queryBox.Width = 478; $queryBox.Height = 28
$queryBox.BackColor = $DarkInput; $queryBox.ForeColor = $DarkText; $queryBox.BorderStyle = "FixedSingle"
$queryBox.Font = New-Object System.Drawing.Font("Segoe UI", 10); $queryBox.Location = New-Object System.Drawing.Point(0, 0)

$suggestList = New-Object System.Windows.Forms.ListBox; $suggestList.Width = 478; $suggestList.Height = 200
$suggestList.Top = 28; $suggestList.Left = 0; $suggestList.Visible = $false
$suggestList.BackColor = $DarkPanel; $suggestList.ForeColor = $DarkText; $suggestList.BorderStyle = "FixedSingle"
$suggestList.Font = New-Object System.Drawing.Font("Segoe UI", 10); $suggestList.ItemHeight = 22
$suggestList.Cursor = [System.Windows.Forms.Cursors]::Hand
$queryPanel.Controls.Add($queryBox); $queryPanel.Controls.Add($suggestList)

# 建议请求去抖动定时器 + 轮询定时器
$script:suggestJob = $null; $script:suggestQuery = ""
$suggestTimer = New-Object System.Windows.Forms.Timer; $suggestTimer.Interval = 300
$suggestTimer.Add_Tick({
    $suggestTimer.Stop()
    $qText = $queryBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($qText) -or $qText.Length -lt 1) { $suggestList.Visible = $false; return }
    $script:suggestQuery = $qText
    # 启动后台任务拉取建议
    $script:suggestJob = Start-Job -ScriptBlock {
        param($q)
        try {
            $e = [uri]::EscapeDataString($q)
            $url = "https://zh.moegirl.org.cn/api.php?action=opensearch&search=$e&limit=10&namespace=0&format=json"
            $r = Invoke-WebRequest -Uri $url -TimeoutSec 4 -UseBasicParsing -Headers @{ "User-Agent" = "Mozilla/5.0" }
            $json = $r.Content | ConvertFrom-Json
            if ($null -eq $json -or $json.Count -lt 2 -or $null -eq $json[1]) { return @() }
            $titles = @($json[1]); $out = @(); foreach ($t in $titles) { $out += $t }
            return $out
        } catch { return @() }
    } -ArgumentList $qText
})
$pollTimer = New-Object System.Windows.Forms.Timer; $pollTimer.Interval = 100
$pollTimer.Add_Tick({
    if ($null -eq $script:suggestJob -or $script:suggestJob.State -ne 'Completed') { return }
    $pollTimer.Stop()
    $titles = @()
    try { $titles = Receive-Job $script:suggestJob -ErrorAction SilentlyContinue } catch {}
    $script:suggestJob = $null
    $suggestList.Items.Clear()
    $qText = $queryBox.Text.Trim()
    if ($titles.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($qText) -and $qText -eq $script:suggestQuery) {
        $suggestList.BeginUpdate()
        foreach ($t in $titles) { $suggestList.Items.Add($t) | Out-Null }
        $suggestList.EndUpdate()
        $listH = [Math]::Min($titles.Count * $suggestList.ItemHeight + 4, 200)
        $suggestList.Height = $listH; $queryPanel.Height = 28 + $listH
        $suggestList.Visible = $true
    } else { $suggestList.Visible = $false; $queryPanel.Height = 28 }
})
# 点击建议项 -> 填入搜索 + 搜索
$suggestList.Add_SelectedIndexChanged({
    if ($suggestList.SelectedIndex -lt 0) { return }
    $sel = [string]$suggestList.SelectedItem
    if ([string]::IsNullOrWhiteSpace($sel)) { return }
    $suggestList.Visible = $false; $queryPanel.Height = 28
    $queryBox.Text = $sel; Run-Search
})
$queryBox.Add_TextChanged({ $suggestList.Visible = $false; $queryPanel.Height = 28; $suggestTimer.Stop(); $suggestTimer.Start() })
# 延迟隐藏建议列表（让点选有机会触发）
$hideTimer = New-Object System.Windows.Forms.Timer; $hideTimer.Interval = 300
$hideTimer.Add_Tick({ $hideTimer.Stop(); $suggestList.Visible = $false; $queryPanel.Height = 28 })
$queryBox.Add_Leave({ $hideTimer.Start() })

$btnS = New-Object System.Windows.Forms.Button; $btnS.Text = "搜索"; $btnS.AutoSize = $true; $btnS.Height = 30
$btnS.BackColor = $AccentBlue; $btnS.ForeColor = [System.Drawing.Color]::White; $btnS.FlatStyle = "Flat"; $btnS.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnS.FlatAppearance.BorderSize = 0
$btnC = New-Object System.Windows.Forms.Button; $btnC.Text = "清理缓存"; $btnC.AutoSize = $true; $btnC.Height = 30
$btnC.BackColor = $DarkInput; $btnC.ForeColor = $DarkText; $btnC.FlatStyle = "Flat"; $btnC.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$lblSrc = New-Object System.Windows.Forms.Label; $lblSrc.Text = "来源"; $lblSrc.AutoSize = $true; $lblSrc.Margin = New-Object System.Windows.Forms.Padding(14, 10, 4, 0)
$lblSrc.ForeColor = $DarkText; $lblSrc.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$cboSrc = New-Object System.Windows.Forms.ComboBox; $cboSrc.DropDownStyle = "DropDownList"; $cboSrc.Width = 120; $cboSrc.Height = 26
$cboSrc.Items.AddRange(@("全部", "百度", "Bing")); $cboSrc.SelectedIndex = 0
$cboSrc.BackColor = $DarkInput; $cboSrc.ForeColor = $DarkText; $cboSrc.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$lblSort = New-Object System.Windows.Forms.Label; $lblSort.Text = "排序"; $lblSort.AutoSize = $true; $lblSort.Margin = New-Object System.Windows.Forms.Padding(14, 10, 4, 0)
$lblSort.ForeColor = $DarkText; $lblSort.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$cboSort = New-Object System.Windows.Forms.ComboBox; $cboSort.DropDownStyle = "DropDownList"; $cboSort.Width = 120; $cboSort.Height = 26
$cboSort.Items.AddRange(@("相关性", "时间", "标题")); $cboSort.SelectedIndex = 0
$cboSort.BackColor = $DarkInput; $cboSort.ForeColor = $DarkText; $cboSort.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$chkOnline = New-Object System.Windows.Forms.CheckBox; $chkOnline.Text = "在线搜索"; $chkOnline.Checked = $true; $chkOnline.AutoSize = $true; $chkOnline.Margin = New-Object System.Windows.Forms.Padding(14, 10, 14, 0)
$chkOnline.ForeColor = $DarkText; $chkOnline.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# 收藏夹按钮
$btnShowFav = New-Object System.Windows.Forms.Button; $btnShowFav.Text = "收藏夹"; $btnShowFav.AutoSize = $true; $btnShowFav.Height = 30
$btnShowFav.BackColor = $DarkInput; $btnShowFav.ForeColor = $DarkText; $btnShowFav.FlatStyle = "Flat"; $btnShowFav.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnShowFav.Add_Click({
    if ($script:gViewMode -eq "favorites") {
        $script:gViewMode = "search"
        $btnShowFav.Text = "收藏夹"
        if ($script:gQuery) { Run-Search } else { Set-Results -Items @(); $stL.Text = "就绪" }
    } else {
        $script:gViewMode = "favorites"
        $btnShowFav.Text = "← 返回搜索"
        $favs = Get-Favorites
        if ($favs.Count -eq 0) {
            Set-Results -Items @(); $stL.Text = "收藏夹为空"
        } else {
            Set-Results -Items $favs; $stL.Text = "收藏夹：$($favs.Count) 项"
        }
    }
})
# 配置选择器
$cboProfile = New-Object System.Windows.Forms.ComboBox; $cboProfile.DropDownStyle = "DropDownList"; $cboProfile.Width = 140; $cboProfile.Height = 26
$cboProfile.BackColor = $DarkInput; $cboProfile.ForeColor = $DarkText; $cboProfile.Font = New-Object System.Drawing.Font("Segoe UI", 10)
# 初始化配置列表
$initState = Load-State
$profileNames = Get-ProfileList -State $initState
foreach ($pn in $profileNames) { $cboProfile.Items.Add($pn) }
$cboProfile.SelectedItem = Get-ActiveProfileName
$cboProfile.Add_SelectedIndexChanged({
    $sel = [string]$cboProfile.SelectedItem
    if (-not [string]::IsNullOrWhiteSpace($sel) -and $sel -ne (Get-ActiveProfileName)) {
        Set-ActiveProfile -Name $sel
        $stL.Text = "已切换配置：$sel"
        # 刷新 UI 偏好（未来可应用 PerPage 等）
    }
})
$btnProfileManage = New-Object System.Windows.Forms.Button; $btnProfileManage.Text = "…"; $btnProfileManage.AutoSize = $true
$btnProfileManage.BackColor = $DarkInput; $btnProfileManage.ForeColor = $DarkText; $btnProfileManage.FlatStyle = "Flat"
$btnProfileManage.Add_Click({ Show-ProfileManager })

$tb.Controls.AddRange(@($queryLabel, $queryPanel, $btnS, $btnC, $lblSrc, $cboSrc, $lblSort, $cboSort, $chkOnline, $btnShowFav, $cboProfile, $btnProfileManage))

# Split
$split = New-Object System.Windows.Forms.SplitContainer; $split.Dock = "Fill"; $split.Orientation = "Vertical"
$split.BackColor = $DarkBorder; $split.SplitterWidth = 3; $split.SplitterIncrement = 1

# Grid
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = "FullRowSelect"; $grid.MultiSelect = $false; $grid.AutoGenerateColumns = $false
$grid.RowHeadersVisible = $false; $grid.AutoSizeColumnsMode = "Fill"
$grid.BackgroundColor = $DarkBg; $grid.ForeColor = $DarkText
$grid.GridColor = $DarkBorder
$grid.BorderStyle = "None"
$grid.CellBorderStyle = "SingleHorizontal"
$grid.RowTemplate.Height = 38
$grid.ColumnHeadersHeightSizeMode = "DisableResizing"; $grid.ColumnHeadersHeight = 42
$grid.ColumnHeadersDefaultCellStyle.BackColor = $DarkPanel
$grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 210)
$grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$grid.ColumnHeadersDefaultCellStyle.Alignment = "MiddleCenter"
$grid.ColumnHeadersDefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(0, 0, 0, 4)
$grid.DefaultCellStyle.BackColor = $DarkGrid
$grid.DefaultCellStyle.ForeColor = $DarkText
$grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$grid.DefaultCellStyle.SelectionBackColor = $DarkSelected
$grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$grid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
$grid.EnableHeadersVisualStyles = $false
$grid.RowTemplate.DefaultCellStyle.BackColor = $DarkGrid
$grid.AlternatingRowsDefaultCellStyle.BackColor = $DarkGridAlt

$c1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c1.Name = "Title"; $c1.HeaderText = "标题"; $c1.FillWeight = 42; $grid.Columns.Add($c1) | Out-Null
$c2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c2.Name = "Source"; $c2.HeaderText = "来源"; $c2.FillWeight = 10; $grid.Columns.Add($c2) | Out-Null
$c3 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c3.Name = "CachedAt"; $c3.HeaderText = "缓存时间"; $c3.FillWeight = 16; $grid.Columns.Add($c3) | Out-Null
$c4 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $c4.Name = "Snippet"; $c4.HeaderText = "摘要"; $c4.FillWeight = 32; $grid.Columns.Add($c4) | Out-Null
# 标题列开启自动换行
$c1.DefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::True

$dp = New-Object System.Windows.Forms.Panel; $dp.Dock = "Fill"; $dp.Padding = New-Object System.Windows.Forms.Padding(16, 12, 16, 12)
$dp.BackColor = $DarkBg

$dl = New-Object System.Windows.Forms.TableLayoutPanel; $dl.Dock = "Fill"; $dl.RowCount = 11; $dl.ColumnCount = 1
$dl.BackColor = $DarkBg
$null = for ($i = 0; $i -lt 8; $i++) { $dl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null }
$dl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$dl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$dl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

$dt = New-Object System.Windows.Forms.Label; $dt.Text = "请选择一条结果"; $dt.AutoSize = $true
$dt.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$dt.ForeColor = $DarkText; $dt.MaximumSize = New-Object System.Drawing.Size(420, 0)

$ds = New-Object System.Windows.Forms.Label; $ds.AutoSize = $true; $ds.ForeColor = $DimText
$ds.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$duL = New-Object System.Windows.Forms.Label; $duL.Text = "链接"; $duL.AutoSize = $true; $duL.ForeColor = $DimText; $duL.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$du = New-Object System.Windows.Forms.LinkLabel; $du.AutoSize = $true; $du.Text = ""; $du.LinkColor = $AccentBlue; $du.ActiveLinkColor = [System.Drawing.Color]::LightBlue
$du.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$du.MaximumSize = New-Object System.Drawing.Size(420, 0)
$dc = New-Object System.Windows.Forms.Label; $dc.AutoSize = $true; $dc.ForeColor = $DimText; $dc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tl = New-Object System.Windows.Forms.Label; $tl.Text = "标签"; $tl.AutoSize = $true; $tl.ForeColor = $DimText; $tl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tep = New-Object System.Windows.Forms.FlowLayoutPanel; $tep.AutoSize = $true; $tep.WrapContents = $false; $tep.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 6)
$tep.BackColor = $DarkBg
$tbx = New-Object System.Windows.Forms.TextBox; $tbx.Width = 280; $tbx.Height = 26
$tbx.BackColor = $DarkInput; $tbx.ForeColor = $DarkText; $tbx.BorderStyle = "FixedSingle"
$tbx.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$tsb = New-Object System.Windows.Forms.Button; $tsb.Text = "保存标签"; $tsb.AutoSize = $true; $tsb.Height = 28; $tsb.Enabled = $false
$tsb.BackColor = $AccentGreen; $tsb.ForeColor = [System.Drawing.Color]::White; $tsb.FlatStyle = "Flat"; $tsb.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$tsb.FlatAppearance.BorderSize = 0
$tsb.Add_Click({
    if ($grid.SelectedRows.Count -gt 0 -and $null -ne $grid.SelectedRows[0].Tag) {
        $it = $grid.SelectedRows[0].Tag; $rw = $tbx.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($rw)) { $it.Tags = @() } else { $it.Tags = @($rw -split "\s*,\s*" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
        $st = Load-State; foreach ($ci in $st.Items) { if ($ci.Url -eq $it.Url) { $ci.Tags = $it.Tags; break } }; Save-State -State $st
        $tsb.Enabled = $false; $stL.Text = "标签已保存"
    }
})
$tbx.Add_TextChanged({ $tsb.Enabled = $true })
$tep.Controls.AddRange(@($tbx, $tsb)) | Out-Null
# 百科链接（居中，点击跳转）
$wikiLink = New-Object System.Windows.Forms.LinkLabel
$wikiLink.AutoSize = $true
$wikiLink.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$wikiLink.LinkColor = $AccentBlue
$wikiLink.ActiveLinkColor = [System.Drawing.Color]::LightBlue
$wikiLink.TextAlign = "MiddleCenter"
$wikiLink.Visible = $false
$wikiLink.Add_LinkClicked({ param($s, $e) if ($s.Tag) { Start-Process $s.Tag | Out-Null } })

# 百科链接行容器（居中撑满）
$wikiRow = New-Object System.Windows.Forms.Panel
$wikiRow.Dock = "Top"
$wikiRow.AutoSize = $true
$wikiRow.BackColor = $DarkBg
$wikiRow.Margin = New-Object System.Windows.Forms.Padding(0, 2, 0, 4)
$wikiRow.Visible = $false
$wikiRow.Controls.Add($wikiLink)
$wikiRow.Add_Resize({
    if ($wikiLink.Visible) {
        $wikiLink.Left = [Math]::Max(0, ($wikiRow.ClientSize.Width - $wikiLink.Width) / 2)
    }
})

# 图片展示区域（单张主图 + 左右切换）
$imagePanel = New-Object System.Windows.Forms.Panel
$imagePanel.Dock = "Fill"
$imagePanel.BackColor = $DarkInput
$imagePanel.BorderStyle = "FixedSingle"

$mainPic = New-Object System.Windows.Forms.PictureBox
$mainPic.SizeMode = "Zoom"
$mainPic.Dock = "Fill"
$mainPic.BackColor = $DarkInput
$mainPic.Cursor = [System.Windows.Forms.Cursors]::Hand
$imagePanel.Controls.Add($mainPic)

# 点击图片放大
$mainPic.Add_Click({
    if ($null -eq $mainPic.Image) { return }
    $zoomForm = New-Object System.Windows.Forms.Form
    $zoomForm.Text = "图片查看 - 点击关闭"
    $zoomForm.Size = New-Object System.Drawing.Size(900, 700)
    $zoomForm.StartPosition = "CenterScreen"
    $zoomForm.BackColor = $DarkBg
    $zoomForm.KeyPreview = $true
    $zoomForm.TopMost = $true

    $zoomPic = New-Object System.Windows.Forms.PictureBox
    $zoomPic.SizeMode = "Zoom"
    $zoomPic.Dock = "Fill"
    $zoomPic.BackColor = $DarkBg
    $zoomPic.Image = $mainPic.Image
    $zoomPic.Cursor = [System.Windows.Forms.Cursors]::Hand

    $zoomForm.Controls.Add($zoomPic)

    # 点击或按 Esc 关闭
    $zoomPic.Add_Click({ $zoomForm.Close() })
    $zoomForm.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq "Escape") { $zoomForm.Close() } })

    $zoomForm.ShowDialog($form)
})

# 左右切换箭头
$btnPrev = New-Object System.Windows.Forms.Label
$btnPrev.Text = "◀"
$btnPrev.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
$btnPrev.BackColor = [System.Drawing.Color]::FromArgb(80, 0, 0, 0)
$btnPrev.Font = New-Object System.Drawing.Font("Segoe UI", 20)
$btnPrev.TextAlign = "MiddleCenter"
$btnPrev.Size = New-Object System.Drawing.Size(40, 60)
$btnPrev.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnPrev.Visible = $false
$btnPrev.Add_Click({ Navigate-Image -Direction -1 })

$btnNext = New-Object System.Windows.Forms.Label
$btnNext.Text = "▶"
$btnNext.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 210)
$btnNext.BackColor = [System.Drawing.Color]::FromArgb(80, 0, 0, 0)
$btnNext.Font = New-Object System.Drawing.Font("Segoe UI", 20)
$btnNext.TextAlign = "MiddleCenter"
$btnNext.Size = New-Object System.Drawing.Size(40, 60)
$btnNext.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnNext.Visible = $false
$btnNext.Add_Click({ Navigate-Image -Direction 1 })

$imagePanel.Controls.Add($btnPrev)
$imagePanel.Controls.Add($btnNext)

# 定位箭头（随面板大小变化居中）
$null = $imagePanel.Add_Resize({
    $btnPrev.Location = New-Object System.Drawing.Point(8, [Math]::Max(0, ($imagePanel.ClientSize.Height - $btnPrev.Height) / 2))
    $btnNext.Location = New-Object System.Drawing.Point([Math]::Max(0, $imagePanel.ClientSize.Width - $btnNext.Width - 8), [Math]::Max(0, ($imagePanel.ClientSize.Height - $btnNext.Height) / 2))
})

# 图片计数器文字（第 X/N 张）
$imgCounterLabel = New-Object System.Windows.Forms.Label
$imgCounterLabel.AutoSize = $true
$imgCounterLabel.ForeColor = $DimText
$imgCounterLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$imgCounterLabel.Visible = $false

# 操作按钮行
$btnRow = New-Object System.Windows.Forms.FlowLayoutPanel; $btnRow.AutoSize = $true; $btnRow.WrapContents = $false; $btnRow.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 0)
$btnRow.BackColor = $DarkBg
$ob = New-Object System.Windows.Forms.Button; $ob.Text = "打开链接"; $ob.AutoSize = $true; $ob.Height = 32; $ob.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$ob.BackColor = $AccentBlue; $ob.ForeColor = [System.Drawing.Color]::White; $ob.FlatStyle = "Flat"; $ob.FlatAppearance.BorderSize = 0
$ob.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$cb = New-Object System.Windows.Forms.Button; $cb.Text = "复制 URL"; $cb.AutoSize = $true; $cb.Height = 32; $cb.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 0)
$cb.BackColor = $DarkInput; $cb.ForeColor = $DarkText; $cb.FlatStyle = "Flat"; $cb.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnFav = New-Object System.Windows.Forms.Button; $btnFav.Text = "☆ 收藏"; $btnFav.AutoSize = $true; $btnFav.Height = 32
$btnFav.BackColor = $DarkInput; $btnFav.ForeColor = [System.Drawing.Color]::FromArgb(230, 180, 60); $btnFav.FlatStyle = "Flat"; $btnFav.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$btnFav.FlatAppearance.BorderSize = 0
$btnFav.Add_Click({
    if ($grid.SelectedRows.Count -gt 0 -and $null -ne $grid.SelectedRows[0].Tag) {
        $it = $grid.SelectedRows[0].Tag
        $isFav = Toggle-Favorite -Item $it
        $btnFav.Text = if ($isFav) { "★ 已收藏" } else { "☆ 收藏" }
        $stL.Text = if ($isFav) { "已收藏：$($it.Title)" } else { "已取消收藏" }
    }
})
$btnRow.Controls.AddRange(@($ob, $cb, $btnFav))

$dl.Controls.Add($dt, 0, 0); $dl.Controls.Add($ds, 0, 1); $dl.Controls.Add($duL, 0, 2); $dl.Controls.Add($du, 0, 3); $dl.Controls.Add($dc, 0, 4); $dl.Controls.Add($tl, 0, 5); $dl.Controls.Add($tep, 0, 6); $dl.Controls.Add($wikiRow, 0, 7); $dl.Controls.Add($imagePanel, 0, 8); $dl.Controls.Add($imgCounterLabel, 0, 9); $dl.Controls.Add($btnRow, 0, 10)
$dp.Controls.Add($dl)

$split.Panel1.Controls.Add($grid); $split.Panel2.Controls.Add($dp)

# ============ 左侧导航栏（图标+文字，垂直居中） ============
$sidebarNav = New-Object System.Windows.Forms.Panel
$sidebarNav.Dock = "Left"
$sidebarNav.Width = 70
$sidebarNav.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32)

# 内部用 TableLayoutPanel 三行自然居中
$sidebarTbl = New-Object System.Windows.Forms.TableLayoutPanel
$sidebarTbl.Dock = "Fill"
$sidebarTbl.ColumnCount = 1; $sidebarTbl.RowCount = 3
$sidebarTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$sidebarTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$sidebarTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$sidebarTbl.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32)

# 按钮容器
$sidebarBtnPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$sidebarBtnPanel.AutoSize = $true
$sidebarBtnPanel.WrapContents = $false
$sidebarBtnPanel.FlowDirection = "TopDown"
$sidebarBtnPanel.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32)
$sidebarTbl.Controls.Add($sidebarBtnPanel, 0, 1)

function New-SidebarButton {
    param([string]$Icon, [string]$Label, [scriptblock]$Click)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Width = 64; $btn.Height = 58
    $btn.FlatStyle = "Flat"; $btn.FlatAppearance.BorderSize = 0
    $btn.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32)
    $btn.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 165)
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $btn.Text = "$Icon`n$Label"
    $btn.TextAlign = "MiddleCenter"
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btn.Tag = $false   # active flag
    $btn.Add_Click($Click)
    $btn.Add_MouseHover({ $this.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48) })
    $btn.Add_MouseLeave({ if (-not $this.Tag) { $this.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32) } })
    return $btn
}

$sidebarIndicator = New-Object System.Windows.Forms.Label
$sidebarIndicator.Width = 3; $sidebarIndicator.Height = 52
$sidebarIndicator.BackColor = $AccentBlue
$sidebarIndicator.Location = New-Object System.Drawing.Point(0, 10)

$btnNavSearch = New-SidebarButton -Icon "🔍" -Label "搜索" -Click {
    $sidebarIndicator.Top = $btnNavSearch.Top + 3
    $btnNavSearch.Tag = $true; $btnNavSearch.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48); $btnNavSearch.ForeColor = [System.Drawing.Color]::White
    $btnNavLocal.Tag = $false; $btnNavLocal.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32); $btnNavLocal.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 165)
    $tb.Visible = $true; $split.Visible = $true; $localPanel.Visible = $false
    $script:gViewMode = "search"
}
$btnNavSearch.Tag = $true; $btnNavSearch.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48); $btnNavSearch.ForeColor = [System.Drawing.Color]::White

$btnNavLocal = New-SidebarButton -Icon "🎮" -Label "本地" -Click {
    $sidebarIndicator.Top = $btnNavLocal.Top + 3
    $btnNavLocal.Tag = $true; $btnNavLocal.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 48); $btnNavLocal.ForeColor = [System.Drawing.Color]::White
    $btnNavSearch.Tag = $false; $btnNavSearch.BackColor = [System.Drawing.Color]::FromArgb(27, 27, 32); $btnNavSearch.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 165)
    $tb.Visible = $false; $split.Visible = $false; $localPanel.Visible = $true
    $script:gViewMode = "local"
}

$sidebarBtnPanel.Controls.AddRange(@($sidebarIndicator, $btnNavSearch, $btnNavLocal))
$sidebarNav.Controls.Add($sidebarTbl)

# ============ 本地游戏面板 ============
$localPanel = New-Object System.Windows.Forms.Panel
$localPanel.Dock = "Fill"
$localPanel.BackColor = $DarkBg
$localPanel.Visible = $false

$localTbl = New-Object System.Windows.Forms.TableLayoutPanel
$localTbl.Dock = "Fill"; $localTbl.RowCount = 3; $localTbl.ColumnCount = 1
$localTbl.BackColor = $DarkBg
$localTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$localTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$localTbl.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null

# 顶部工具栏
$localTopBar = New-Object System.Windows.Forms.FlowLayoutPanel
$localTopBar.Dock = "Top"; $localTopBar.AutoSize = $true
$localTopBar.BackColor = $DarkPanel; $localTopBar.Padding = New-Object System.Windows.Forms.Padding(12, 10, 12, 10)
$localTopBar.WrapContents = $true

$localTitleLbl = New-Object System.Windows.Forms.Label
$localTitleLbl.Text = "本地游戏"
$localTitleLbl.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$localTitleLbl.ForeColor = $DarkText; $localTitleLbl.AutoSize = $true
$localTitleLbl.Margin = New-Object System.Windows.Forms.Padding(0, 2, 16, 0)

$btnLocalScan = New-Object System.Windows.Forms.Button
$btnLocalScan.Text = "扫描本地游戏"
$btnLocalScan.AutoSize = $true; $btnLocalScan.Height = 32
$btnLocalScan.BackColor = $AccentGreen
$btnLocalScan.ForeColor = [System.Drawing.Color]::White; $btnLocalScan.FlatStyle = "Flat"
$btnLocalScan.FlatAppearance.BorderSize = 0
$btnLocalScan.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$lblLocalSearch = New-Object System.Windows.Forms.Label
$lblLocalSearch.Text = " 筛选"; $lblLocalSearch.AutoSize = $true
$lblLocalSearch.ForeColor = $DimText; $lblLocalSearch.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$lblLocalSearch.Margin = New-Object System.Windows.Forms.Padding(12, 6, 2, 0)

$txtLocalFilter = New-Object System.Windows.Forms.TextBox
$txtLocalFilter.Width = 200; $txtLocalFilter.Height = 28
$txtLocalFilter.BackColor = $DarkInput; $txtLocalFilter.ForeColor = $DarkText; $txtLocalFilter.BorderStyle = "FixedSingle"
$txtLocalFilter.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$localTopBar.Controls.AddRange(@($localTitleLbl, $btnLocalScan, $lblLocalSearch, $txtLocalFilter))

# 本地游戏搜索过滤
$txtLocalFilter.Add_TextChanged({
    $kw = $txtLocalFilter.Text.Trim().ToLowerInvariant()
    $allLocalItems = $localGrid.Tag
    if ($null -eq $allLocalItems) { $localGrid.Rows.Clear(); return }
    $filtered = if ([string]::IsNullOrWhiteSpace($kw)) { $allLocalItems } else { @($allLocalItems | Where-Object { $_.Title.ToLowerInvariant().Contains($kw) -or $_.Snippet.ToLowerInvariant().Contains($kw) }) }
    Update-LocalGrid -Items $filtered
})

# 本地游戏网格 — 带图标显示的列
$localGrid = New-Object System.Windows.Forms.DataGridView
$localGrid.Dock = "Fill"; $localGrid.ReadOnly = $true; $localGrid.AllowUserToAddRows = $false; $localGrid.AllowUserToDeleteRows = $false
$localGrid.SelectionMode = "FullRowSelect"; $localGrid.MultiSelect = $false; $localGrid.AutoGenerateColumns = $false
$localGrid.RowHeadersVisible = $false; $localGrid.AutoSizeColumnsMode = "Fill"
$localGrid.BackgroundColor = $DarkBg; $localGrid.ForeColor = $DarkText
$localGrid.GridColor = $DarkBorder; $localGrid.BorderStyle = "None"
$localGrid.CellBorderStyle = "SingleHorizontal"
$localGrid.RowTemplate.Height = 38
$localGrid.ColumnHeadersHeightSizeMode = "DisableResizing"; $localGrid.ColumnHeadersHeight = 42
$localGrid.ColumnHeadersDefaultCellStyle.BackColor = $DarkPanel
$localGrid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(180, 190, 210)
$localGrid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$localGrid.ColumnHeadersDefaultCellStyle.Alignment = "MiddleCenter"
$localGrid.DefaultCellStyle.BackColor = $DarkGrid
$localGrid.DefaultCellStyle.ForeColor = $DarkText
$localGrid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$localGrid.DefaultCellStyle.SelectionBackColor = $DarkSelected
$localGrid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
$localGrid.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 0)
$localGrid.EnableHeadersVisualStyles = $false
$localGrid.AlternatingRowsDefaultCellStyle.BackColor = $DarkGridAlt
$localGrid.RowTemplate.Height = 36

# 图标列（16x16 图标）
$localIconCol = New-Object System.Windows.Forms.DataGridViewImageColumn
$localIconCol.Name = "Icon"; $localIconCol.HeaderText = ""; $localIconCol.Width = 36; $localIconCol.MinimumWidth = 36
$localIconCol.FillWeight = 1; $localIconCol.Resizable = "False"
$localIconCol.ImageLayout = "Zoom"
$localIconCol.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 2, 0)
$localIconCol.DefaultCellStyle.NullValue = $null
$localGrid.Columns.Add($localIconCol) | Out-Null

$localCol1 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $localCol1.Name = "Title"; $localCol1.HeaderText = "名称"; $localCol1.FillWeight = 35; $localCol1.MinimumWidth = 100; $localGrid.Columns.Add($localCol1) | Out-Null
$localCol2 = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $localCol2.Name = "Path"; $localCol2.HeaderText = "路径"; $localCol2.FillWeight = 65; $localGrid.Columns.Add($localCol2) | Out-Null

# 判断 exe 文件名是否为非游戏程序
function Get-NonGameExe {
    param([string]$Name)
    $skip = @('uninstall', 'setup', 'install', 'vcredist', 'dxsetup', 'dotnet', 'UnityCrashHandler', 'UEPrereqSetup', 'NDP')
    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name).ToLowerInvariant()
    foreach ($s in $skip) { if ($base -eq $s.ToLowerInvariant() -or $base.StartsWith($s.ToLowerInvariant())) { return $true } }
    return $false
}

function Add-LocalGridRow {
    param($Item)
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($Item.Url)
        $iconImg = $icon.ToBitmap()
    } catch { $iconImg = $null }
    $r = $localGrid.Rows[$localGrid.Rows.Add()]; $r.Tag = $Item
    $r.Cells["Icon"].Value = $iconImg
    $r.Cells["Title"].Value = $Item.Title; $r.Cells["Path"].Value = $Item.Snippet
}

function Update-LocalGrid {
    param([object[]]$Items)
    $localGrid.Rows.Clear()
    foreach ($item in $Items) { Add-LocalGridRow -Item $item }
}

$stLocal = New-Object System.Windows.Forms.Label
$stLocal.Dock = "Bottom"; $stLocal.AutoSize = $true
$stLocal.ForeColor = $DimText; $stLocal.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$stLocal.Text = "点击上方按钮扫描本地游戏"
$stLocal.Padding = New-Object System.Windows.Forms.Padding(12, 6, 0, 6)

$localTbl.Controls.Add($localTopBar, 0, 0)
$localTbl.Controls.Add($localGrid, 0, 1)
$localTbl.Controls.Add($stLocal, 0, 2)
$localPanel.Controls.Add($localTbl)

# ============ 主内容容器（侧边栏 + 页面） ============
$mainContent = New-Object System.Windows.Forms.Panel
$mainContent.Dock = "Fill"
$mainContent.Controls.Add($localPanel)
$mainContent.Controls.Add($split)

# ============ 本地游戏扫描逻辑 ============
$localScanRunning = $false
$btnLocalScan.Add_Click({
    if ($localScanRunning) { return }
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "选择游戏安装目录（将扫描该文件夹下所有含 exe 的子文件夹）"
    $fbd.ShowNewFolderButton = $false
    if ($fbd.ShowDialog() -ne "OK") { return }
    $scanRoot = $fbd.SelectedPath
    $localScanRunning = $true; $btnLocalScan.Enabled = $false; $stLocal.Text = "扫描中..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
    try {
        $items = New-Object System.Collections.Generic.List[object]
        # 递归获取所有 exe 文件（不限层级），全部列出（只过滤明显非游戏的安装卸载程序）
        try {
            $allExes = @(Get-ChildItem -Path $scanRoot -Filter '*.exe' -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and -not (Get-NonGameExe $_.Name) })
            foreach ($exe in $allExes) {
                $items.Add((New-ResultObject -T $exe.Name -U $exe.FullName -Sn $exe.Directory.FullName -Sr "本地" -Q "本地"))
            }
        } catch { Write-DiagLog "本地扫描递归: $_" }
        $arr = $items.ToArray()
        # 存到缓存
        $state = Load-State
        $existingNonLocal = @($state.Items | Where-Object { $_.Source -ne "本地" })
        $state.Items = $existingNonLocal + @($arr)
        Save-State -State $state
        # 保存原始数据到 Tag 供筛选使用
        $localGrid.Tag = $arr
        # 显示到本地网格
        Update-LocalGrid -Items $arr
        $stLocal.Text = "找到 $($arr.Count) 个本地游戏"
    } catch { $stLocal.Text = "扫描失败：" + $_.Exception.Message; [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.ToString(), "扫描错误", "OK", "Error") | Out-Null } finally { $localScanRunning = $false; $btnLocalScan.Enabled = $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})
# 本地游戏双击打开
$localGrid.Add_CellDoubleClick({
    if ($localGrid.SelectedRows.Count -gt 0 -and $null -ne $localGrid.SelectedRows[0].Tag) {
        $localItem = $localGrid.SelectedRows[0].Tag
        $u = Get-TextValue $localItem.Url
        if (-not [string]::IsNullOrWhiteSpace($u)) { Start-Process $u | Out-Null }
    }
})

# 本地游戏右键菜单 — 在文件资源管理器中打开
$localCtxMenu = New-Object System.Windows.Forms.ContextMenuStrip
$localCtxMenu.BackColor = $DarkPanel; $localCtxMenu.ForeColor = $DarkText
$localCtxMenu.ShowImageMargin = $false

$miOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem
$miOpenFolder.Text = "在文件资源管理器中打开"
$miOpenFolder.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$miOpenFolder.ForeColor = $DarkText
$miOpenFolder.Add_Click({
    if ($localGrid.SelectedRows.Count -gt 0 -and $null -ne $localGrid.SelectedRows[0].Tag) {
        $localItem = $localGrid.SelectedRows[0].Tag
        $u = Get-TextValue $localItem.Url
        if (-not [string]::IsNullOrWhiteSpace($u) -and (Test-Path $u -PathType Leaf)) {
            $folderPath = Split-Path $u -Parent
            if (Test-Path $folderPath) { Start-Process "explorer.exe" -ArgumentList "/select,`"$u`"" }
        }
    }
})
$localCtxMenu.Items.Add($miOpenFolder) | Out-Null

$localGrid.ContextMenuStrip = $localCtxMenu

# 右键选中所在行
$localGrid.Add_CellMouseDown({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $localGrid.ClearSelection()
        $localGrid.Rows[$e.RowIndex].Selected = $true
        $localGrid.CurrentCell = $localGrid.Rows[$e.RowIndex].Cells[0]
    }
})

$status = New-Object System.Windows.Forms.StatusStrip
$status.BackColor = $DarkPanel; $status.ForeColor = $DarkText; $status.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$status.SizingGrip = $false
$stL = New-Object System.Windows.Forms.ToolStripStatusLabel; $stL.Text = "就绪 — 输入关键词后按 Enter 搜索"
$stL.ForeColor = $DarkText; $stL.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$status.Items.Add($stL) | Out-Null

$root.Controls.Add($sidebarNav, 0, 0); $root.SetRowSpan($sidebarNav, 4)
$root.Controls.Add($m, 1, 0); $root.Controls.Add($tb, 1, 1); $root.Controls.Add($mainContent, 1, 2); $root.Controls.Add($status, 1, 3)

function Navigate-Image {
    param([int]$Direction)
    if ($script:imgCachePaths.Count -eq 0) { return }
    $newIdx = $script:imgCurrentIndex + $Direction
    if ($newIdx -lt 0 -or $newIdx -ge $script:imgCachePaths.Count) { return }
    $script:imgCurrentIndex = $newIdx
    $path = $script:imgCachePaths[$script:imgCurrentIndex]
    try {
        # 释放旧图片防止 GDI+ 泄漏
        try { if ($mainPic.Image) { $mainPic.Image.Dispose() } } catch {}
        $mainPic.Image = [System.Drawing.Image]::FromFile($path)
        $imgCounterLabel.Text = "第 $($script:imgCurrentIndex + 1)/$($script:imgCachePaths.Count) 张"
    } catch { Write-DiagLog "NavImg: 加载失败 $path : $_" }
    $btnPrev.Visible = $script:imgCurrentIndex -gt 0
    $btnNext.Visible = $script:imgCurrentIndex -lt $script:imgCachePaths.Count - 1
}

$script:currentResults = @()

function Update-Details {
    param($I)
    if ($null -eq $I) {
        # 清空图片和百科链接
        try { if ($mainPic.Image) { $mainPic.Image.Dispose() } } catch {}
        $script:imgCachePaths = @(); $script:imgCurrentIndex = 0; $script:imgLoadedForTitle = ""
        $mainPic.Image = $null; $wikiRow.Visible = $false; $btnPrev.Visible = $false; $btnNext.Visible = $false; $imgCounterLabel.Visible = $false
        $dt.Text = "未选择结果"; $ds.Text = ""; $du.Text = ""; $du.Tag = $null; $dc.Text = ""
        $tbx.Text = ""; $tbx.ReadOnly = $true; $tsb.Enabled = $false; $btnFav.Enabled = $false; return
    }
    # 文字详情总是更新
    $dt.Text = Get-TextValue $I.Title; $ds.Text = "来源：" + (Get-TextValue $I.Source)
    $du.Text = Get-TextValue $I.Url; $du.Tag = $I; $dc.Text = "缓存：" + (Get-TextValue $I.CachedAt)
    if ($I.Tags -and $I.Tags.Count -gt 0) { $tbx.Text = $I.Tags -join "，" } else { $tbx.Text = "" }
    $tbx.ReadOnly = $false; $tsb.Enabled = $false
    # 更新收藏按钮状态
    $isFav = if ($null -ne $I.IsFavorite) { $I.IsFavorite } else { $false }
    $btnFav.Text = if ($isFav) { "★ 已收藏" } else { "☆ 收藏" }
    $btnFav.Enabled = $true
    # 设置百科链接（用选中项的标题）
    # 设置百科链接（用搜索关键词）
    $wikiKeyword = $script:gQuery
    if ([string]::IsNullOrWhiteSpace($wikiKeyword)) { $wikiKeyword = Get-TextValue $I.Title }
    if (-not [string]::IsNullOrWhiteSpace($wikiKeyword)) {
        $wikiUrl = "https://zh.moegirl.org.cn/$([uri]::EscapeDataString($wikiKeyword))"
        $wikiLink.Text = "萌娘百科：$wikiKeyword"
        $wikiLink.Tag = $wikiUrl
        $wikiLink.AutoSize = $true
        $wikiLink.Visible = $true
        $wikiRow.Visible = $true
        $wikiLink.Left = [Math]::Max(0, ($wikiRow.ClientSize.Width - $wikiLink.Width) / 2)
    }
    # 图片用搜索框关键词加载（切结果不重新加载）
    $imgTitle = $script:gQuery
    if ([string]::IsNullOrWhiteSpace($imgTitle)) { $imgTitle = Get-TextValue $I.Title }
    if ($script:imgLoadedForTitle -ne $imgTitle -and $script:imgCachePaths.Count -eq 0) {
        Write-DiagLog "UpdateDetails: 开始查找萌百图片 '$imgTitle'"
        $script:imgLoadingTitle = $imgTitle
        $stL.Text = "查找萌百图片..."; [System.Windows.Forms.Application]::DoEvents()
        Start-ImageFetchJob -Title $imgTitle
        Write-DiagLog "UpdateDetails: imgJob=$($script:imgJob.Id) 已启动"
        $script:imgPollTimer.Start()
    }
}

function Set-Results {
    param([object[]]$Items)
    if ($null -eq $Items) { $Items = @() }; $script:currentResults = $Items; $grid.Rows.Clear()
    if ($Items.Count -eq 0) { $r = $grid.Rows[$grid.Rows.Add()]; $r.Cells["Title"].Value = "输入关键词后按 Enter 搜索，支持百度 / Bing 在线搜索"; $r.DefaultCellStyle.ForeColor = $DimText; $r.DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Italic); return }
    foreach ($item in $script:currentResults) { $r = $grid.Rows[$grid.Rows.Add()]; $r.Tag = $item; $r.Cells["Title"].Value = $item.Title; $r.Cells["Source"].Value = $item.Source; $r.Cells["CachedAt"].Value = $item.CachedAt; $r.Cells["Snippet"].Value = $item.Snippet }
    if ($grid.Rows.Count -gt 0) { $grid.ClearSelection(); $grid.Rows[0].Selected = $true; $grid.CurrentCell = $grid.Rows[0].Cells["Title"]; Update-Details -I $grid.Rows[0].Tag } else { Update-Details -I $null }
}

function Run-Search {
    # 隐藏建议下拉
    $suggestList.Visible = $false; $queryPanel.Height = 28
    $qNow = $queryBox.Text
    $script:gSource = [string]$cboSrc.SelectedItem
    $script:gSort = [string]$cboSort.SelectedItem
    $on = $chkOnline.Checked

    # 同词搜索累计+10，换词重置为50
    if ($qNow -eq $script:lastQuery -and -not [string]::IsNullOrWhiteSpace($qNow)) {
        $script:queryLimit += 10
    } else {
        $script:queryLimit = 50
    }
    $script:lastQuery = $qNow
    $script:gQuery = $qNow

    $btnS.Enabled = $false; $stL.Text = "搜索中..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:gQuery)) {
            $res = Search-Data
            $total = @($res.Items).Count

            if ($total -gt $script:queryLimit) {
                $res.Items = @($res.Items[0..($script:queryLimit - 1)])
                $stL.Text = "显示 $($script:queryLimit)/$total 条(再次搜索+10)"
            } else {
                $stL.Text = "找到 $total 条结果"
            }
            Set-Results -Items $res.Items
        } else {
            $stL.Text = "请输入关键词"
        }
    } catch { $stL.Text = "失败：" + $_.Exception.Message; [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "错误", "OK", "Error") | Out-Null } finally { $btnS.Enabled = $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Run-ScanLocalGames {
    # 弹出文件夹选择对话框
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = "选择游戏安装目录（将扫描该文件夹下所有含 exe 的子文件夹）"
    $fbd.ShowNewFolderButton = $false

    if ($fbd.ShowDialog() -ne "OK") { $stL.Text = "已取消"; return }

    $scanRoot = $fbd.SelectedPath
    $btnS.Enabled = $false; $stL.Text = "扫描中..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
    try {
        $localItems = New-Object System.Collections.Generic.List[object]

        # 扫描所选文件夹的一级子目录
        $dirs = Get-ChildItem -Path $scanRoot -Directory -ErrorAction SilentlyContinue
        foreach ($d in $dirs) {
            $exes = @($d.GetFiles("*.exe"))
            if ($exes.Count -gt 0) {
                $mainExe = $exes | Sort-Object Length -Descending | Select-Object -First 1
                $localItems.Add((New-ResultObject -T $d.Name -U $mainExe.FullName -Sn $d.FullName -Sr "本地" -Q "本地"))
            }
        }

        $items = $localItems.ToArray()
        # 存到缓存
        $state = Load-State
        $existingNonLocal = @($state.Items | Where-Object { $_.Source -ne "本地" })
        $state.Items = $existingNonLocal + @($items)
        Save-State -State $state

        Set-DefaultLimit; $script:lastQuery = "本地"
        $grid.Rows.Clear()
        $limit = [Math]::Min($items.Count, 50)
        for ($i = 0; $i -lt $limit; $i++) {
            $r = $grid.Rows[$grid.Rows.Add()]; $r.Tag = $items[$i]
            $r.Cells["Title"].Value = $items[$i].Title; $r.Cells["Source"].Value = $items[$i].Source; $r.Cells["CachedAt"].Value = ""; $r.Cells["Snippet"].Value = $items[$i].Snippet
        }
        if ($grid.Rows.Count -gt 0) { $grid.ClearSelection(); $grid.Rows[0].Selected = $true; $grid.CurrentCell = $grid.Rows[0].Cells["Title"]; Update-Details -I $grid.Rows[0].Tag } else { Update-Details -I $null }
        $stL.Text = "找到 $($items.Count) 个本地游戏(显示 $limit 个，再次点击+10)"
    } catch { $stL.Text = "失败：" + $_.Exception.Message; [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.ToString(), "扫描错误", "OK", "Error") | Out-Null } finally { $btnS.Enabled = $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Run-ClearCache {
    $r = [System.Windows.Forms.MessageBox]::Show($form, "确定要清空所有搜索结果缓存？`n收藏夹和用户配置将保留。", "清理缓存", "YesNo", "Warning")
    if ($r -ne "Yes") { return }
    $btnC.Enabled = $false; $stL.Text = "清理中..."; $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; [System.Windows.Forms.Application]::DoEvents()
    try {
        # 保护 Profiles 和 ActiveProfile
        $oldState = Load-State
        $seed = [ordered]@{
            Version = 2
            Items = @()
            Profiles = $oldState.Profiles
            ActiveProfile = $oldState.ActiveProfile
        }
        $seed | ConvertTo-Json -Depth 16 | Set-Content -Path $DataFile -Encoding UTF8
        # 清理图片缓存
        if (Test-Path $imgCacheDir) { Remove-Item "$imgCacheDir\*" -Force -ErrorAction SilentlyContinue }
        try { if ($mainPic.Image) { $mainPic.Image.Dispose() } } catch {}
        $mainPic.Image = $null; $script:imgCachePaths = @(); $script:imgCurrentIndex = 0; $script:imgLoadedForTitle = ""; $btnPrev.Visible = $false; $btnNext.Visible = $false; $imgCounterLabel.Visible = $false
        Set-DefaultLimit; $script:lastQuery = ""
        $grid.Rows.Clear(); Update-Details -I $null; $stL.Text = "缓存已清空（配置和收藏已保留）"
    } catch { $stL.Text = "失败：" + $_.Exception.Message } finally { $btnC.Enabled = $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

$btnS.Add_Click({ Run-Search }); $btnC.Add_Click({ Run-ClearCache })
$queryBox.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $e.SuppressKeyPress = $true
        if ($suggestList.Visible -and $suggestList.SelectedIndex -ge 0) {
            $sel = [string]$suggestList.SelectedItem
            $suggestList.Visible = $false; $queryPanel.Height = 28
            $queryBox.Text = $sel; Run-Search; return
        }
        $suggestList.Visible = $false; $queryPanel.Height = 28; Run-Search
        return
    }
    if ($suggestList.Visible) {
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Down) {
            $e.SuppressKeyPress = $true
            if ($suggestList.SelectedIndex -lt $suggestList.Items.Count - 1) { $suggestList.SelectedIndex++ }
            return
        }
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Up) {
            $e.SuppressKeyPress = $true
            if ($suggestList.SelectedIndex -gt 0) { $suggestList.SelectedIndex-- }
            return
        }
    }
})
$grid.Add_SelectionChanged({ if ($grid.SelectedRows.Count -gt 0) { Update-Details -I $grid.SelectedRows[0].Tag } })
$grid.Add_CellDoubleClick({ if ($grid.SelectedRows.Count -gt 0) { Open-ResultUrl -I $grid.SelectedRows[0].Tag } })
$du.Add_LinkClicked({ param($s, $e) if ($null -ne $s.Tag) { Open-ResultUrl -I $s.Tag } })
$ob.Add_Click({ if ($grid.SelectedRows.Count -gt 0) { Open-ResultUrl -I $grid.SelectedRows[0].Tag } })
$cb.Add_Click({ if ($grid.SelectedRows.Count -gt 0) { Copy-ResultUrl -I $grid.SelectedRows[0].Tag } })

$form.Add_KeyDown({
    param($s, $e)
    if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::R) { $e.SuppressKeyPress = $true; $btnNavLocal.PerformClick(); return }
    if ($e.Control -and ($e.KeyCode -eq [System.Windows.Forms.Keys]::F -or $e.KeyCode -eq [System.Windows.Forms.Keys]::L)) { $e.SuppressKeyPress = $true; $queryBox.Focus(); $queryBox.SelectAll(); return }
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; if ($suggestList.Visible) { $suggestList.Visible = $false; $queryPanel.Height = 28 } elseif (-not [string]::IsNullOrWhiteSpace($queryBox.Text)) { $queryBox.Text = "" } elseif ($grid.SelectedRows.Count -gt 0) { $grid.ClearSelection(); Update-Details -I $null } }
})

$form.Add_Shown({ $split.Panel1MinSize = 580; $split.Panel2MinSize = 320; $split.SplitterDistance = 860; $queryBox.Focus(); Set-Results -Items @() })

# 图片加载轮询定时器
$script:imgPollTimer = New-Object System.Windows.Forms.Timer
$script:imgPollTimer.Interval = 500
$script:imgPollTimer.Add_Tick({
    $script:pollTickCount += 1
    # 超时保护：100 次轮询（500ms*100=50秒）后放弃 — 后台作业要连续调两次API
    if ($script:pollTickCount -ge 100) {
        $script:imgPollTimer.Stop()
        Write-DiagLog "ImgTimer: 轮询超时(100次)，放弃等待"
        if ($script:imgJob -and ($script:imgJob.State -eq 'Running' -or $script:imgJob.State -eq 'Stopping')) { try { $script:imgJob.StopJob() | Out-Null } catch {} }
        $script:imgJob = $null
        $stL.Text = "未找到萌百图片（超时）"
        return
    }
    if ($null -eq $script:imgJob) { $script:imgPollTimer.Stop(); $stL.Text = "未找到萌百图片"; return }
    if ($script:imgJob.State -eq 'Running' -or $script:imgJob.State -eq 'NotStarted' -or $script:imgJob.State -eq 'Stopping') {
        # 每5次轮询更新一次状态栏，给用户反馈
        if ($script:pollTickCount % 10 -eq 0) { $stL.Text = "正在查找萌百图片...($([Math]::Floor($script:pollTickCount / 2)))" }
        return
    }
    # 作业已结束（Completed / Failed / Stopped）
    $script:imgPollTimer.Stop()
    $jobState = $script:imgJob.State
    Write-DiagLog "ImgTimer: 作业结束，状态=$jobState 轮询次数=$($script:pollTickCount)"
    if ($jobState -ne 'Completed') {
        Write-DiagLog "ImgTimer: 作业未成功完成"
        try { if ($script:imgJob.ChildJobs[0].Error) { foreach ($e in $script:imgJob.ChildJobs[0].Error) { Write-DiagLog "ImgTimer: 错误: $e" } } } catch {}
        $script:imgJob = $null; $stL.Text = "未找到萌百图片"
        return
    }
    # Completed — 取回结果
    $images = @()
    try {
        $images = @(Receive-Job $script:imgJob -ErrorAction SilentlyContinue)
        Write-DiagLog "ImgTimer: Receive-Job 收到 $($images.Count) 个结果"
        foreach ($imgUrl in $images) { Write-DiagLog "ImgTimer: URL: $imgUrl" }
    } catch { Write-DiagLog "ImgTimer: Receive-Job 失败: $_" }
    $script:imgJob = $null
    # 下载所有图片到缓存
    $script:imgCachePaths = @(); $script:imgCurrentIndex = 0
    $stL.Text = "正在下载萌百图片..."; [System.Windows.Forms.Application]::DoEvents()
    foreach ($imgUrl in $images) {
        $cf = Get-CachedImage -ImageUrl $imgUrl
        if ($cf -and (Test-Path $cf)) { $script:imgCachePaths += $cf }
    }
    Write-DiagLog "ImgTimer: 成功缓存 $($script:imgCachePaths.Count)/$($images.Count) 张图片"
    if ($script:imgCachePaths.Count -gt 0) {
        # 释放旧图片防止 GDI+ 资源泄漏
        try { if ($mainPic.Image) { $mainPic.Image.Dispose() } } catch {}
        try {
            $mainPic.Image = [System.Drawing.Image]::FromFile($script:imgCachePaths[0])
            $imgCounterLabel.Text = "第 1/$($script:imgCachePaths.Count) 张"
            $imgCounterLabel.Visible = $true
            $btnPrev.Visible = $false
            $btnNext.Visible = $script:imgCachePaths.Count -gt 1
            $script:imgLoadedForTitle = $script:imgLoadingTitle
        } catch { Write-DiagLog "ImgTimer: 首图加载失败: $_" }
        $stL.Text = "加载了 $($script:imgCachePaths.Count) 张萌百图片"
    } else {
        try { if ($mainPic.Image) { $mainPic.Image.Dispose() } } catch {}
        $mainPic.Image = $null; $btnPrev.Visible = $false; $btnNext.Visible = $false; $imgCounterLabel.Visible = $false
        $script:imgLoadedForTitle = $script:imgLoadingTitle   # 标为已加载（即使无图），避免重复请求
        $stL.Text = "未找到萌百图片"; Write-DiagLog "ImgTimer: 未找到图片"
    }
})

[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::Run($form)

