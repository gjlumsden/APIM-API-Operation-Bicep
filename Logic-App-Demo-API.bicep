/*
This template relies on the Logic App, API Management Service and Key Vault being in the same resource group.
See the following documentation for more information on using deployment scopes to allow resources to exist in separate resource groups:

- https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/file#target-scope
- https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-subscription?tabs=azure-cli
- https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/deploy-to-resource-group?tabs=azure-cli
- https://docs.microsoft.com/en-us/azure/azure-resource-manager/bicep/bicep-functions-scope

*/

@description('Existing API Management Service name. This can be deployed and managed independently of the APIs/Operations/Products/etc')
param apimName string
@description('The name of the Logic App to add as a backend API. This is an existing logic app or one that will be created with a sample workflow.')
param logicAppName string
@description('The name of an existing key vault used for named values (Logic App Signature is added to this vault).')
param keyVaultName string
@description('Use an existing logic app referenced by the parameter \'logicAppName\' or deploy a sample logic app with this name.')
param useExistingLogicApp bool
@description('Deployment location. Defaults to Resource Group location.')
param location string = resourceGroup().location

param basePath string = '/demo' //The base path for the API

//Resource Names
var secretName = '${logicAppName}-sig-value'
var backendName = '${logicAppName}-backend'
var apiName = '${logicAppName}-api'
var operationName = '${apiName}-get-operation'

//Existing API Management Service resource
resource apiManagement 'Microsoft.ApiManagement/service@2021-12-01-preview' existing = {
  name: apimName
}

//Existing Logic App resource
resource existingLogicApp 'Microsoft.Logic/workflows@2019-05-01' existing = if (useExistingLogicApp) {
  name: logicAppName
}

resource newLogicApp 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  properties: {
    definition: loadJsonContent('workflow.json')
  }
}

//Existing Key Vault resource
resource namedValuesVault 'Microsoft.KeyVault/vaults@2021-11-01-preview' existing = {
  name: keyVaultName
}

//Get Logic App Signature and insert into key vault
resource signatureSecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' = {
  name: secretName
  parent: namedValuesVault
  properties: {
    value: listCallbackUrl(resourceId('Microsoft.Logic/workflows/triggers', (useExistingLogicApp ? existingLogicApp.name : newLogicApp.name), 'manual'), '2016-06-01').queries.sig
  }
}

//create named value linked to key vault secret
resource logicAppSignatureNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-12-01-preview' = {
  name: secretName
  parent: apiManagement
  properties: {
    displayName: secretName
    keyVault: {
      secretIdentifier: '${namedValuesVault.properties.vaultUri}secrets/${signatureSecret.name}'
    }
    secret: true
  }
}

//create backend with named value query sig auth
resource logicAppBackend 'Microsoft.ApiManagement/service/backends@2021-12-01-preview' = {
  name: backendName
  parent: apiManagement
  properties: {
    protocol: 'http'
    resourceId: '${environment().resourceManager}${substring((useExistingLogicApp ? existingLogicApp.id : newLogicApp.id), 1)}'
    url: useExistingLogicApp ? '${existingLogicApp.listCallbackUrl().basePath}/triggers' : '${newLogicApp.listCallbackUrl().basePath}/triggers'
    credentials: {
      query: {
        'sig': [
          '{{${logicAppSignatureNamedValue.properties.displayName}}}'
        ]
      }
    }
  }
}

//create named value used by the API Policy to determine the backend name
resource backendNameNamedValue 'Microsoft.ApiManagement/service/namedValues@2021-12-01-preview' = {
  name: '${logicAppName}-backend-name'
  parent: apiManagement
  properties: {
    displayName: '${logicAppName}-backend-name'
    value: logicAppBackend.name
  }
}

//create api with inbound policy xml
resource logicAppApi 'Microsoft.ApiManagement/service/apis@2021-12-01-preview' = {
  name: apiName
  parent: apiManagement
  properties: {
    path: basePath
    displayName: 'Demo Logic App API'
    subscriptionRequired: true
    apiType: 'http'
    protocols: [
      'https'
    ]
  }
}

resource logicAppApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2021-12-01-preview' = {
  name: 'policy'
  parent: logicAppApi
  properties: {
    value: replace(loadTextContent('API/policy.xml'), '{{logicAppBackendNamedValuePlaceholder}}', '{{${backendNameNamedValue.properties.displayName}}}')
    format: 'xml'
  }
}

//create api operation with inbound policy xml
resource logicAppApiOperation 'Microsoft.ApiManagement/service/apis/operations@2021-12-01-preview' = {
  name: operationName
  parent: logicAppApi
  properties: {
    method: 'GET'
    displayName: 'Get Echo Queries'
    urlTemplate: '/echoqueries'
  }
}

resource logicAppApiOperationPolicy 'Microsoft.ApiManagement/service/apis/operations/policies@2021-12-01-preview' = {
  name: 'policy'
  parent: logicAppApiOperation
  properties: {
    value: loadTextContent('API/Operations/GetEchoQueries/policy.xml')
    format: 'xml'
  }
}
