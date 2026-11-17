$ErrorActionPreference='Stop'
$folder=Join-Path $PSScriptRoot '../WindowsBridge'
foreach($file in Get-ChildItem $folder -Recurse -Filter '*.ps1') {
    $tokens=$null;$errors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if($errors.Count){throw ($errors | Out-String)}
    foreach($assignment in $ast.FindAll({param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst]},$true)) {
        if($assignment.Left -is [System.Management.Automation.Language.VariableExpressionAst]){
            $name=$assignment.Left.VariablePath.UserPath -replace '^.*:',''
            if($name -in @('HOME','PID','PSHOME','Host','ExecutionContext')){throw "Reserved variable assignment: $name"}
        }
    }
}
Write-Host 'PASS: all bridge PowerShell sources parse; no reserved-variable assignments.'
