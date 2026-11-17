# Device inventory and read-only update detection. Runs on the selected computer.
function Get-DriverSupportUrl([string]$Manufacturer) {
    switch -Regex ($Manufacturer) {
        'Dell' {return 'https://www.dell.com/support/home/en-us?app=drivers'}
        'Hewlett|\bHP\b' {return 'https://support.hp.com/us-en/drivers'}
        'Lenovo' {return 'https://pcsupport.lenovo.com/us/en'}
        'Intel' {return 'https://www.intel.com/content/www/us/en/download-center/home.html'}
        'NVIDIA' {return 'https://www.nvidia.com/download/index.aspx/'}
        'AMD|Advanced Micro Devices' {return 'https://www.amd.com/en/support/download/drivers.html'}
        'ASUS|ASUSTeK' {return 'https://www.asus.com/support/download-center/'}
        'Logitech' {return 'https://www.logitech.com/en-us/software'}
        default {return ''}
    }
}
function Get-ConnectedDriverInventory {
    $signed=@{}; Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | ForEach-Object {if($_.DeviceID){$signed[[string]$_.DeviceID]=$_}}
    $entities=@{}; Get-CimInstance Win32_PnPEntity -ErrorAction Stop | ForEach-Object {if($_.DeviceID){$entities[[string]$_.DeviceID]=$_}}
    $system=Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    $oemUrl=Get-DriverSupportUrl $system.Manufacturer
    foreach($p in Get-PnpDevice -PresentOnly -ErrorAction Stop) {
        $id=[string]$p.InstanceId; $d=$signed[$id]; $e=$entities[$id]
        $ids=@(@($e.HardwareID)+@($e.CompatibleID) | Where-Object {$_} | Select-Object -Unique)
        $maker=[string]$e.Manufacturer
        $url=Get-DriverSupportUrl $maker
        if(!$url){$url=Get-DriverSupportUrl ([string]$d.DriverProviderName)}
        [pscustomobject][ordered]@{
            Device=$(if($p.FriendlyName){$p.FriendlyName}else{$id}); Class=[string]$p.Class; Status=[string]$p.Status
            Manufacturer=$maker; DriverVersion=[string]$d.DriverVersion; DriverProvider=[string]$d.DriverProviderName
            DriverDate=$(if($d.DriverDate){([datetime]$d.DriverDate).ToString('yyyy-MM-dd')}else{''})
            INF=[string]$d.InfName; Signed=[string]$d.IsSigned
            UpdateStatus='Not checked'; AvailableUpdates=''; CheckedAt=''
            DeviceSupportURL=$url; ComputerSupportURL=$oemUrl; ComputerModel=[string]$system.Model
            HardwareIDs=($ids -join '; '); InstanceId=$id
        }
    }
}
function Merge-DriverUpdates($Devices,$Updates,[bool]$Complete,[string]$Failure='') {
    $checked=Get-Date -Format o
    foreach($device in $Devices) {
        $ids=@(([string]$device.HardwareIDs -split '; ') | Where-Object {$_})
        $matches=@($Updates | Where-Object {$_.HardwareID -and $_.HardwareID -in $ids})
        $device.CheckedAt=$checked
        $device.AvailableUpdates=($matches | ForEach-Object Title) -join ' | '
        if($matches.Count){$device.UpdateStatus='Update offered'}
        elseif(!$Complete){$device.UpdateStatus='Unknown - scan incomplete: '+$Failure}
        elseif(!$ids.Count){$device.UpdateStatus='Unknown - hardware IDs unavailable'}
        else{$device.UpdateStatus='No update offered by configured source'}
        $device
    }
}
function Get-DriverUpdateReport {
    $devices=@(Get-ConnectedDriverInventory)
    $updates=New-Object 'System.Collections.Generic.List[object]'
    $session=$null; $searcher=$null; $found=$null; $complete=$false; $failure=''; $source='Configured Windows Update source (Windows Update / managed WSUS)'
    try {
        $session=New-Object -ComObject Microsoft.Update.Session
        $session.ClientApplicationID='DeviceDesk driver check'
        $searcher=$session.CreateUpdateSearcher(); $searcher.Online=$true
        # Use the existing service and company policy. Do not switch services or install anything.
        $found=$searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        $complete=([int]$found.ResultCode -eq 2)
        if(!$complete){$failure='Windows Update returned result code '+[string]$found.ResultCode}
        for($i=0;$i -lt $found.Updates.Count;$i++) {
            $u=$found.Updates.Item($i)
            try {
                $updates.Add([pscustomobject][ordered]@{Title=[string]$u.Title; HardwareID=[string]$u.DriverHardwareID; Provider=[string]$u.DriverProvider; Model=[string]$u.DriverModel; DriverDate=([datetime]$u.DriverVerDate).ToString('yyyy-MM-dd'); Source=$source; UpdateID=[string]$u.Identity.UpdateID})
            } finally {if([Runtime.InteropServices.Marshal]::IsComObject($u)){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($u)}}
        }
    } catch {$failure=$_.Exception.Message; $complete=$false}
    finally {foreach($com in @($found,$searcher,$session)){if($null -ne $com -and [Runtime.InteropServices.Marshal]::IsComObject($com)){[void][Runtime.InteropServices.Marshal]::ReleaseComObject($com)}}}
    $rows=@(Merge-DriverUpdates $devices $updates.ToArray() $complete $failure)
    [pscustomobject]@{Devices=$rows; Updates=$updates.ToArray(); Complete=$complete; Note=$(if($complete){'Scan finished. No update offered does not guarantee the newest vendor release. Company policy may restrict the catalog.'}else{'Update status is unknown or partial. '+$failure}); Source=$source}
}
