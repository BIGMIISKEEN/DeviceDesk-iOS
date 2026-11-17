# Directory operations run on the operator PC using its RSAT module, not through the device target.
function ConvertTo-LdapLiteral([string]$Value) {
    return $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
}
function Invoke-DirectoryOperation($Request,$Credential) {
    if([string]$Request.Server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.\-]{0,252}$'){throw 'Enter your AD domain DNS name or domain controller.'}
    if(!(Get-Module -ListAvailable ActiveDirectory)){throw 'Active Directory tools are missing on this PC. Install RSAT: Active Directory Domain Services and Lightweight Directory Services Tools from Windows Optional features, then restart DeviceDesk.'}
    Import-Module ActiveDirectory -ErrorAction Stop
    $connection=@{Server=[string]$Request.Server;ErrorAction='Stop'}
    if($Credential){$connection.Credential=$Credential}
    # Pin this request and subsequent actions to the responding DC, even if a domain name was entered.
    $dc=Get-ADRootDSE @connection
    $connection.Server=[string]$dc.dnsHostName
    if([string]::IsNullOrWhiteSpace($connection.Server)){throw 'The domain controller did not return its DNS name.'}
    if($Request.Action -eq 'Search') {
        $text=([string]$Request.Query).Trim()
        if($text.Length -lt 2 -or $text.Length -gt 128){throw 'Enter 2 to 128 characters to search.'}
        $escaped=ConvertTo-LdapLiteral $text
        if($Request.Kind -eq 'Users') {
            $rows=@(Get-ADUser @connection -LDAPFilter "(|(sAMAccountName=*$escaped*)(displayName=*$escaped*)(userPrincipalName=*$escaped*))" -ResultSetSize 201 -Properties DisplayName,Mail,Department,Title,LockedOut,PasswordLastSet,AccountExpirationDate,LastLogonDate |
                Select-Object @{n='Kind';e={'User'}},Name,SamAccountName,DisplayName,Enabled,LockedOut,UserPrincipalName,Mail,Department,Title,PasswordLastSet,AccountExpirationDate,LastLogonDate,DistinguishedName,@{n='ObjectGUID';e={$_.ObjectGUID.ToString()}})
        } elseif($Request.Kind -eq 'Computers') {
            $rows=@(Get-ADComputer @connection -LDAPFilter "(|(name=*$escaped*)(dNSHostName=*$escaped*))" -ResultSetSize 201 -Properties DNSHostName,OperatingSystem,OperatingSystemVersion,LastLogonDate,Description |
                Select-Object @{n='Kind';e={'Computer'}},Name,SamAccountName,Enabled,DNSHostName,OperatingSystem,OperatingSystemVersion,LastLogonDate,Description,DistinguishedName,@{n='ObjectGUID';e={$_.ObjectGUID.ToString()}})
        } else {throw 'Select Users or Computers.'}
        return [pscustomobject]@{Rows=@($rows | Select-Object -First 200); Server=$connection.Server; Note=$(if($rows.Count -gt 200){'Showing the first 200 results. Refine your search.'}else{[string]$rows.Count+' results.'})}
    }
    if($Request.Action -notin @('Unlock','ResetPassword')){throw 'Unsupported directory action.'}
    $guid=[guid]::Parse([string]$Request.ObjectGUID)
    # Resolve again immediately before mutation; never select an account by a partial display name.
    $user=Get-ADUser @connection -Identity $guid -Properties LockedOut
    if($user.DistinguishedName -cne [string]$Request.DistinguishedName -or $user.SamAccountName -cne [string]$Request.SamAccountName){throw 'The account changed since the search. Search again before continuing.'}
    if($Request.Action -eq 'Unlock') {
        Unlock-ADAccount @connection -Identity $guid -Confirm:$false
        $after=Get-ADUser @connection -Identity $guid -Properties LockedOut
        return [pscustomobject]@{Note=('Unlock requested for '+$user.SamAccountName+'. LockedOut now: '+[string]$after.LockedOut); Rows=@(); Server=$connection.Server}
    }
    if($Request.Password -isnot [Security.SecureString] -or $Request.Password.Length -eq 0){throw 'Enter a new password.'}
    Set-ADAccountPassword @connection -Identity $guid -Reset -NewPassword $Request.Password -Confirm:$false
    $note='Password reset for '+$user.SamAccountName+'.'
    if($Request.ChangeAtLogon) {
        try {Set-ADUser @connection -Identity $guid -ChangePasswordAtLogon $true; $note+=' Password change at next sign-in enabled.'}
        catch {$note+=' The password was reset, but requiring a change at next sign-in FAILED: '+$_.Exception.Message}
    }
    return [pscustomobject]@{Note=$note;Rows=@();Server=$connection.Server}
}
