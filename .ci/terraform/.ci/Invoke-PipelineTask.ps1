<#
.Synopsis
    Script to use Terraform locally and in Azure DevOps
.DESCRIPTION
    Build:
        Invoke-PipelineTask.ps1 -tfFolderName tf-core-infra -build
    Deploy:
        Invoke-PipelineTask.ps1 -tfFolderName tf-core-infra -deploy
.NOTES
    Name: Invoke-PipelineTask.ps1
    Author: Simon Gottschlag
    Date Created: 2019-11-24
    Version History:
        2019-11-24 - Simon Gottschlag
            Initial Creation


    Xenit AB
#>

[cmdletbinding(DefaultParameterSetName = 'build')]
Param(
    [Parameter(Mandatory = $true, ParameterSetName = 'build')]
    [switch]$build,
    [Parameter(Mandatory = $true, ParameterSetName = 'deploy')]
    [switch]$deploy,
    [Parameter(Mandatory = $true, ParameterSetName = 'destroy')]
    [switch]$destroy,
    [Parameter(Mandatory = $true, ParameterSetName = 'import')]
    [switch]$import,
    [Parameter(Mandatory = $false, ParameterSetName = 'build')]
    [Parameter(Mandatory = $false, ParameterSetName = 'deploy')]
    [Parameter(Mandatory = $false, ParameterSetName = 'destroy')]
    [Parameter(Mandatory = $false, ParameterSetName = 'import')]
    [switch]$azureDevOps,
    [Parameter(Mandatory = $true, ParameterSetName = 'build')]
    [Parameter(Mandatory = $true, ParameterSetName = 'deploy')]
    [Parameter(Mandatory = $true, ParameterSetName = 'destroy')]
    [Parameter(Mandatory = $true, ParameterSetName = 'import')]
    [string]$tfFolderName,
    [Parameter(Mandatory = $false, ParameterSetName = 'build')]
    [Parameter(Mandatory = $false, ParameterSetName = 'deploy')]
    [Parameter(Mandatory = $false, ParameterSetName = 'destroy')]
    [Parameter(Mandatory = $true, ParameterSetName = 'import')]
    [string]$tfImportResource,
    [string]$tfVersion = "0.12.19",
    [string]$tfPath = "$($PSScriptRoot)/../$($tfFolderName)/",
    [string]$tfEncPassword,
    [string]$environmentShort = "dev",
    [string]$artifactPath,
    [bool]$createStorageAccount = $true,
    [string]$tfBackendKey = "$($environmentShort).terraform.tfstate",
    [string]$tfBackendResourceGroupLocation = "West Europe",
    [string]$tfBackendResourceGroupLocationShort = "we",
    [string]$tfBackendResourceGroup = "rg-$($environmentShort)-$($tfBackendResourceGroupLocationShort)-team1",
    [string]$tfBackendStorageAccountName = "strg$($environmentShort)$($tfBackendResourceGroupLocationShort)t1tfstate",
    [string]$tfBackendStorageAccountKind = "StorageV2",
    [string]$tfBackendContainerName = "tfstate-$($tfFolderName)"
)

