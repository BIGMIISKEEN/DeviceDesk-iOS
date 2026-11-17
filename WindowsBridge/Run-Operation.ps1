#requires -Version 5.1
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::InputEncoding=[Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
try {
    $request=[Console]::In.ReadToEnd() | ConvertFrom-Json
    $engine=Join-Path $PSScriptRoot 'Engine'
    . (Join-Path $engine 'DeviceDesk.ps1') -ValidateOnly
    $action=[string]$request.Action
    if($action -in @('DirectorySearch','DirectoryUnlock','DirectoryResetPassword')) {
        . (Join-Path $engine 'DirectoryTools.ps1')
        $payload=@{}
        foreach($property in $request.Payload.PSObject.Properties){$payload[$property.Name]=$property.Value}
        $payload.Server=[string]$request.DirectoryServer
        $payload.Action=@{DirectorySearch='Search';DirectoryUnlock='Unlock';DirectoryResetPassword='ResetPassword'}[$action]
        if($action -eq 'DirectoryResetPassword'){$payload.Password=ConvertTo-SecureString ([string]$payload.Password) -AsPlainText -Force}
        try {$data=Invoke-DirectoryOperation $payload $null} finally {if($payload.Password -is [Security.SecureString]){$payload.Password.Dispose()};$payload.Clear()}
    } else {
        if($action -notin @('Inventory','DriverUpdates','PopupMessage','TempPreview','TempDelete','TempDiscard','Restart','Trim')){throw 'Unsupported operation'}
        $target=[string]$request.Target
        if($target -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]{0,252}$'){throw 'Invalid target'}
        $driverCode=Get-Content (Join-Path $engine 'DriverTools.ps1') -Raw
        $popupCode=Get-Content (Join-Path $engine 'PopupMessaging.cs') -Raw
        if($target -ieq $env:COMPUTERNAME -or $target -ieq 'localhost'){
            $data=& $Worker $action $request.Payload $popupCode $driverCode
        } else {
            $arguments=@{ComputerName=$target;ScriptBlock=$Worker;ArgumentList=@($action,$request.Payload,$popupCode,$driverCode);SessionOption=(New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 900000);ErrorAction='Stop'}
            if($request.WinRMHTTPS){$arguments.UseSSL=$true}
            $data=Invoke-Command @arguments
        }
    }
    [Console]::WriteLine((@{ok=$true;data=$data} | ConvertTo-Json -Depth 16 -Compress))
    exit 0
} catch {
    # Do not serialize exception records; they can include password-bearing input.
    [Console]::WriteLine('{"ok":false,"error":"Operation failed"}')
    exit 1
}
