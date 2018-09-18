<##################################################################################################

    Description
    ===========

    Create a Lab Environment using the provided ARM template.

    Coming soon / planned work
    ==========================

    - N/A.    

##################################################################################################>

#
# Parameters to this script file.
#

[CmdletBinding()]
param(
    [string] $ConnectedServiceName,
    [string] $LabId,
    [string] $RepositoryId,
    [string] $TemplateId,
    [string] $EnvironmentName,
    [string] $EnvironmentParameterFile,
    [string] $EnvironmentParameterOverrides,
    [string] $EnvironmentTemplateOutputVariables,
    [string] $LocalTemplateName,
    [string] $LocalParameterFile,
    [string] $LocalParameterOverrides,
    [string] $LocalTemplateOutputVariables
)

###################################################################################################

#
# Required modules.
#

Import-Module Microsoft.TeamFoundation.DistributedTask.Task.Common
Import-Module Microsoft.TeamFoundation.DistributedTask.Task.Internal

###################################################################################################

#
# PowerShell configurations
#

# NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
#       This is necessary to ensure we capture errors inside the try-catch-finally block.
$ErrorActionPreference = "Stop"

# Ensure we set the working directory to that of the script.
Push-Location $PSScriptRoot

###################################################################################################

#
# Functions used in this script.
#

.".\task-funcs.ps1"

###################################################################################################

#
# Handle all errors in this script.
#

trap
{
    # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
    #       script, unless you want to ignore a specific error.

    $message = $error[0].Exception.Message
    
    if ($message) {
        Write-Error "`n$message"
    }
}

###################################################################################################

#
# Main execution block.
#

[string] $environmentResourceId = ''
[string] $environmentResourceGroupId = ''

try
{
    $OptionalParameters = @{}

    Write-Host 'Starting Azure DevTest Labs Create and Populate Environment Task'

    Show-InputParameters

    $parameterSet = Get-ParameterSet -templateId $TemplateId -path $EnvironmentParameterFile -overrides $EnvironmentParameterOverrides
    $OptionalParameter = ConvertTo-Optionals -overrideParameters $LocalParameterOverrides
    
    Show-TemplateParameters -templateId $TemplateId -parameters $parameterSet

    $environmentResourceId = New-DevTestLabEnvironment -labId $LabId -templateId $TemplateId -environmentName $EnvironmentName -environmentParameterSet $parameterSet

    Write-Host "A: $environmentResourceId"

    $environmentResourceGroupId = Get-DevTestLabEnvironmentResourceGroupId -environmentResourceId $environmentResourceId

    Write-Host "B: $environmentResourceGroupId"

    $environmentResourceGroupName = $environmentResourceGroupId.Split('/')[4]
    Write-Host "C: $environmentResourceGroupName"

    $environmentResourceGroupLocation = Get-DevTestLabEnvironmentResourceGroupLocation -environmentResourceId $environmentResourceId
    Write-Host "D: $environmentResourceGroupLocation"
    
    #Create storage and copy files up
    $StorageContainerName = $environmentResourceGroupName.ToLowerInvariant() + '-stageartifacts'
    $StorageAccountName = 'stage' + ((Get-AzureRmContext).Subscription.SubscriptionId).Replace('-', '').substring(0, 19)
    $StorageAccount = New-AzureRmStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $environmentResourceGroupName -Location $environmentResourceGroupLocation
    New-AzureStorageContainer -Name $StorageContainerName -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1

    Write-Host "E: $StorageAccount"

    $localRootDir = Split-Path $LocalTemplateName
    $rootFile = Split-Path $LocalTemplateName -Leaf


    $localFilePaths = Get-ChildItem $localRootDir -Recurse -File | ForEach-Object -Process {$_.FullName}
    foreach ($SourcePath in $localFilePaths) {
        Set-AzureStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($localRootDir.length + 1) `
            -Container $StorageContainerName -Context $StorageAccount.Context -Force
        Write-Host "F: $SourcePath"
    }

    $OptionalParameters.$ArtifactsLocationName = $StorageAccount.Context.BlobEndPoint + $StorageContainerName
    Write-Host "G: $OptionalParameters"

    # Generate a 4 hour SAS token for the artifacts location if one was not provided in the parameters file
    $OptionalParameters.$ArtifactsLocationSasTokenName = ConvertTo-SecureString -AsPlainText -Force `
       (New-AzureStorageContainerSASToken -Container $StorageContainerName -Context $StorageAccount.Context -Permission r -ExpiryTime (Get-Date).AddHours(4))
    
    Write-Host "H: $OptionalParameters"

    # Update RG
    $localDeploymentOutput = New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $rootFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                       -ResourceGroupName $environmentResourceGroupName `
                                       -TemplateFile $StorageAccount.Context.BlobEndPoint + $StorageContainerName + $rootFile `
                                       -TemplateParameterFile $EnvironmentParameterFile `
                                       @OptionalParameters `
                                       -Force

    Write-Host "I: $localDeploymentOutput"
    Write-Host "Z: Remove storage"
    Remove-AzureRmStorageAccount -ResourceGroupName $environmentResourceGroupName -Name $StorageAccountName -Force
    Write-Host "Post Remove"
        
    if ([System.Xml.XmlConvert]::ToBoolean($EnvironmentTemplateOutputVariables))
    {
        $environmentDeploymentOutput = [hashtable] (Get-DevTestLabEnvironmentOutput -environmentResourceId $environmentResourceId) 
        $environmentDeploymentOutput.Keys | ForEach-Object {
            if(Test-DevTestLabEnvironmentOutputIsSecret -templateId $TemplateId -key $_) {
                Write-Host "##vso[task.setvariable variable=$_;isSecret=true;isOutput=true;]$($environmentDeploymentOutput[$_])"
            } else {
                Write-Host "##vso[task.setvariable variable=$_;isSecret=false;isOutput=true;]$($environmentDeploymentOutput[$_])"
            }   
        }
    }
}
finally
{
    if (-not [string]::IsNullOrWhiteSpace($environmentResourceId))
    {
        Write-Host "##vso[task.setvariable variable=environmentResourceId;isSecret=false;isOutput=true;]$environmentResourceId"
    }

    if (-not [string]::IsNullOrWhiteSpace($environmentResourceGroupId))
    {
        Write-Host "##vso[task.setvariable variable=environmentResourceGroupId;isSecret=false;isOutput=true;]$environmentResourceGroupId"
    }

    Write-Host 'Completing Azure DevTest Labs Create Environment Task'
    Pop-Location
}