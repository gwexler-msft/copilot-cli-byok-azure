param apimName string
param productId string = 'byok-jwt'
param active bool = false
param apiNames string[] = []
param consumerPolicyIds array

@export()
var jwtProductGuardTemplate string = '<policies><inbound><choose><when condition="@(!__ACTIVE__ || !context.Variables.ContainsKey(&quot;byokCallerAuthenticated&quot;) || !(bool)context.Variables[&quot;byokCallerAuthenticated&quot;] || !context.Variables.ContainsKey(&quot;byokJwtValidated&quot;) || !(bool)context.Variables[&quot;byokJwtValidated&quot;] || !context.Variables.ContainsKey(&quot;callerAuthMethod&quot;) || ((string)context.Variables[&quot;callerAuthMethod&quot;] != &quot;entraJwt&quot; &amp;&amp; (string)context.Variables[&quot;callerAuthMethod&quot;] != &quot;oktaJwt&quot;))"><return-response><set-status code="401" reason="Validated JWT required" /></return-response></when></choose></inbound><backend /><outbound /><on-error /></policies>'

resource apim 'Microsoft.ApiManagement/service@2024-05-01' existing = {
  name: apimName
}

resource product 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: productId
  properties: {
    displayName: 'BYOK validated JWT admission'
    description: 'JWT-only admission after the shared caller gate. Never authorizes a subscription key or an anonymous request.'
    subscriptionRequired: false
    state: 'notPublished'
  }
}

resource guard 'Microsoft.ApiManagement/service/products/policies@2024-05-01' = {
  parent: product
  name: 'policy'
  properties: {
    format: 'xml'
    value: replace(jwtProductGuardTemplate, '__ACTIVE__', toLower(string(active)))
  }
}

@batchSize(1)
resource links 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = [for apiName in apiNames: if (active) {
  parent: product
  name: apiName
  dependsOn: [guard]
}]

output id string = product.id
output consumerDependency array = consumerPolicyIds