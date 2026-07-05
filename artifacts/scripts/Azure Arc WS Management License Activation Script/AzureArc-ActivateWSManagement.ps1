# Define parameters
param (
    [string]$SubscriptionId,
    [string]$ResourceGroupName,    
    [string]$CsvPath   
)

# Connect to Azure and set the subscription
$account = Connect-AzAccount 
$context = Set-AzContext -Subscription $SubscriptionId 

# Get the access token
$profile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile 
$profileClient = [Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient]::new( $profile ) 
$token = $profileClient.AcquireAccessToken($context.Subscription.TenantId) 
$header = @{ 
    'Content-Type'='application/json' 
    'Authorization'='Bearer ' + $token.AccessToken 
}


# Get Azure Arc machines
$arcMachines = Get-AzConnectedMachine -ResourceGroupName $ResourceGroupName

# Initialize an array to store machine data
$machineData = @()

foreach ($machine in $arcMachines) {
    $licenseProfileUri = "https://management.azure.com$($machine.Id)/licenseProfiles/default?api-version=2023-10-03-preview"

    try {
        # Check current license status
        $response = Invoke-RestMethod -Method GET -Uri $licenseProfileUri -Headers $header
        $licenseStatus = $response.properties.softwareAssurance.softwareAssuranceCustomer
        $operationResult = "Already enabled"
    } catch {
        $licenseStatus = "Unknown"
        $operationResult = "Error occurred: $($_.Exception.Message)"
    }

    # Add data to the list
    $machineData += [PSCustomObject]@{
        MachineName   = $machine.Name
        LicenseStatus = $licenseStatus
        Operation     = $operationResult
    }
}

# Save the initial data to a CSV file
$machineData | Export-Csv -Path $CsvPath -NoTypeInformation
Write-Host "Machine list and license status saved to CSV: $csvPath"

# Read the CSV file and enable license if not enabled
$csvData = Import-Csv -Path $csvPath
$updatedMachineData = @()

foreach ($row in $csvData) {
    if ($row.LicenseStatus -ne "Enabled") {
        Write-Host "License is not enabled, enabling now: $($row.MachineName)"

        try {
            # Construct the PUT request to enable the license
            $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.HybridCompute/machines/$($row.MachineName)/licenseProfiles/default?api-version=2023-10-03-preview"
            $location = (Get-AzConnectedMachine -Name $row.MachineName -ResourceGroupName $ResourceGroupName).Location
            $data = @{ 
                location = $Location
                properties = @{ 
                    softwareAssurance = @{ 
                        softwareAssuranceCustomer = $true
                    }
                }
            }
            $json = $data | ConvertTo-Json -Depth 10

            # Enable the license
            $response = Invoke-RestMethod -Method PUT -Uri $uri -ContentType "application/json" -Headers $header -Body $json
            $operationResult = "License activated"
        } catch {
            $operationResult = "Error occurred: $($_.Exception.Message)"
        }
    } else {
        Write-Host "License is already enabled: $($row.MachineName)"
        $operationResult = "Already enabled"
    }

    # Add updated data to the list
    $updatedMachineData += [PSCustomObject]@{
        MachineName   = $row.MachineName
        LicenseStatus = "Enabled"
        Operation     = $operationResult
    }
}

# Save the updated data to the CSV file
$updatedMachineData | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "Updated machine list saved to CSV: $csvPath"

Write-Host "All machines have been checked and licenses updated."