Begin {
    $ErrorActionPreference = "Stop"

    # Function to retrun error code correctly from binaries
    function Invoke-Call {
        param (
            [scriptblock]$ScriptBlock,
            [string]$ErrorAction = $ErrorActionPreference,
            [switch]$SilentNoExit        
        )
        if ($SilentNoExit) {
            & @ScriptBlock 2>$null
        }
        else {
            & @ScriptBlock

            if (($lastexitcode -ne 0) -and $ErrorAction -eq "Stop") {
                exit $lastexitcode
            }
        }
    }

    function Log-Message {
        Param(
            [string]$message,
            [switch]$header
        )

        if ($header) {
            Write-Output ""
            Write-Output "=============================================================================="
        }
        else {
            Write-Output ""
            Write-Output "---"
        }
        Write-Output $message
        if ($header) {
            Write-Output "=============================================================================="
            Write-Output ""
        }
        else {
            Write-Output "---"
            Write-Output ""
        }
    }

    if (!$($artifactPath)) {
        if (!($ENV:IsWindows) -or $($ENV:IsWindows) -eq $false) {
            $artifactPath = "/tmp/$($environmentShort)-$($tfFolderName)-terraform-output"
        }
        else {
            $artifactPath = "$($ENV:TMP)\$($environmentShort)-$($tfFolderName)-terraform-output"
        }
        if (!$(Test-Path $artifactPath)) {
            New-Item -Path $artifactPath -ItemType Directory | Out-Null
            Log-Message -message "INFO: artifactPath ($($artifactPath)) created."
        }
        else {
            Log-Message -message "INFO: artifactPath ($($artifactPath)) already exists."
        }
    }

    $tfPlanFile = "$($artifactPath)/$($environmentShort).tfplan"
    if ($tfEncPassword -or $ENV:tfEncPassword) {
        $tfPlanEncryption = $true
        $opensslBin = $(Get-Command openssl -ErrorAction Stop)
        if (!$tfEncPassword) {
            $tfEncPassword = $ENV:tfEncPassword
        }
        $opensslVersionRaw = Invoke-Call ([ScriptBlock]::Create("$opensslBin version")) -split " "
        $opensslVersionRaw = ($opensslVersionRaw -split " ")[1] -replace "[^0-9.]"
        $opensslVersion = [version]$opensslVersionRaw
    }

}
Process {
    Set-Location -Path $tfPath -ErrorAction Stop

    if ($azureDevOps) {
        Log-Message -message "INFO: Running Azure DevOps specific configuration"
        # Download and extract Terraform
        Invoke-WebRequest -Uri "https://releases.hashicorp.com/terraform/$($tfVersion)/terraform_$($tfVersion)_linux_amd64.zip" -OutFile "/tmp/terraform_$($tfVersion)_linux_amd64.zip"
        Expand-Archive -Force -Path "/tmp/terraform_$($tfVersion)_linux_amd64.zip" -DestinationPath "/tmp"
        $tfBin = "/tmp/terraform"
        $chmodBin = $(Get-Command chmod -ErrorAction Stop)
        Invoke-Call ([ScriptBlock]::Create("$chmodBin +x $tfBin"))
        Log-Message -message "INFO: Using Terraform version $($tfVersion) from $($tfBin)"

        # Configure environment variables for Terraform
        $azBin = $(Get-Command az -ErrorAction Stop)
        $Subscriptions = Invoke-Call ([ScriptBlock]::Create("$azBin account list --output json")) | ConvertFrom-Json
        foreach ($Subscription in $Subscriptions) {
            if ($Subscription.isDefault) {
                $ENV:ARM_SUBSCRIPTION_ID = $Subscription.id
            }
        }
        $ENV:ARM_CLIENT_ID = $ENV:servicePrincipalId
        $ENV:ARM_CLIENT_SECRET = $ENV:servicePrincipalKey
        $ENV:ARM_TENANT_ID = $ENV:tenantId

        if ($createStorageAccount) {
            $createRg = Invoke-Call ([ScriptBlock]::Create("$azBin group create --name `"$($tfBackendResourceGroup)`" --location `"$($tfBackendResourceGroupLocation)`" --output json")) | ConvertFrom-Json
            if ($createRg.properties.provisioningState -eq "Succeeded") {
                Log-Message -message "INFO: Azure Resource Group $($tfBackendResourceGroup) successfully provisioned in $($tfBackendResourceGroupLocation)."
            }
            else {
                Log-Message -message "ERROR: Azure Resource Group $($tfBackendResourceGroup) failed to provision in $($tfBackendResourceGroupLocation)."
                exit 1
            }

            $createStrg = Invoke-Call ([ScriptBlock]::Create("$azBin storage account create --resource-group `"$($tfBackendResourceGroup)`" --name `"$($tfBackendStorageAccountName)`" --kind `"$($tfBackendStorageAccountKind)`" --output json")) | ConvertFrom-Json
            if ($createStrg.provisioningState -eq "Succeeded") {
                Log-Message -message "INFO: Azure Storage Account $($tfBackendStorageAccountName) successfully provisioned in resource group $($tfBackendResourceGroup)."
            }
            else {
                Log-Message -message "ERROR: Azure Storage Account $($tfBackendStorageAccountName) failed to provision in resource group $($tfBackendResourceGroup)."
                exit 1
            }

            $createContainer = Invoke-Call ([ScriptBlock]::Create("$azBin storage container create --account-name `"$($tfBackendStorageAccountName)`" --name `"$($tfBackendContainerName)`" --output json")) | ConvertFrom-Json
            if ($createContainer.created -eq $true) {
                Log-Message -message "INFO: Azure Storage Account Container $($tfBackendContainerName) created in $($tfBackendStorageAccountName)."
            }
            else {
                Log-Message -message "INFO: Azure Storage Account Container $($tfBackendContainerName) already exists in $($tfBackendStorageAccountName)."
            }
        }

    }
    else {
        try {
            $tfBin = $(Get-Command terraform -ErrorAction Stop)
        }
        catch {
            Write-Error "Terraform isn't installed"
        }
    }

    switch ($PSCmdlet.ParameterSetName) {
        'build' {
            Log-Message -message "START: Build" -header
            try {
                Log-Message -message "START: terraform init"
                Invoke-Call ([ScriptBlock]::Create("$tfBin init -input=false -backend-config `"key=$($tfBackendKey)`" -backend-config=`"resource_group_name=$($tfBackendResourceGroup)`" -backend-config=`"storage_account_name=$($tfBackendStorageAccountName)`" -backend-config=`"container_name=$($tfBackendContainerName)`""))
                try {
                    Invoke-Call ([ScriptBlock]::Create("$tfBin workspace new $($environmentShort)")) -SilentNoExit
                    Log-Message -message "INFO: terraform workspace $($environmentShort) created"
                }
                catch {
                    Log-Message -message "INFO: terraform workspace $($environmentShort) already exists"
                }
                Log-Message -message "INFO: terraform workspace $($environmentShort) selected"
                Invoke-Call ([ScriptBlock]::Create("$tfBin workspace select $($environmentShort)"))
                Log-Message -message "END: terraform init"

                Log-Message -message "START: terraform validate"
                Invoke-Call ([ScriptBlock]::Create("$tfBin validate"))
                Log-Message -message "END: terraform validate"

                Log-Message -message "START: terraform plan"
                Invoke-Call ([ScriptBlock]::Create("$tfBin plan -input=false -var-file=`"variables/$($environmentShort).tfvars`" -var-file=`"variables/common.tfvars`" -out=`"$($tfPlanFile)`""))
                Log-Message -message "END: terraform plan"

                if ($tfPlanEncryption) {
                    Log-Message -message "START: Encrypt terraform plan"
                    if ($opensslVersion -ge [version]"1.1.1") {
                        Invoke-Call ([ScriptBlock]::Create("$opensslBin enc -aes-256-cbc -md sha512 -pbkdf2 -iter 1000 -a -salt -in `"$($tfPlanFile)`" -out `"$($tfPlanFile).enc`" -k `"$($tfEncPassword)`""))
                    }
                    else {
                        Invoke-Call ([ScriptBlock]::Create("$opensslBin enc -aes-256-cbc -md sha512 -a -salt -in `"$($tfPlanFile)`" -out `"$($tfPlanFile).enc`" -k `"$($tfEncPassword)`""))
                    }
                    Remove-Item -Force -Path $tfPlanFile | Out-Null
                    Log-Message -message "END: Encrypt terraform plan"
                }

            }
            catch {
                $ErrorMessage = $_.Exception.Message
                $FailedItem = $_.Exception.ItemName
                Write-Error "Message: $ErrorMessage`r`nItem: $FailedItem"
                exit 1
            }
            Log-Message -message "END: Build" -header
        }
        'deploy' {
            Log-Message -message "START: Deploy" -header
            try {
                Log-Message -message "START: terraform init"
                Invoke-Call ([ScriptBlock]::Create("$tfBin init -input=false -backend-config `"key=$($tfBackendKey)`" -backend-config=`"resource_group_name=$($tfBackendResourceGroup)`" -backend-config=`"storage_account_name=$($tfBackendStorageAccountName)`" -backend-config=`"container_name=$($tfBackendContainerName)`""))
                try {
                    Invoke-Call ([ScriptBlock]::Create("$tfBin workspace new $($environmentShort)")) -SilentNoExit
                    Log-Message -message "INFO: terraform workspace $($environmentShort) created"
                }
                catch {
                    Log-Message -message "INFO: terraform workspace $($environmentShort) already exists"
                }
                Log-Message -message "INFO: terraform workspace $($environmentShort) selected"
                Invoke-Call ([ScriptBlock]::Create("$tfBin workspace select $($environmentShort)"))
                Log-Message -message "END: terraform init"

                if ($tfPlanEncryption) {
                    Log-Message -message "START: Decrypt terraform plan"
                    if ($opensslVersion -ge [version]"1.1.1") {
                        Invoke-Call ([ScriptBlock]::Create("$opensslBin enc -aes-256-cbc -md sha512 -pbkdf2 -iter 1000 -a -d -salt -in `"$($tfPlanFile).enc`" -out `"$($tfPlanFile)`" -k `"$($tfEncPassword)`""))
                    }
                    else {
                        Invoke-Call ([ScriptBlock]::Create("$opensslBin enc -aes-256-cbc -md sha512 -a -d -salt -in `"$($tfPlanFile).enc`" -out `"$($tfPlanFile)`" -k `"$($tfEncPassword)`""))
                    }
                    Log-Message -message "END: Decrypt terraform plan"
                }

                Log-Message -message "START: terraform apply"
                Invoke-Call ([ScriptBlock]::Create("$tfBin apply -input=false -auto-approve `"$($tfPlanFile)`""))
                Log-Message -message "END: terraform apply"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                $FailedItem = $_.Exception.ItemName
                Write-Error "Message: $ErrorMessage`r`nItem: $FailedItem"
                exit 1
            }
            Log-Message -message "END: Deploy" -header
        }
        'destroy' {
            Log-Message -message "START: Destroy" -header
            try {
                Log-Message -message "START: terraform init"
                Invoke-Call ([ScriptBlock]::Create("$tfBin init -input=false -backend-config `"key=$($tfBackendKey)`" -backend-config=`"resource_group_name=$($tfBackendResourceGroup)`" -backend-config=`"storage_account_name=$($tfBackendStorageAccountName)`" -backend-config=`"container_name=$($tfBackendContainerName)`""))
                try {
                    Invoke-Call ([ScriptBlock]::Create("$tfBin workspace new $($environmentShort)")) -SilentNoExit
                    Log-Message -message "INFO: terraform workspace $($environmentShort) created"
                }
                catch {
                    Log-Message -message "INFO: terraform workspace $($environmentShort) already exists"
                }
                Log-Message -message "INFO: terraform workspace $($environmentShort) selected"
                Invoke-Call ([ScriptBlock]::Create("$tfBin workspace select $($environmentShort)"))
                Log-Message -message "END: terraform init"

                Log-Message -message "START: terraform destroy"
                Log-Message -message "INFO: Manual input required"
                $destroyConfirmation = Read-Host -Prompt "Continue and destroy $($tfFolderName) (environment: $($environmentShort))? [y/n]"
                if ( $destroyConfirmation -match "[yY]" ) { 
                    Invoke-Call ([ScriptBlock]::Create("$tfBin destroy -var-file=`"variables/$($environmentShort).tfvars`" -var-file=`"variables/common.tfvars`""))
                }
                Log-Message -message "END: terraform destroy"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                $FailedItem = $_.Exception.ItemName
                Write-Error "Message: $ErrorMessage`r`nItem: $FailedItem"
                exit 1
            }
            Log-Message -message "END: Deploy" -header
        }
        'import' {
            Log-Message -message "START: Destroy" -header
            try {
                Log-Message -message "START: terraform init"
                Invoke-Call ([ScriptBlock]::Create("$tfBin init -input=false -backend-config `"key=$($tfBackendKey)`" -backend-config=`"resource_group_name=$($tfBackendResourceGroup)`" -backend-config=`"storage_account_name=$($tfBackendStorageAccountName)`" -backend-config=`"container_name=$($tfBackendContainerName)`""))
                try {
                    Invoke-Call ([ScriptBlock]::Create("$tfBin workspace new $($environmentShort)")) -SilentNoExit
                    Log-Message -message "INFO: terraform workspace $($environmentShort) created"
                }
                catch {
                    Log-Message -message "INFO: terraform workspace $($environmentShort) already exists"
                }
                Log-Message -message "INFO: terraform workspace $($environmentShort) selected"
                Invoke-Call ([ScriptBlock]::Create("$tfBin workspace select $($environmentShort)"))
                Log-Message -message "END: terraform init"

                Log-Message -message "START: terraform import"
                Invoke-Call ([ScriptBlock]::Create("$tfBin import -var-file=`"variables/$($environmentShort).tfvars`" -var-file=`"variables/common.tfvars`" $($tfImportResource)"))
                Log-Message -message "END: terraform import"
            }
            catch {
                $ErrorMessage = $_.Exception.Message
                $FailedItem = $_.Exception.ItemName
                Write-Error "Message: $ErrorMessage`r`nItem: $FailedItem"
                exit 1
            }
            Log-Message -message "END: Deploy" -header
        }
        default {
            Write-Error "No options chosen."
            exit 1
        }
    }
}
End {
    
}