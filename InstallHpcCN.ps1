<#
    The script to install HPC Pack compute node
    Author :  Microsoft HPC Pack team
    Version:  1.0
#>
Param
(
    [parameter(Mandatory = $true)]
    [string] $ClusterConnectionString,

    [parameter(Mandatory = $true)]
    [string] $CertThumbprint
)

# Must disable Progress bar
$ProgressPreference = "SilentlyContinue"
$ErrorActionPreference = "Stop"
Set-StrictMode -Version latest
$curTimeStr = Get-Date -Format "yyyyMMdd-HHmmss"
$Script:LogFile = "C:\Windows\Temp\HPCComputeNode-${curTimeStr}.log"

function Write-Log
{
    param(
        [Parameter(Mandatory=$true, Position=0, ValueFromPipeline=$true)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Mandatory=$false, Position=1)]
        [ValidateSet("Error", "Warning", "Information", "Detail")]
        [string]$LogLevel = "Information"
    )

    $formattedMessage = '[{0:s}][{1}] {2}' -f ([DateTimeOffset]::Now.ToString('u')), $LogLevel, $Message
    Write-Verbose -Verbose "${formattedMessage}"
    if($Script:LogFile)
    {
        try
        {
            $formattedMessage | Out-File $Script:LogFile -Append
        }
        catch
        {
        }
    }

    if($LogLevel -eq "Error")
    {
        throw $Message
    }
}

$pfxCert = Get-Item Cert:\LocalMachine\My\$CertThumbprint -ErrorAction SilentlyContinue
if ($null -eq $pfxCert) {
    Write-Log "The certificate Cert:\LocalMachine\My\$CertThumbprint doesn't exist" -LogLevel Error
}

if ($pfxCert.Subject -eq $pfxCert.Issuer) {
    if (-not (Test-Path Cert:\LocalMachine\Root\$CertThumbprint)) {
        Write-Log "Installing self-signed HPC communication certificate to Cert:\LocalMachine\Root\$CertThumbprint"
        $cerFileName = "$env:Temp\HpcPackComm.cer"
        Export-Certificate -Cert "Cert:\LocalMachine\My\$CertThumbprint" -FilePath $cerFileName | Out-Null
        Import-Certificate -FilePath $cerFileName -CertStoreLocation Cert:\LocalMachine\Root  | Out-Null
        Remove-Item $cerFileName -Force -ErrorAction SilentlyContinue
    }
}

$hpcRegKey = Get-Item HKLM:\SOFTWARE\Microsoft\HPC -ErrorAction SilentlyContinue
if ($hpcRegKey -and ("ClusterConnectionString" -in $hpcRegKey.Property)) {
    $curClusConnStr = ($hpcRegKey | Get-ItemProperty | Select-Object -Property ClusterConnectionString).ClusterConnectionString
    if ($curClusConnStr -eq $ClusterConnectionString) {
        Write-Log "HPC Pack compute node already installed"
    }
}

$randomNum = Get-Random
$setupDir = "C:\Windows\Temp\$randomNum"
New-Item -Path $setupDir -ItemType Directory -Force
$headNodes = $ClusterConnectionString.Split(",")
foreach($hn in $headNodes)
{
    if(Test-Path "\\$hn\REMINST\Setup\HpcCompute_x64.msi") {
        Copy-Item -Path "\\$hn\REMINST\amd64\SSCERuntime_x64-ENU.exe" -Destination $setupDir -Force
        Copy-Item -Path "\\$hn\REMINST\MPI\MSMpiSetup.exe" -Destination $setupDir -Force
        Copy-Item -Path "\\$hn\REMINST\Setup\HpcCompute_x64.msi" -Destination $setupDir -Force
        break
    }    
}

$exitCode = -1
$nonDomainJoin = 1
$computerSystemObj = Get-WmiObject Win32_ComputerSystem
if ($computerSystemObj.PartOfDomain) {
    $nonDomainJoin = 0
}

if (-not (Test-Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server Compact Edition\v4.0\ENU")) {
    $ssceFilePath = Join-Path -Path $setupDir -ChildPath 'SSCERuntime_x64-ENU.exe'
    if (Test-Path $ssceFilePath -PathType Leaf) {
        $sqlceLogFile = "C:\Windows\Temp\SqlCompactInstallLogX64.log"
        $p = Start-Process -FilePath $ssceFilePath -ArgumentList "/i /passive /l*v `"$sqlceLogFile`"" -Wait -PassThru
        Write-Log "Sql Server Compact installation finished with exit code $($p.ExitCode)."
    }
}
$timeStamp = Get-Date -Format "yyyy_MM_dd-hh_mm_ss"
$mpiFilePath = Join-Path -Path $setupDir -ChildPath 'MsMpiSetup.exe'
if (Test-Path $mpiFilePath -PathType Leaf) {
    $mpiLogFile = "C:\Windows\Temp\msmpi-$timeStamp.log"
    Start-Process -FilePath $mpiFilePath -ArgumentList "/unattend /force /minimal /log `"$mpiLogFile`" /verbose" -Wait
}

$timeStamp = Get-Date -Format "yyyy_MM_dd-hh_mm_ss"
$cnLogFile = "C:\Windows\Temp\hpccompute-$timeStamp.log"
$setupArgs = "REBOOT=ReallySuppress CLUSTERCONNSTR=`"$ClusterConnectionString`" SSLTHUMBPRINT=`"$CertThumbprint`" NONDOMAINJOIN=`"#$nonDomainJoin`""
$p = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$SetupFilePath`" $setupArgs /quiet /norestart /l+v* `"$cnLogFile`"" -Wait -PassThru
$exitCode = $p.ExitCode
Write-Log "HPC compute node installation finished with exit code $exitCode."
if ($exitCode -eq 3010) {
    Write-Log "A system reboot is required after HPC compute node installation."
}

exit $exitCode
