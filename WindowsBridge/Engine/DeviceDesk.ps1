#requires -Version 5.1
# DeviceDesk - Windows PowerShell 5.1, x64, STA.
[CmdletBinding()]
param([switch]$ValidateOnly)
$ErrorActionPreference = 'Stop'
# English-only UI helpers; no language files or saved-language preference required.
function Format-UiText([string]$Text, [object[]]$Values = @()) {
    if($Values.Count -gt 0){return ($Text -f $Values)}
    return $Text
}
function Set-ControlText($Control,[string]$Text){$Control.Text=$Text}
function Set-Status([string]$Text,[object[]]$Values=@()){$status.Text=Format-UiText $Text $Values}

# Executed locally in a worker process or on the target via WinRM.
$Worker = {
    param([string]$Mode, $Payload, [string]$PopupCode, [string]$DriverCode)
    $ErrorActionPreference = 'Stop'
    if($Mode -in @('Inventory','DriverUpdates')){. ([scriptblock]::Create($DriverCode))}
    if($Mode -eq 'DriverUpdates'){return Get-DriverUpdateReport}
    $ErrorActionPreference = 'Stop'
    function Row($Name,$Value) { [pscustomobject]@{Item=$Name; Value=[string]$Value} }
    function SafePath([string]$Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        while ($null -ne $item) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
            if ($item -is [IO.FileInfo]) { $item=$item.Directory } else { $item=$item.Parent }
        }
        return $true
    }
    function TempFiles {
        $roots = @((Join-Path $env:windir 'Temp'), $env:TEMP) | Select-Object -Unique
        foreach ($root in $roots) {
            if (!(Test-Path -LiteralPath $root) -or !(SafePath $root)) { continue }
            $stack = New-Object 'System.Collections.Generic.Stack[string]'
            $stack.Push($root)
            while ($stack.Count -gt 0) {
                $dir=$stack.Pop()
                if (!(SafePath $dir)) { continue }
                foreach ($f in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
                    if ($f.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($f.PSIsContainer) { $stack.Push($f.FullName) }
                    elseif ($f.LastWriteTimeUtc -lt [datetime]::UtcNow.AddDays(-7)) {
                        [pscustomobject]@{Path=$f.FullName; Bytes=$f.Length; Stamp=$f.LastWriteTimeUtc.Ticks}
                    }
                }
            }
        }
    }
    function PreviewFolder {
        $base=[Environment]::GetFolderPath('LocalApplicationData')
        if([string]::IsNullOrWhiteSpace($base)){throw 'The execution account has no local application data folder.'}
        $folder=Join-Path $base 'DeviceDesk\CleanupPreviews'
        [void][IO.Directory]::CreateDirectory($folder)
        if(!(SafePath $folder)){throw 'Cleanup preview storage cannot use a redirected or linked folder.'}
        return $folder
    }
    function PreviewAccount { return ([Environment]::UserDomainName+'\'+[Environment]::UserName) }
    function PreviewHash($Stream) {
        $sha=[Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($Stream))).Replace('-','') }
        finally {$sha.Dispose()}
    }
    if ($Mode -eq 'TempPreview') {
        $folder=PreviewFolder
        # Only expire this app's old preview metadata, never the candidate temp files.
        foreach($old in Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue) {
            if($old.Name -match '^[a-f0-9]{32}\.jsonl$' -and $old.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-30) -and !($old.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
            }
        }
        $id=[guid]::NewGuid().ToString('N'); $path=Join-Path $folder ($id+'.jsonl')
        $expires=[datetime]::UtcNow.AddMinutes(15)
        $header=@{Version=1;PreviewId=$id;Computer=$env:COMPUTERNAME;Account=(PreviewAccount);ExpiresUtc=$expires.ToString('o')}
        [long]$count=0; [long]$bytes=0; $writer=$null; $stream=$null; $success=$false
        try {
            $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            $writer=[IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),4096,$true)
            $writer.WriteLine(($header | ConvertTo-Json -Compress))
            $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            TempFiles | ForEach-Object {
                if($seen.Add($_.Path)) {
                    $writer.WriteLine(($_ | ConvertTo-Json -Compress))
                    $count++; $bytes+=[long]$_.Bytes
                }
            }
            $writer.Flush(); $stream.Position=0; $hash=PreviewHash $stream
            $success=$true
        } finally {
            if($writer){$writer.Dispose()}; if($stream){$stream.Dispose()}
            if(!$success -or $count -eq 0){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
        }
        # This single small record is the only preview object crossing WinRM/Start-Job.
        return [pscustomobject]@{Kind='TempPreview';PreviewId=$id;Hash=$hash;FileCount=$count;Bytes=$bytes;ExpiresUtc=$expires.ToString('o')}
    }
    if ($Mode -in @('TempDelete','TempDiscard')) {
        if(!$Payload -or [string]$Payload.PreviewId -notmatch '^[a-f0-9]{32}$' -or [string]$Payload.Hash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'Invalid cleanup preview reference. Run Preview temp cleanup again.'
        }
        $path=Join-Path (PreviewFolder) ([string]$Payload.PreviewId+'.jsonl')
        if(!(Test-Path -LiteralPath $path -PathType Leaf) -or !(SafePath $path)){throw 'Cleanup preview is unavailable. Run Preview temp cleanup again.'}
        $stream=$null; $reader=$null; $consume=$false
        [long]$count=0; [long]$bytes=0; [long]$skipped=0
        try {
            # Lock against modification while checking the digest and reading this snapshot.
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
            if((PreviewHash $stream) -cne ([string]$Payload.Hash).ToUpperInvariant()){throw 'Cleanup preview changed. Nothing was deleted. Run the preview again.'}
            $stream.Position=0
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,4096,$true)
            $header=$reader.ReadLine() | ConvertFrom-Json
            if($header.Version -ne 1 -or $header.PreviewId -cne [string]$Payload.PreviewId -or $header.Computer -ine $env:COMPUTERNAME -or $header.Account -ine (PreviewAccount)) {
                throw 'The cleanup preview belongs to a different computer or account. Run the preview again.'
            }
            $consume=$true
            if($Mode -eq 'TempDiscard'){return 'Cleanup cancelled; preview metadata removed.'}
            if([datetime]::Parse($header.ExpiresUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind) -lt [datetime]::UtcNow) {
                throw 'Cleanup preview expired. Nothing was deleted. Run the preview again.'
            }
            # Re-enumerate allowed files on the target; never accept arbitrary input paths.
            $allowed=@{}; TempFiles | ForEach-Object {$allowed[$_.Path]=$_}
            while(!$reader.EndOfStream) {
                $entry=$reader.ReadLine() | ConvertFrom-Json
                try {
                    $f=$allowed[$entry.Path]
                    if(!$f -or $f.Stamp -ne $entry.Stamp -or $f.Bytes -ne $entry.Bytes -or !(SafePath $entry.Path)){$skipped++;continue}
                    $current=Get-Item -LiteralPath $entry.Path -Force
                    if($current.LastWriteTimeUtc.Ticks -ne $entry.Stamp -or $current.Length -ne $entry.Bytes){$skipped++;continue}
                    Remove-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
                    $count++; $bytes+=[long]$entry.Bytes
                } catch {$skipped++}
            }
        } finally {
            if($reader){$reader.Dispose()}; if($stream){$stream.Dispose()}
            if($consume){Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue}
        }
        return "Deleted files: $count | MB: $([math]::Round($bytes/1MB,2)) | Skipped/locked: $skipped"
    }
    if ($Mode -eq 'PopupMessage') {
        if(!$Payload -or [string]::IsNullOrWhiteSpace($PopupCode)){throw 'The popup messaging component is missing. Extract the complete app ZIP.'}
        if(!('DeviceDesk.PopupMessaging' -as [type])){Add-Type -TypeDefinition $PopupCode}
        return [DeviceDesk.PopupMessaging]::Send([string]$Payload.Title,[string]$Payload.Message,[int]$Payload.Seconds,([Security.Principal.WindowsIdentity]::GetCurrent().Name))
    }
    if ($Mode -eq 'Restart') {
        $out=& "$env:windir\System32\shutdown.exe" /r /t 0 2>&1
        if ($LASTEXITCODE -ne 0) { throw ($out -join ' ') }
        return 'Restart requested; refresh later to verify boot time.'
    }
    if ($Mode -eq 'Trim') {
        $proc=Get-Process -Id ([int]$Payload.Id)
        if ($proc.SessionId -eq 0 -or $proc.Id -eq $PID -or $proc.StartTime.ToUniversalTime().Ticks -ne [long]$Payload.StartTicks) { throw 'Process changed or is a service. Refresh inventory.' }
        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class MemoryNative { [DllImport("psapi.dll", SetLastError=true)] [return: MarshalAs(UnmanagedType.Bool)] public static extern bool EmptyWorkingSet(IntPtr process); }'
        $before=$proc.WorkingSet64
        if (![MemoryNative]::EmptyWorkingSet($proc.Handle)) { throw (New-Object ComponentModel.Win32Exception) }
        $proc.Refresh()
        return "Working set MB: $([math]::Round($before/1MB,1)) -> $([math]::Round($proc.WorkingSet64/1MB,1)). Temporary effect; pages can return."
    }
    $data=[ordered]@{}; $issues=New-Object 'System.Collections.Generic.List[object]'
    function Section([string]$Name,[scriptblock]$Code) {
        try { $data[$Name]=@(& $Code) }
        catch { $data[$Name]=@(); $issues.Add((Row $Name $_.Exception.Message)) }
    }
    Section 'Summary' {
        $os=Get-CimInstance Win32_OperatingSystem
        $cs=Get-CimInstance Win32_ComputerSystem
        $bios=Get-CimInstance Win32_BIOS
        $up=(Get-Date)-$os.LastBootUpTime
        Row 'Computer' $env:COMPUTERNAME
        Row 'Manufacturer' $cs.Manufacturer; Row 'Model' $cs.Model
        Row 'PCSystemType (1 Desktop, 2 Mobile, 3 Workstation)' $cs.PCSystemType
        Row 'Serial number' $bios.SerialNumber
        Row 'Windows' ($os.Caption+' / '+$os.Version)
        Row 'CPU' ((Get-CimInstance Win32_Processor | ForEach-Object Name)-join '; ')
        Row 'Boot time' $os.LastBootUpTime
        Row 'Uptime' ("{0} days {1} hours {2} minutes" -f $up.Days,$up.Hours,$up.Minutes)
        Row 'RAM total GB' ([math]::Round($os.TotalVisibleMemorySize/1MB,2))
        Row 'RAM available GB' ([math]::Round($os.FreePhysicalMemory/1MB,2))
        Row 'Collected at' (Get-Date -Format o)
        Row 'Execution account' ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
    }
    Section 'Network' {
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' | ForEach-Object {
            [pscustomobject]@{Name=$_.Description; IP=($_.IPAddress -join ', '); MAC=$_.MACAddress; Subnet=($_.IPSubnet -join ', '); Gateway=($_.DefaultIPGateway -join ', '); DHCP=$_.DHCPEnabled}
        }
    }
    Section 'Programs' {
        # Registry enumeration avoids Win32_Product repair side effects.
        $keys=@('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')
        foreach ($key in $keys) {
            Get-ItemProperty $key -ErrorAction SilentlyContinue | Where-Object DisplayName | ForEach-Object {
                [pscustomobject]@{Name=$_.DisplayName; Version=$_.DisplayVersion; Publisher=$_.Publisher; Scope=$(if($key -like 'HKCU*'){'Execution user'}else{'Machine'})}
            }
        }
        try {
            Get-AppxPackage -AllUsers -ErrorAction Stop | ForEach-Object { [pscustomobject]@{Name=$_.Name;Version=[string]$_.Version;Publisher=$_.Publisher;Scope='Appx / all users'} }
        } catch { $issues.Add((Row 'Appx' $_.Exception.Message)) }
    }
    Section 'Drivers' {
        Get-CimInstance Win32_PnPSignedDriver | Select-Object DeviceName,DriverVersion,DriverProviderName,DriverDate,IsSigned,DeviceID
    }
    Section 'Connected' {
        Get-ConnectedDriverInventory
    }
    Section 'Disks' {
        $physical=@()
        try { $physical=@(Get-PhysicalDisk) } catch { $issues.Add((Row 'Storage API' $_.Exception.Message)) }
        Get-CimInstance Win32_DiskDrive | ForEach-Object {
            $d=$_; $pd=@($physical | Where-Object { [string]$_.DeviceId -eq [string]$d.Index })
            $temp='Unavailable'; $media=$d.MediaType; $bus=$d.InterfaceType; $health='Unknown'
            if ($pd.Count -eq 1) {
                $media=[string]$pd[0].MediaType; $bus=[string]$pd[0].BusType; $health=[string]$pd[0].HealthStatus
                try { $counter=$pd[0] | Get-StorageReliabilityCounter; if ($null -ne $counter.Temperature -and $counter.Temperature -gt 0) { $temp=[string]$counter.Temperature } } catch {}
            }
            [pscustomobject]@{Disk=$d.Index; Model=$d.Model; Serial=$d.SerialNumber; Type=$media; Bus=$bus; SizeGB=[math]::Round($d.Size/1GB,2); TemperatureC=$temp; Health=$health}
        }
    }
    Section 'Volumes' {
        Get-CimInstance Win32_LogicalDisk | Where-Object {$_.Size -gt 0} | ForEach-Object {
            [pscustomobject]@{Drive=$_.DeviceID;Label=$_.VolumeName;FileSystem=$_.FileSystem;SizeGB=[math]::Round($_.Size/1GB,2);FreeGB=[math]::Round($_.FreeSpace/1GB,2)}
        }
    }
    Section 'Processes' {
        Get-Process | ForEach-Object {
            try { [pscustomobject]@{Id=$_.Id;Name=$_.ProcessName;MemoryMB=[math]::Round($_.WorkingSet64/1MB,1);Session=$_.SessionId;StartTicks=$_.StartTime.ToUniversalTime().Ticks} } catch {}
        } | Sort-Object MemoryMB -Descending
    }
    Section 'SCCM' {
        Row 'Assessment' 'Indicators only; does not verify site communication, policy or deployment compliance.'
        foreach ($name in @('CcmExec','CmRcService','Winmgmt','BITS')) {
            $svc=Get-Service $name -ErrorAction SilentlyContinue
            Row $name $(if($svc){[string]$svc.Status}else{'Not installed / not found'})
        }
        $basicOk=$false
        try {
            $client=Get-CimInstance -Namespace root\ccm -ClassName SMS_Client
            $basicOk=([bool]$client.ClientVersion -and (Get-Service CcmExec).Status -eq 'Running')
            Row 'Client version' $client.ClientVersion
            Row 'Assigned site' (Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName GetAssignedSite).sSiteCode
        } catch { Row 'Client WMI' ('Unavailable: '+$_.Exception.Message) }
        try {
            $task=Get-ScheduledTask -TaskPath '\Microsoft\Configuration Manager\' -TaskName 'Configuration Manager Health Evaluation'
            $info=$task | Get-ScheduledTaskInfo
            Row 'CcmEval last run' $info.LastRunTime
            Row 'CcmEval task exit code (0 is task success only)' $info.LastTaskResult
            Row 'CcmEval recent (within 3 days)' ($info.LastRunTime -gt (Get-Date).AddDays(-3))
        } catch { Row 'CcmEval task' ('Unknown: '+$_.Exception.Message) }
        Row 'Basic client status' $(if($basicOk){'Running and WMI readable; full health NOT confirmed. Review evaluation report and site console.'}else{'Needs attention / not installed / insufficient access. Review details above.'})
        $report=Join-Path $env:windir 'CCM\CcmEvalReport.xml'
        if (Test-Path $report) {
            Row 'Report modified' (Get-Item $report).LastWriteTime
            Row 'Evaluation report (raw)' (Get-Content $report -Raw)
        } else { Row 'Evaluation report' 'Not found' }
        $log=Join-Path $env:windir 'CCM\Logs\CcmEval.log'
        if (Test-Path $log) { Row 'CcmEval log (last 30 lines)' ((Get-Content $log -Tail 30)-join "`r`n") }
    }
    $data['Errors']=@($issues.ToArray())
    [pscustomobject]$data
}
if ($ValidateOnly) { return }
if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitProcess) { throw 'Run with 64-bit Windows PowerShell 5.1.' }
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'ExtraPages.ps1')
$script:job=$null; $script:credential=$null; $script:inventory=$null; $script:grids=@{}
$blue=[Drawing.ColorTranslator]::FromHtml('#087DFA')
$navy=[Drawing.ColorTranslator]::FromHtml('#173554')
$muted=[Drawing.ColorTranslator]::FromHtml('#63788F')
$surface=[Drawing.ColorTranslator]::FromHtml('#F1F6FC')
$teal=[Drawing.ColorTranslator]::FromHtml('#00B9B3')
$form=New-Object Windows.Forms.Form
$form.Text='Saudi Energy | DeviceDesk'; $form.Size=New-Object Drawing.Size(1380,920); $form.MinimumSize=New-Object Drawing.Size(1280,850); $form.StartPosition='CenterScreen'
$form.Font=New-Object Drawing.Font('Segoe UI',10)
$form.AutoScaleMode='Font'; $form.BackColor=$surface
$root=New-Object Windows.Forms.TableLayoutPanel
$root.Dock='Fill'; $root.ColumnCount=1; $root.RowCount=5; $root.Padding=[Windows.Forms.Padding]::new(18,12,18,10)
foreach($height in @(108,224,86)){[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height)))}
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',34)))
$form.Controls.Add($root)
$header=New-Object Windows.Forms.Panel; $header.Dock='Fill'; $header.BackColor=[Drawing.Color]::White; $header.Margin=[Windows.Forms.Padding]::new(0,0,0,10)
$root.Controls.Add($header,0,0)
# Fixed logo column and flexible title column.
$headerGrid=New-Object Windows.Forms.TableLayoutPanel; $headerGrid.Dock='Fill'; $headerGrid.ColumnCount=2; $headerGrid.RowCount=1; $headerGrid.Margin=[Windows.Forms.Padding]::new(0)
[void]$headerGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',178)))
[void]$headerGrid.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
$header.Controls.Add($headerGrid)
$logoPath=Join-Path $PSScriptRoot 'company-logo.png'
$script:logoImage=$null
if(Test-Path -LiteralPath $logoPath){$script:logoImage=[Drawing.Image]::FromFile($logoPath)}
$logoPanel=New-Object Windows.Forms.Panel; $logoPanel.Dock='Fill'; $logoPanel.Width=178
$logoPanel.Add_Paint({param($sender,$e)
    if($script:logoImage){
        $e.Graphics.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        # Render the supplied logo's content area; the original PNG is unchanged.
        $e.Graphics.DrawImage($script:logoImage,(New-Object Drawing.Rectangle(30,4,113,92)),125,140,195,160,[Drawing.GraphicsUnit]::Pixel)
    }
})
$headerGrid.Controls.Add($logoPanel,0,0)
$titleBlock=New-Object Windows.Forms.TableLayoutPanel; $titleBlock.Dock='Fill'; $titleBlock.RowCount=2; $titleBlock.Padding=[Windows.Forms.Padding]::new(12,12,22,12)
$title=New-Object Windows.Forms.Label; $title.Dock='Fill'; Set-ControlText $title 'Device Management Center'; $title.Font=New-Object Drawing.Font('Segoe UI',22,[Drawing.FontStyle]::Bold); $title.ForeColor=$navy; $title.TextAlign='MiddleLeft'
$subtitle=New-Object Windows.Forms.Label; $subtitle.Dock='Fill'; Set-ControlText $subtitle 'DeviceDesk   /   Device information • Remote support • Maintenance'; $subtitle.ForeColor=$muted; $subtitle.TextAlign='MiddleLeft'
[void]$titleBlock.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',65)))
[void]$titleBlock.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',35)))
$titleBlock.Controls.Add($title,0,0); $titleBlock.Controls.Add($subtitle,0,1); $headerGrid.Controls.Add($titleBlock,1,0)
$accent=New-Object Windows.Forms.Panel; $accent.Dock='Bottom'; $accent.Height=3; $accent.BackColor=$teal; $header.Controls.Add($accent); $headerGrid.BringToFront()
$top=New-Object Windows.Forms.TableLayoutPanel; $top.Dock='Fill'; $top.RowCount=4; $top.ColumnCount=1; $top.Margin=[Windows.Forms.Padding]::new(0,0,0,8); $top.BackColor=[Drawing.Color]::White
foreach($n in 1..4){[void]$top.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',25)))}
$root.Controls.Add($top,0,1)
$script:bar=$null
function New-Bar([int]$index,[string]$caption){
    $script:bar=New-Object Windows.Forms.FlowLayoutPanel; $script:bar.Dock='Fill'; $script:bar.FlowDirection='LeftToRight'; $script:bar.WrapContents=$false; $script:bar.AutoScroll=$true; $script:bar.Padding=[Windows.Forms.Padding]::new(6,7,6,4); $script:bar.Margin=[Windows.Forms.Padding]::new(0)
    $top.Controls.Add($script:bar,0,$index)
    $l=New-Object Windows.Forms.Label; Set-ControlText $l $caption; $l.ForeColor=$muted; $l.Width=115; $l.Height=34; $l.TextAlign='MiddleLeft'; $script:bar.Controls.Add($l)
}
function Label($text) { $l=New-Object Windows.Forms.Label; Set-ControlText $l $text; $l.AutoSize=$true; $l.Margin=[Windows.Forms.Padding]::new(6,8,3,3); $l.ForeColor=$muted; $script:bar.Controls.Add($l) }
function TextBox($value,$width) { $t=New-Object Windows.Forms.TextBox; $t.Text=$value; $t.Width=$width; $t.Margin=[Windows.Forms.Padding]::new(4,5,4,3); $t.RightToLeft='No'; $script:bar.Controls.Add($t); return $t }
function Button($text,[scriptblock]$click) {
    $b=New-Object Windows.Forms.Button; Set-ControlText $b $text; $b.AutoSize=$true; $b.Height=35; $b.Padding=[Windows.Forms.Padding]::new(10,2,10,2); $b.Margin=[Windows.Forms.Padding]::new(4,1,4,1); $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize=0; $b.BackColor=$surface; $b.ForeColor=$navy; $b.Cursor='Hand'
    $b.Add_Click($click); $script:bar.Controls.Add($b); return $b
}
New-Bar 0 'Connection'
function Info($s) { [void][Windows.Forms.MessageBox]::Show([string]$s,'DeviceDesk') }
function Show-Details([string]$text){
    $detail=New-Object Windows.Forms.Form; $detail.Text=Format-UiText 'DeviceDesk | Details'; $detail.Size=New-Object Drawing.Size(900,600); $detail.StartPosition='CenterParent'; $detail.Font=$form.Font; $detail.MinimizeBox=$false
    $body=New-Object Windows.Forms.TextBox; $body.Dock='Fill'; $body.Multiline=$true; $body.ReadOnly=$true; $body.ScrollBars='Both'; $body.WordWrap=$false; $body.Text=$text; $body.BackColor=[Drawing.Color]::White
    $detail.Controls.Add($body)
    try{[void]$detail.ShowDialog($form)}finally{$detail.Dispose()}
}
function Confirm($s) { return [Windows.Forms.MessageBox]::Show($s,(Format-UiText 'Confirm action'),'YesNo','Warning','Button2') -eq 'Yes' }
function Target {
    $t=$targetBox.Text.Trim()
    if ($t -notmatch '^(\.|[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252})$') { throw (Format-UiText 'Enter a valid computer name or IPv4 address.') }
    return $t
}
Label 'Computer:'; $targetBox=TextBox $env:COMPUTERNAME 180
$https=New-Object Windows.Forms.CheckBox; $https.Text='WinRM HTTPS'; $https.AutoSize=$true; $https.Margin=[Windows.Forms.Padding]::new(6,8,4,3); $script:bar.Controls.Add($https)
$scan=Button 'Scan / Refresh' { try { Start-Operation 'Inventory' $null } catch { Info $_.Exception.Message } }
$cred=Button 'Connection account' { $script:credential=Get-Credential -Message (Format-UiText 'Remote computer administrator account (password is not saved)') }
$clearCred=Button 'Current account' { $script:credential=$null; Info (Format-UiText 'The current Windows account will be used.') }
$export=Button 'Export report' {
    if (!$script:inventory) { Info (Format-UiText 'Scan the computer first.'); return }
    $d=New-Object Windows.Forms.SaveFileDialog; $d.Filter='JSON (*.json)|*.json'; $d.FileName='DeviceDesk-report.json'
    if ($d.ShowDialog() -eq 'OK') { try { $script:inventory | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $d.FileName -Encoding UTF8; Info (Format-UiText 'Report saved.') } catch { Info $_.Exception.Message } }
}
$scan.BackColor=$blue; $scan.ForeColor=[Drawing.Color]::White
New-Bar 1 'Remote support'
Label 'CmRcViewer.exe:'; $viewer=TextBox '' 320
if ($env:SMS_ADMIN_UI_PATH) { $viewer.Text=Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH) 'i386\CmRcViewer.exe' }
$browse=Button 'Browse viewer' { $d=New-Object Windows.Forms.OpenFileDialog; $d.Filter='CmRcViewer|CmRcViewer.exe'; if($d.ShowDialog() -eq 'OK'){$viewer.Text=$d.FileName} }
$remote=Button 'SCCM Remote Control' {
    try { $t=Target; if (!(Test-Path -LiteralPath $viewer.Text -PathType Leaf) -or [IO.Path]::GetFileName($viewer.Text) -ine 'CmRcViewer.exe') { throw (Format-UiText 'Select CmRcViewer.exe from your Configuration Manager Console installation.') }; Start-Process -FilePath $viewer.Text -ArgumentList $t } catch { Info $_.Exception.Message }
}
$rdp=Button 'RDP connection' { try { $t=Target; Start-Process "$env:windir\System32\mstsc.exe" -ArgumentList "/v:$t" } catch { Info $_.Exception.Message } }
function Show-PopupComposer {
    if($script:job){Info 'Wait for the current operation to finish.';return}
    $destination=Target
    $dialog=New-Object Windows.Forms.Form
    $dialog.Text='Send popup message'; $dialog.Size=[Drawing.Size]::new(680,510); $dialog.MinimumSize=[Drawing.Size]::new(600,470)
    $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font; $dialog.MinimizeBox=$false; $dialog.MaximizeBox=$false
    $layout=New-Object Windows.Forms.TableLayoutPanel; $layout.Dock='Fill'; $layout.RowCount=7; $layout.ColumnCount=1; $layout.Padding=[Windows.Forms.Padding]::new(16)
    foreach($height in @(42,24,35,24,0,48,48)) {
        if($height){[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Absolute',$height))}
        else{[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new('Percent',100))}
    }
    $dialog.Controls.Add($layout)
    $targetLabel=New-Object Windows.Forms.Label; $targetLabel.Text='Target computer: '+$destination; $targetLabel.Dock='Fill'; $targetLabel.ForeColor=$navy
    $layout.Controls.Add($targetLabel,0,0)
    $titleLabel=New-Object Windows.Forms.Label; $titleLabel.Text='Title'; $titleLabel.Dock='Fill'; $layout.Controls.Add($titleLabel,0,1)
    $messageTitle=New-Object Windows.Forms.TextBox; $messageTitle.Text='IT Support'; $messageTitle.MaxLength=100; $messageTitle.Dock='Fill'; $layout.Controls.Add($messageTitle,0,2)
    $bodyLabel=New-Object Windows.Forms.Label; $bodyLabel.Text='Message (up to 2,000 characters)'; $bodyLabel.Dock='Fill'; $layout.Controls.Add($bodyLabel,0,3)
    $messageBody=New-Object Windows.Forms.TextBox; $messageBody.Multiline=$true; $messageBody.AcceptsReturn=$true; $messageBody.ScrollBars='Vertical'; $messageBody.MaxLength=2000; $messageBody.Dock='Fill'; $layout.Controls.Add($messageBody,0,4)
    $hint=New-Object Windows.Forms.Label; $hint.Text='Sends to active signed-in users on this computer. The popup closes after 60 seconds. Your execution account is shown as the sender.'; $hint.Dock='Fill'; $layout.Controls.Add($hint,0,5)
    $actions=New-Object Windows.Forms.FlowLayoutPanel; $actions.Dock='Fill'; $actions.FlowDirection='RightToLeft'; $layout.Controls.Add($actions,0,6)
    $cancelButton=New-Object Windows.Forms.Button; $cancelButton.Text='Cancel'; $cancelButton.Width=100; $cancelButton.Height=34; $cancelButton.DialogResult='Cancel'; $actions.Controls.Add($cancelButton)
    $sendButton=New-Object Windows.Forms.Button; $sendButton.Text='Send message'; $sendButton.Width=145; $sendButton.Height=34; $sendButton.BackColor=$blue; $sendButton.ForeColor=[Drawing.Color]::White; $sendButton.DialogResult='OK'; $actions.Controls.Add($sendButton)
    $dialog.AcceptButton=$sendButton; $dialog.CancelButton=$cancelButton
    try {
        while($true) {
            $dialog.DialogResult='None'
            if($dialog.ShowDialog($form) -ne 'OK'){return}
            if([string]::IsNullOrWhiteSpace($messageTitle.Text) -or [string]::IsNullOrWhiteSpace($messageBody.Text)){Info 'Enter a title and a message.';continue}
            if((Target) -ne $destination){throw 'The target changed. Reopen the popup message window.'}
            Start-Operation 'PopupMessage' @{Title=$messageTitle.Text;Message=$messageBody.Text;Seconds=60}
            return
        }
    } finally {$dialog.Dispose()}
}

$popupButton=Button 'Send popup message' {try {Show-PopupComposer} catch {Info $_.Exception.Message}}
New-Bar 2 'Power'
Label 'MAC:'; $mac=TextBox '' 145; Label 'Broadcast IPv4:'; $broadcast=TextBox '255.255.255.255' 135
$wake=Button 'Wake-on-LAN' {
    try {
        $m=$mac.Text -replace '[:-]',''; if($m -notmatch '^[0-9a-fA-F]{12}$'){throw (Format-UiText 'Enter a valid MAC address for the target computer.')}
        $ip=[Net.IPAddress]::Parse($broadcast.Text); if($ip.AddressFamily -ne 'InterNetwork'){throw 'IPv4 required'}
        [byte[]]$six=0..5 | ForEach-Object {[Convert]::ToByte($m.Substring($_*2,2),16)}
        [byte[]]$packet=@(255)*6; 1..16 | ForEach-Object {$packet+=$six}
        $udp=New-Object Net.Sockets.UdpClient
        try {$udp.EnableBroadcast=$true; [void]$udp.Send($packet,$packet.Length,(New-Object Net.IPEndPoint($ip,9)))} finally {$udp.Dispose()}
        Info (Format-UiText 'Wake packet sent to the specified MAC address. This does not confirm that the computer started; wait, then scan it.')
    } catch {Info $_.Exception.Message}
}
$restart=Button 'Restart' { try { $t=Target; if(Confirm (Format-UiText 'Restart {0} now? Save open work first. Applications will not be forcibly closed.' @($t))){ Start-Operation 'Restart' $null } } catch {Info $_.Exception.Message} }
New-Bar 3 'Maintenance'
$restart.BackColor=[Drawing.ColorTranslator]::FromHtml('#FFF0ED'); $restart.ForeColor=[Drawing.ColorTranslator]::FromHtml('#AC3829')
$clean=Button 'Preview temp cleanup' { try {Start-Operation 'TempPreview' $null} catch {Info $_.Exception.Message} }
$trim=Button 'Trim selected app RAM' {
    try {
        if (!$script:inventory -or (Target) -ne $script:inventory.Target) {throw (Format-UiText 'Scan the current target first.')}
        $g=$script:grids['Processes']; if($g.SelectedRows.Count -ne 1){throw (Format-UiText 'Select an application in the Processes and RAM tab.')}
        $row=$g.SelectedRows[0]; $pidValue=[int]$row.Cells['Id'].Value
        $ticks=[long]$row.Cells['StartTicks'].Value; $name=$row.Cells['Name'].Value
        if(Confirm (Format-UiText 'Trim the working set of {0} (PID {1}) on {2}? This may temporarily slow the application, and memory will return as needed. The application will not be closed.' @($name,$pidValue,(Target)))) { Start-Operation 'Trim' @{Id=$pidValue;StartTicks=$ticks} }
    } catch {Info $_.Exception.Message}
}
Label 'Select a process to trim its memory. Cleanup and restart require confirmation.'
$cards=New-Object Windows.Forms.TableLayoutPanel; $cards.Dock='Fill'; $cards.ColumnCount=4; $cards.RowCount=1; $cards.Margin=[Windows.Forms.Padding]::new(0,0,0,10)
$root.Controls.Add($cards,0,2); $script:cardValues=@{}
$cardTitles=[ordered]@{Computer='Displayed computer';Memory='RAM available / total';Uptime='Uptime';Disks='Disk count'}
$ci=0
foreach($key in $cardTitles.Keys){
    [void]$cards.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',25)))
    $card=New-Object Windows.Forms.Panel; $card.Dock='Fill'; $card.BackColor=[Drawing.Color]::White; $card.Margin=[Windows.Forms.Padding]::new(4,0,4,0); $card.Padding=[Windows.Forms.Padding]::new(12,6,12,5)
    $caption=New-Object Windows.Forms.Label; $caption.Dock='Top'; $caption.Height=23; Set-ControlText $caption $cardTitles[$key]; $caption.TextAlign='MiddleLeft'; $caption.ForeColor=$muted
    $value=New-Object Windows.Forms.Label; $value.Dock='Fill'; $value.Text='—'; $value.TextAlign='MiddleLeft'; $value.ForeColor=$navy; $value.Font=New-Object Drawing.Font('Segoe UI',12,[Drawing.FontStyle]::Bold); $value.AutoEllipsis=$true
    $card.Controls.Add($value); $card.Controls.Add($caption); $cards.Controls.Add($card,$ci,0); $script:cardValues[$key]=$value; $ci++
}
$status=New-Object Windows.Forms.Label; $status.Dock='Fill'; $status.TextAlign='MiddleLeft'; $status.ForeColor=$muted; Set-Status 'Ready • Enter a computer name, then click Scan / Refresh'; $root.Controls.Add($status,0,4)
$main=New-Object Windows.Forms.TableLayoutPanel; $main.Dock='Fill'; $main.ColumnCount=2; $main.RowCount=1; $main.Margin=[Windows.Forms.Padding]::new(0)
[void]$main.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100)))
[void]$main.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute',208)))
$root.Controls.Add($main,0,3)
$tabs=New-Object Windows.Forms.Panel; $tabs.Dock='Fill'; $tabs.Margin=[Windows.Forms.Padding]::new(0,0,10,0); $tabs.BackColor=[Drawing.Color]::White; $main.Controls.Add($tabs,0,0)
$nav=New-Object Windows.Forms.FlowLayoutPanel; $nav.Dock='Fill'; $nav.FlowDirection='TopDown'; $nav.WrapContents=$false; $nav.AutoScroll=$true; $nav.BackColor=[Drawing.Color]::White; $nav.Padding=[Windows.Forms.Padding]::new(6); $nav.Margin=[Windows.Forms.Padding]::new(0); $main.Controls.Add($nav,1,0)
$names=[ordered]@{Summary='Overview';Network='Network and IPs';Programs='Installed programs';Drivers='Drivers';Connected='Devices and drivers';DriverOffers='Driver updates offered';Directory='Active Directory';Disks='Disks and temperature';Volumes='Storage volumes';Processes='Processes and RAM';SCCM='SCCM client health';Errors='Scan notes'}
$script:pages=@{}; $script:navButtons=@{}
function Select-Page([string]$key){
    $script:selectedPage=$key
    $root.SuspendLayout()
    $isDirectory=($key -eq 'Directory')
    $top.Visible=!$isDirectory; $cards.Visible=!$isDirectory
    $root.RowStyles[1].Height=$(if($isDirectory){0}else{224})
    $root.RowStyles[2].Height=$(if($isDirectory){0}else{86})
    foreach($k in $script:pages.Keys){
        $script:pages[$k].Visible=($k -eq $key)
        $script:navButtons[$k].BackColor=$(if($k -eq $key){$blue}else{[Drawing.Color]::White})
        $script:navButtons[$k].ForeColor=$(if($k -eq $key){[Drawing.Color]::White}else{$navy})
    }
    $root.ResumeLayout($true)
}
foreach($key in $names.Keys){
    $tab=New-Object Windows.Forms.Panel; $tab.Dock='Fill'; $tab.Padding=[Windows.Forms.Padding]::new(12); $tab.Visible=$false
    $heading=New-Object Windows.Forms.Label; Set-ControlText $heading ($names[$key]+'   |   Double-click a cell to view details'); $heading.Dock='Top'; $heading.Height=36; $heading.TextAlign='MiddleLeft'; $heading.ForeColor=$muted
    $grid=New-Object Windows.Forms.DataGridView; $grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.MultiSelect=$false; $grid.SelectionMode='FullRowSelect'; $grid.AutoSizeColumnsMode='DisplayedCells'; $grid.RowHeadersVisible=$false
    $grid.BackgroundColor=[Drawing.Color]::White; $grid.BorderStyle='None'; $grid.CellBorderStyle='SingleHorizontal'; $grid.GridColor=$surface; $grid.EnableHeadersVisualStyles=$false
    $grid.ColumnHeadersDefaultCellStyle.BackColor=$surface; $grid.ColumnHeadersDefaultCellStyle.ForeColor=$navy; $grid.ColumnHeadersDefaultCellStyle.Font=New-Object Drawing.Font('Segoe UI',10,[Drawing.FontStyle]::Bold)
    $grid.ColumnHeadersHeightSizeMode='DisableResizing'; $grid.ColumnHeadersHeight=38; $grid.RowTemplate.Height=32
    $grid.DefaultCellStyle.ForeColor=$navy; $grid.DefaultCellStyle.SelectionBackColor=[Drawing.ColorTranslator]::FromHtml('#DDEDFF'); $grid.DefaultCellStyle.SelectionForeColor=$navy
    $grid.AlternatingRowsDefaultCellStyle.BackColor=[Drawing.ColorTranslator]::FromHtml('#F8FAFD')
    $grid.Add_CellDoubleClick({ param($sender,$e) if($e.RowIndex -ge 0 -and $e.ColumnIndex -ge 0){Show-Details ([string]$sender.Rows[$e.RowIndex].Cells[$e.ColumnIndex].Value)} })
    $tab.Controls.Add($grid); $tab.Controls.Add($heading); $tabs.Controls.Add($tab); $script:grids[$key]=$grid; $script:pages[$key]=$tab
    $nb=New-Object Windows.Forms.Button; Set-ControlText $nb $names[$key]; $nb.Tag=$key; $nb.Width=182; $nb.Height=32; $nb.FlatStyle='Flat'; $nb.FlatAppearance.BorderSize=0; $nb.TextAlign='MiddleLeft'; $nb.Padding=[Windows.Forms.Padding]::new(6,0,6,0); $nb.Margin=[Windows.Forms.Padding]::new(2); $nb.Cursor='Hand'
    $nb.Add_Click({param($sender,$e) Select-Page ([string]$sender.Tag)})
    $nav.Controls.Add($nb); $script:navButtons[$key]=$nb
}
Initialize-ExtraPages
Select-Page 'Summary'
$tooltips=New-Object Windows.Forms.ToolTip
$targetBox.Add_TextChanged({
    if(!$script:job){
        $script:inventory=$null
        foreach($k in $script:grids.Keys){if($k -ne 'Directory'){$script:grids[$k].DataSource=$null}}
        foreach($v in $script:cardValues.Values){$v.Text='—'}
        Set-Status 'Target changed • Click Scan / Refresh to load its data'
    }
})
function Update-Cards($data){
    $values=@{}; foreach($row in @($data.Summary)){$values[$row.Item]=$row.Value}
    $script:cardValues.Computer.Text=$script:operationTarget
    $script:cardValues.Memory.Text=$(if($values.ContainsKey('RAM available GB')){"$($values['RAM available GB']) / $($values['RAM total GB']) GB"}else{Format-UiText 'Unavailable'})
    $script:cardValues.Uptime.Text=$(if($values['Uptime']){$values['Uptime']}else{Format-UiText 'Unavailable'})
    $script:cardValues.Disks.Text=$(if(@($data.Errors | Where-Object Item -eq 'Disks').Count){Format-UiText 'Unavailable'}else{[string](@($data.Disks).Count)})
}
function FillGrid($key,$rows){
    $table=New-Object Data.DataTable
    $arr=@($rows | Where-Object {$null -ne $_})
    if($arr.Count -gt 0){
        $props=@($arr[0].PSObject.Properties.Name | Where-Object {$_ -notin @('PSComputerName','RunspaceId','PSShowComputerName')})
        foreach($p in $props){[void]$table.Columns.Add($p,[string])}
        foreach($r in $arr){$dr=$table.NewRow();foreach($p in $props){$dr[$p]=[string]$r.$p};$table.Rows.Add($dr)}
    }
    $script:grids[$key].DataSource=$table
}
function Start-Operation([string]$mode,$payload){
    if($script:job){throw (Format-UiText 'Wait for the current operation to finish.')}
    $t=Target
    if($mode -eq 'DriverUpdates'){
        $script:grids.Connected.DataSource=$null; $script:grids.DriverOffers.DataSource=$null
        if($script:inventory){
            $script:inventory.Data.Connected=@()
            $script:inventory.PSObject.Properties.Remove('DriverUpdateCheck')
        }
    }
    $driverCodeForJob=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'DriverTools.ps1') -Raw
    $popupCodeForJob=''
    if($mode -eq 'PopupMessage'){$popupCodeForJob=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'PopupMessaging.cs') -Raw}
    $script:mode=$mode; $script:operationTarget=$t
    $local=$t -in @('.','localhost','127.0.0.1',$env:COMPUTERNAME)
    $script:job=Start-Job -ArgumentList $Worker.ToString(),$mode,$payload,$t,$local,$script:credential,$https.Checked,$popupCodeForJob,$driverCodeForJob -ScriptBlock {
        param($code,$mode,$payload,$target,$local,$credential,$ssl,$popupCode,$driverCode)
        $ErrorActionPreference='Stop'; $block=[scriptblock]::Create($code)
        if($local){ & $block $mode $payload $popupCode $driverCode }
        else {
            $options=New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 180000
            $argsMap=@{ComputerName=$target;ScriptBlock=$block;ArgumentList=@($mode,$payload,$popupCode,$driverCode);SessionOption=$options;ErrorAction='Stop'}
            if($credential){$argsMap.Credential=$credential}; if($ssl){$argsMap.UseSSL=$true}
            Invoke-Command @argsMap
        }
    }
    $top.Enabled=$false; $script:adToolbar.Enabled=$false; Set-Status 'Running {0} on {1} ...' @($mode,$t); $script:started=Get-Date
}
$timer=New-Object Windows.Forms.Timer; $timer.Interval=400
$timer.Add_Tick({
    if(!$script:job){return}
    if($script:job.State -in @('Running','NotStarted')){
        Set-Status 'Running {0} on {1} | {2} seconds' @($script:mode,$script:operationTarget,([int]((Get-Date)-$script:started).TotalSeconds))
        return
    }
    $j=$script:job; $script:job=$null; $top.Enabled=$true; $script:adToolbar.Enabled=$true
    try {
        $result=@(Receive-Job $j -ErrorAction Stop)
        if($j.State -ne 'Completed'){throw (Format-UiText 'The operation did not complete. Check connectivity and permissions, then scan again.')}
        Set-Status 'Finished {0} on {1} | {2}' @($script:mode,$script:operationTarget,(Get-Date -Format T))
        switch($script:mode){
            'Inventory' {
                if($result.Count -ne 1){throw (Format-UiText 'No valid report was received.')}
                $script:inventory=[pscustomobject]@{Target=$script:operationTarget;CollectedAt=(Get-Date -Format o);Data=$result[0]}
                foreach($k in $names.Keys){if($k -ne 'Directory'){FillGrid $k $result[0].$k}}
                Update-Cards $result[0]
                Set-Status 'Computer: {0} | Disks: {1} | Scan errors: {2} | {3}' @($script:operationTarget,@($result[0].Disks).Count,@($result[0].Errors).Count,(Get-Date -Format T))
            }
            'DriverUpdates' {
                if($result.Count -ne 1){throw 'No valid driver report received.'}
                FillGrid 'Connected' $result[0].Devices
                FillGrid 'DriverOffers' $result[0].Updates
                $script:cardValues.Computer.Text=$script:operationTarget
                if($script:inventory -and $script:inventory.Target -eq $script:operationTarget){
                    $script:inventory.Data.Connected=$result[0].Devices
                    $script:inventory | Add-Member -NotePropertyName DriverUpdateCheck -NotePropertyValue $result[0] -Force
                }
                Select-Page 'Connected'
                Set-Status ('Driver check on '+$script:operationTarget+' | '+$result[0].Note)
                Info ($result[0].Note+"`r`nOffered updates: "+@($result[0].Updates).Count+"`r`nSee Devices and drivers and Driver updates offered.")
            }
            'Directory' {
                if($result.Count -ne 1){throw 'No valid directory result received.'}
                $script:adResultServer=$result[0].Server
                FillGrid 'Directory' $result[0].Rows
                Set-Status ('Active Directory | '+$result[0].Server+' | '+$result[0].Note)
                if($script:directoryAction -ne 'Search'){Info $result[0].Note}
            }
            'TempPreview' {
                if($result.Count -ne 1 -or $result[0].Kind -ne 'TempPreview'){throw 'No valid cleanup preview was received.'}
                $preview=$result[0]
                if([long]$preview.FileCount -eq 0){Info 'No temporary files are eligible for deletion (older than 7 days).';break}
                $reference=@{PreviewId=[string]$preview.PreviewId;Hash=[string]$preview.Hash}
                if(Confirm (Format-UiText 'On {0}: delete {1} temporary files totaling {2} MB? Scope: Windows Temp and the execution account Temp folder only. Locked or changed files will be skipped. This preview expires in 15 minutes.' @($script:operationTarget,$preview.FileCount,([math]::Round([double]$preview.Bytes/1MB,2))))){Start-Operation 'TempDelete' $reference}
                else{Start-Operation 'TempDiscard' $reference}
            }
            'TempDiscard' {Set-Status 'Cleanup cancelled. No temporary files were deleted.'}
            default {Info ($result -join "`r`n")}
        }
    } catch { Set-Status 'Unable to complete the operation; see the message'; Info $_.Exception.Message }
    finally {Remove-Job $j -Force -ErrorAction SilentlyContinue; if($script:adPendingPassword){$script:adPendingPassword.Dispose();$script:adPendingPassword=$null}}
})
$form.Add_FormClosing({param($sender,$e) if($script:job){$e.Cancel=$true;Info (Format-UiText 'Wait for the operation to finish before closing; an action may still be running on the remote computer.')}})

# English reading direction and left-side navigation.
$main.SuspendLayout()
$main.ColumnStyles[0].SizeType='Absolute'; $main.ColumnStyles[0].Width=208
$main.ColumnStyles[1].SizeType='Percent'; $main.ColumnStyles[1].Width=100
$main.SetColumn($nav,0); $main.SetColumn($tabs,1)
$tabs.Margin=[Windows.Forms.Padding]::new(10,0,0,0)
$main.ResumeLayout($true)
$tooltips.SetToolTip($popupButton,'Send a popup to active signed-in users on the selected computer; requires messaging permission')
$tooltips.SetToolTip($wake,'Requires Wake-on-LAN enabled and the target computer MAC address')
$tooltips.SetToolTip($trim,'Temporarily trims the selected application working set; does not increase RAM capacity')
$tooltips.SetToolTip($https,'For computers already configured to accept WinRM over HTTPS')

$timer.Start()
try {[void]$form.ShowDialog()} finally { $timer.Stop();$timer.Dispose();$tooltips.Dispose();$form.Dispose();if($script:logoImage){$script:logoImage.Dispose()}}
