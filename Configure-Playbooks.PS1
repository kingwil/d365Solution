######################### BEGIN SCRIPT #########################

## SECTION1: Update these values to your environment:
$userAssignedIdentityName = "User Assigned Managed Identity Name" 
$resourceGroupName = "resource group name used during deployment of solution"
$functionAppRegClientId = "App Registration Application (client) ID"
$functionAppName = "name of the function app e.g. D365-License-Function-xxxxx"
$keyVaultName = "name of the key vault e.g. D365-License-KV-xxxxx"

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

try {
    Get-AzUserAssignedIdentity -Name $userAssignedIdentityName -ResourceGroupName $resourceGroupName
}
catch [System.Management.Automation.CommandNotFoundException] {
    Write-Host "Run the following cmdlet to install the module and re-run this script:" -ForegroundColor Yellow
    Write-Host "Install-Module -Name Az.ManagedServiceIdentity -AllowPrerelease" -ForegroundColor Green
    Write-Error "Az.ManagedServiceIdentity module not found."
}

catch {
    Write-Error "Managed identity not found. Please makes sure the identity name is correct and in the same resource group used to deploy the solution."
}
try {
    Get-AzADApplication -ApplicationId $functionAppRegClientId
}

catch {
    Write-Error "Azure AD App Registration not found for the Azure Function. Check app reg client ID."
}

if(!(Get-AzFunctionApp -Name $functionAppName -ResourceGroupName $resourceGroupName)) {
    Write-Error "Azure function $functionAppName not found. Please ensure you have used the correct function name."
}

if(!(Get-AzKeyVault -VaultName $keyVaultName -ResourceGroupName $resourceGroupName)) {
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

#### SECTION2: Assign Azure Sentinel Contributor role to the User Assigned Managed Identity
Write-Host "Adding Sentinel Contributor role assignment" -ForegroundColor Yellow
$managedIdentity = Get-AzUserAssignedIdentity -Name $userAssignedIdentityName -ResourceGroupName $resourceGroupName
if(!(Get-AzRoleAssignment -ObjectId $managedIdentity.PrincipalId -RoleDefinitionName "Azure Sentinel Contributor" -ResourceGroupName $resourceGroupName))
{
    New-AzRoleAssignment -ObjectId $managedIdentity.PrincipalId -RoleDefinitionName "Azure Sentinel Contributor" -ResourceGroupName $resourceGroupName
}

#### SECTION3: Add an App Role to the App Registration
Write-Host "Creating Enterprise App - App Role" -ForegroundColor Yellow
AzureAD.Standard.Preview\Connect-AzureAD -Identity -TenantID $env:ACC_TID

$app = Get-AzureADApplication | Where-Object AppId -eq $functionAppRegClientId
$appRole = Get-AzureADApplication -ObjectId $app.ObjectId | Select-Object -ExpandProperty AppRoles | Where-Object Value -eq "Playbook"
$appServicePrincipal = Get-AzureADServicePrincipal -All $true | Where-Object AppId -eq $app.AppId

if(!($appRole))
{
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

#### SECTION4:Role Assignment and App Role permission to the User Assigned Managed Identity
Write-Host "Assigning App Role to User Assigned Managed Identity" -ForegroundColor Yellow
if(!(Get-AzureADServiceAppRoleAssignedTo -ObjectId $managedIdentity.PrincipalId | Where-Object Id -eq $appRole.id))
{
    $appServicePrincipal | Set-AzureADServicePrincipal -AppRoleAssignmentRequired $true
    New-AzureADServiceAppRoleAssignment `
        -ObjectId $managedIdentity.PrincipalId `
        -Id $appRole.Id `
        -PrincipalId $managedIdentity.PrincipalId `
        -ResourceId $appServicePrincipal.ObjectId
}

#### SECTION5: Assign the License Administrator Directory role to the App Registration
Write-Host "Assigning License Administrator role" -ForegroundColor Yellow
$directoryRole = Get-AzureADDirectoryRole | Where-Object DisplayName -eq "License Administrator"
if (!($directoryRole)) {
    $directoryRoleTemplate = Get-AzureADDirectoryRoleTemplate | Where-Object DisplayName -eq "License Administrator"
    $directoryRole = Enable-AzureADDirectoryRole -RoleTemplateId $directoryRoleTemplate.ObjectId
}
if(!(Get-AzureADDirectoryRoleMember -ObjectId $directoryRole.ObjectId | Where-Object ObjectId -eq $appServicePrincipal.ObjectId))
{
    Add-AzureADDirectoryRoleMember -ObjectId $directoryRole.ObjectId -RefObjectId $appServicePrincipal.ObjectId
}

#### SECTION6: Update Function App settings
Write-Host "Obtaining Function App" -ForegroundColor Yellow
$functionApp = Get-AzFunctionApp -Name $functionAppName -resourceGroupName $resourceGroupName

#### SECTION7: Create a new Key Vault and grant access to the Function App
Write-Host "Adding Key Vault Access Policies" -ForegroundColor Yellow
$currentUser = az ad signed-in-user show | ConvertFrom-Json
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -UserPrincipalName $currentUser.userPrincipalName -PermissionsToSecrets all
Set-AzKeyVaultAccessPolicy -VaultName $keyVaultName -ObjectId $functionApp.IdentityPrincipalId -PermissionsToSecrets get

#### SECTION8: Migrate the Function App App Registration client secret to Key Vault
Write-Host "Migrating App Client Secret to Key Vault" -ForegroundColor Yellow
$secretName = "MICROSOFT-PROVIDER-AUTHENTICATION-SECRET"
$keyVaultSecret = Get-AzKeyVaultSecret -VaultName $keyVaultName -SecretName $secretName
if(!($keyVaultSecret))
{
    $functionSecret = ConvertTo-SecureString $functionApp.ApplicationSettings.MICROSOFT_PROVIDER_AUTHENTICATION_SECRET -AsPlainText -Force
    $keyVaultSecret = Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $secretName -SecretValue $functionSecret
}

#### SECTION9: Update Function App Settings
Write-Host "Configuring Function App" -ForegroundColor Yellow
Update-AzFunctionAppSetting -Name $functionAppName -ResourceGroupName $resourceGroupName `
    -AppSetting @{
    "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"  = "@Microsoft.KeyVault(SecretUri=" + $keyVaultSecret.Id + ")";
    "tenantId"                                  = $managedIdentity.TenantId; `
    "clientId"                                  = $app.AppId;
}

#### SECTION10: Update License Management Logic App settings
Write-Host "Updating Logic App parameters" -ForegroundColor Yellow
foreach ($logicAppName in $logicAppNames) {
    $logicApp = Get-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName
    $definition = $logicApp.Definition.ToString() | ConvertFrom-Json
    $definition.parameters.Audience.defaultValue = $functionAppRegClientId
    Set-AzLogicApp -Name $logicAppName -ResourceGroupName $resourceGroupName -Definition($definition | ConvertTo-Json -Depth 100) -Force
}
######################### END SCRIPT #########################
