[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$WorkSpaceName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)


Function Get-AzSentinelAutomationRule ($workspaceName, $resourceGroupName) {
    #Setup the Authentication header needed for the REST calls
    $context = Get-AzContext
    $profile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
    $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($profile)
    $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)
    $authHeader = @{
        'Content-Type'  = 'application/json' 
        'Authorization' = 'Bearer ' + $token.AccessToken 
    }
    
    $SubscriptionId = (Get-AzContext).Subscription.Id

    $url = "https://management.azure.com/subscriptions/$($subscriptionId)/resourceGroups/$($resourceGroupName)/providers/Microsoft.OperationalInsights/workspaces/$($workspaceName)/providers/Microsoft.SecurityInsights/automationRules/?api-version=2022-12-01-preview"
    $results = (Invoke-RestMethod -Method "Get" -Uri $url -Headers $authHeader ).value

    foreach ($result in $results) {
        # Replace values in ARM template
        $automationRuleTemplate = @"
{{
    "`$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {{
        "workspace": {{
            "type": "string",
            "metadata": {{
                "description": "The name of the Sentinel workspace where the automation rule will be deployed"
            }}
        }},
        "ResourceGroupName": {{
            "type": "string",
            "defaultValue": "[resourceGroup().name]"
        }},
        "TenantID": {{
            "type": "string",
            "defaultValue": "[subscription().tenantId]"
        }},
        "SubscriptionID": {{
            "type": "string",
            "defaultValue": "[subscription().id]"
        }},
        "automationRuleName": {{
            "type": "string",
            "metadata": {{
                "description": "The name of the automation rule that will be deployed."
            }},
            "defaultValue": "{0}"
        }}
    }},
    "variables": {{
        "automationRuleGuid": "[uniqueString(parameters('automationRuleName'))]" 
    }},
    "resources": [
        {{
            "type": "Microsoft.OperationalInsights/workspaces/providers/automationRules",
            "name": "[concat(parameters('workspace'),'/Microsoft.SecurityInsights/',parameters('automationRuleName'))]",
            "apiVersion": "2022-11-01",
            "properties": {1}
        }}
    ],
    "outputs": {{}}
}}
"@

        $displayName = $result.properties.displayName
        $name = $result.name
        $properties = ConvertTo-Json $result.properties -depth 100

        # Replace values in the ARM template
        $automationRuleTemplate = $automationRuleTemplate -f $name, $properties

        # Save the ARM template to a file
        $folderName = "Automation_Rules_Backup"
        $filePath = Join-Path $PSScriptRoot $folderName
        $fileName = "$($displayName).json"
        $filePath = Join-Path $filePath $fileName
        
        $automationRuleTemplate | Out-File $filePath -Encoding utf8

        Write-Host "Automation rule template saved to: $($filePath)"

        $folderPath = Join-Path $PSScriptRoot $folderName

        # Loop through each file in the folder
        Get-ChildItem -Path $folderPath -Filter *.json | ForEach-Object {

            # Load the contents of the file into a variable
            $fileContent = Get-Content $_.FullName | Out-String | ConvertFrom-Json

            # Loop through each action in the resources section of the JSON object
            foreach ($action in $fileContent.resources.properties.actions) {
                # Check if the action has a tenantId property
                if ($action.actionConfiguration.tenantId) {
                    # Replace the tenantId value with the parameter value
                    $action.actionConfiguration.tenantId = "[parameters('TenantID')]"
                }
                
                # Check if the action has a logicAppResourceId property
                if ($action.actionConfiguration.logicAppResourceId -match "/subscriptions/(?<subId>[^/]+)/resourceGroups/(?<rgName>[^/]+)/providers/Microsoft.Logic/workflows/(?<workflowName>[^/]+)") {
                    $subId = $Matches["subId"]
                    $rgName = $Matches["rgName"]
                    $workflowName = $Matches["workflowName"]
                    # Replace the logicAppResourceId value with the parameter value
                    $action.actionConfiguration.logicAppResourceId = "[concat(parameters('SubscriptionID'),'/resourceGroups/',parameters('ResourceGroupName'),'/providers/Microsoft.Logic/workflows/','$workflowName')]"
                }
            }
            
            # Loop through each property in the resources section of the JSON object
            foreach ($resource in $fileContent.resources) {
                if ($resource.type -eq "Microsoft.OperationalInsights/workspaces/providers/automationRules") {
                    $propertyValues = $resource.properties.triggeringLogic.conditions.conditionProperties.propertyValues
                    
                    if ($propertyValues -ne $null) {
                        foreach ($i in 0..($propertyValues.Count - 1)) {
                            if ($propertyValues[$i] -match "/providers/Microsoft.SecurityInsights/alertRules/(?<alertRuleId>([A-Za-z0-9]+(-[A-Za-z0-9]+)+))" -or
                                $propertyValues[$i] -match "/providers/Microsoft.SecurityInsights/alertRules/(?<alertRuleId>[A-Za-z0-9-]+)") {
                                $alertRuleId = $Matches["alertRuleId"]
                                $propertyValues[$i] = "[concat(parameters('SubscriptionID'),'/resourceGroups/',parameters('ResourceGroupName'),'/providers/Microsoft.OperationalInsights/workspaces/',parameters('workspace'),'/providers/Microsoft.SecurityInsights/alertRules/','$alertRuleId')]"
                            }
                        }
                    }
                }
            }
            
            foreach ($resource in $fileContent.resources) {
                if ($resource.type -eq "Microsoft.OperationalInsights/workspaces/providers/automationRules") {
                    $conditions = $resource.properties.triggeringLogic.conditions
                    
                    foreach ($condition in $conditions) {
                        if ($condition.conditionType -eq "Property") {
                            $propertyValues = $condition.conditionProperties.propertyValues
                            
                            if ($propertyValues -ne $null) {
                                foreach ($i in 0..($propertyValues.Count - 1)) {
                                    if ($propertyValues[$i] -match "/providers/Microsoft.SecurityInsights/alertRules/(?<alertRuleId>([A-Za-z0-9]+(-[A-Za-z0-9]+)+))" -or
                                        $propertyValues[$i] -match "/providers/Microsoft.SecurityInsights/alertRules/(?<alertRuleId>[A-Za-z0-9-]+)") {
                                        $alertRuleId = $Matches["alertRuleId"]
                                        $propertyValues[$i] = "[concat(parameters('SubscriptionID'),'/resourceGroups/',parameters('ResourceGroupName'),'/providers/Microsoft.OperationalInsights/workspaces/',parameters('workspace'),'/providers/Microsoft.SecurityInsights/alertRules/','$alertRuleId')]"
                                    }
                                }
                            }
                        }
                    }
                }
            }                    
            
            # Save the updated JSON object back to the file
            $fileContent | ConvertTo-Json -Depth 100 | Set-Content $_.FullName
        }

    }
}


Get-AzSentinelAutomationRule $WorkSpaceName $ResourceGroupName