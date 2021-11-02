######################### BEGIN SCRIPT #########################

## SECTION1: Update these values to your environment:
$resourceGroupName = Read-Host('Resource group name of function app')
$functionAppName = Read-Host('Function app name')
$keyVaultName = Read-Host('Key vault name')

#### Update Logic App Names to your environment (only required if custom names used during deployment):
$logicAppNames = "D365-License-Manual-Disable", `
    "D365-License-Manual-Enable", `
    "D365-License-Auto-Disable", `
    "D365-License-Auto-Disable-Outlook", `
    "D365-License-Auto-Disable-Teams"

$ErrorActionPreference = 'Stop'

Write-Host "Checking variables" -ForegroundColor Yellow
try {
    Get-AzResourceGroup -Name $resourceGroupName
}
catch {
    Write-Error "Resource group not found. Please use the resource group name used to deploy the solution."
}

if (!(Get-AzFunctionApp -Name $functionAppName -ResourceGroupName $resourceGroupName)) {
    Write-Error "Azure function $functionAppName not found. Please ensure you have used the correct function name."
}

if (!(Get-AzKeyVault -VaultName $keyVaultName)) {
    Write-Error "Key Vault $keyVaultName not found. Please ensure you are using correct Key Vault names."
}

foreach ($logicAppName in $logicAppNames) {
    try {
        Get-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName
    }
    catch {
        Write-Error "LogicApp $logicAppName not found. Please ensure you are using correct Logic App names."
    }
}

Write-Host "Obtaining Function App and App Registration" -ForegroundColor Yellow
$functionApp = Get-AzFunctionApp -Name $functionAppName -resourceGroupName $resourceGroupName
$functionAuthSettings = (Invoke-AzRestMethod -Method GET -Path ($functionApp.Id + '/config/authsettingsV2/list?api-version=2021-02-01')).Content | ConvertFrom-Json
$functionAppRegClientId = $functionAuthSettings.properties.identityProviders.azureActiveDirectory.registration.clientId

Write-Host "Obtaining User Assigned Managed Identity info from Logic App" -ForegroundColor Yellow
$logicApp = Get-AzResource -Name $logicAppNames[0] -ResourceGroupName $resourceGroupName -ResourceType 'Microsoft.Logic/workflows'
$userAssignedManagedIdentity = $logicApp.identity.UserAssignedIdentities.Values

#### SECTION2: Add an App Role to the App Registration
Write-Host "Creating Enterprise App - App Role" -ForegroundColor Yellow
AzureAD.Standard.Preview\Connect-AzureAD -Identity -TenantID $env:ACC_TID

$app = Get-AzureADApplication | Where-Object AppId -eq $functionAppRegClientId
$appRole = Get-AzureADApplication -ObjectId $app.ObjectId | Select-Object -ExpandProperty AppRoles | Where-Object Value -eq "Playbook"

if (!($appRole)) {
    $appRole = New-Object Microsoft.Open.AzureAD.Model.AppRole
    $appRole.AllowedMemberTypes = New-Object System.Collections.Generic.List[string]
    $appRole.AllowedMemberTypes.Add("User")
    $appRole.DisplayName = "Playbook"
    $appRole.Id = New-Guid
    $appRole.IsEnabled = $true
    $appRole.Description = "Used to authorize access to D365 Licesense Function"
    $appRole.Value = "Playbook"
    $appRoles = $app.AppRoles 
    $appRoles.Add($appRole)
    Set-AzureADApplication -ObjectId $app.ObjectId -AppRoles $appRoles
}

#### SECTION3:Role Assignment and App Role permission assignment to User Assigned Managed Identity
Write-Host "Assigning App Role to User Assigned Managed Identity" -ForegroundColor Yellow
if (!(Get-AzureADServiceAppRoleAssignedTo -ObjectId $userAssignedManagedIdentity.PrincipalId | Where-Object Id -eq $appRole.id)) {
    $appServicePrincipal = Get-AzureADServicePrincipal -All $true | Where-Object AppId -eq $app.AppId
    $appServicePrincipal | Set-AzureADServicePrincipal -AppRoleAssignmentRequired $true
    New-AzureADServiceAppRoleAssignment `
        -ObjectId $userAssignedManagedIdentity.PrincipalId `
        -Id $appRole.Id `
        -PrincipalId $userAssignedManagedIdentity.PrincipalId `
        -ResourceId $appServicePrincipal.ObjectId
}

#### SECTION4: Assign the License Administrator Directory role to the Function App App Registration
Write-Host "Assigning License Administrator role" -ForegroundColor Yellow
$directoryRole = Get-AzureADDirectoryRole | Where-Object DisplayName -eq "License Administrator"
if (!($directoryRole)) {
    $directoryRoleTemplate = Get-AzureADDirectoryRoleTemplate | Where-Object DisplayName -eq "License Administrator"
    $directoryRole = Enable-AzureADDirectoryRole -RoleTemplateId $directoryRoleTemplate.ObjectId
}
if (!(Get-AzureADDirectoryRoleMember -ObjectId $directoryRole.ObjectId | Where-Object ObjectId -eq $appServicePrincipal.ObjectId)) {
    Add-AzureADDirectoryRoleMember -ObjectId $directoryRole.ObjectId -RefObjectId $appServicePrincipal.ObjectId
}

#### SECTION5: Add Function app to KV access policy
Write-Host "Adding Key Vault Access Policies" -ForegroundColor Yellow
$currentUser = az ad signed-in-user show | ConvertFrom-Json
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -UserPrincipalName $currentUser.userPrincipalName -PermissionsToSecrets all
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $functionApp.IdentityPrincipalId -PermissionsToSecrets get

#### SECTION6: Migrate the Function App App Registration client secret to Key Vault
Write-Host "Migrating App Client Secret to Key Vault" -ForegroundColor Yellow
$secretName = "MICROSOFT-PROVIDER-AUTHENTICATION-SECRET"
$keyVaultSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -SecretName $secretName
if (!($keyVaultSecret)) {
    $functionSecret = ConvertTo-SecureString $functionApp.ApplicationSettings.MICROSOFT_PROVIDER_AUTHENTICATION_SECRET -AsPlainText -Force
    $keyVaultSecret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $functionSecret
}

#### SECTION7: Update Function App Settings
Write-Host "Configuring Function App" -ForegroundColor Yellow
Update-AzFunctionAppSetting -Name $functionAppName -ResourceGroupName $resourceGroupName `
    -AppSetting @{
    "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET" = "@Microsoft.KeyVault(SecretUri=" + $keyVaultSecret.Id + ")";
    "clientId"                                 = $app.AppId;
}

#### SECTION8: Update License Management Logic App settings
Write-Host "Updating Logic App parameters" -ForegroundColor Yellow
foreach ($logicAppName in $logicAppNames) {
    $logicApp = Get-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName
    $definition = $logicApp.Definition.ToString() | ConvertFrom-Json
    $definition.parameters.Audience.defaultValue = $functionAppRegClientId
    Set-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName -Definition($definition | ConvertTo-Json -Depth 100) -Force
}
######################### END SCRIPT #########################