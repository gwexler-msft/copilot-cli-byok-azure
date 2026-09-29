# IntelliJ BYOK bolt-on — Terraform route

A Terraform-native version of the standalone bolt-on for teams that deploy strictly with Terraform.
It **reuses the same shared assets** as the Bicep route (no forked copies):

| Shared asset | Used by |
|---|---|
| `../policies/intellij-inference.xml`, `../policies/intellij-models.xml` | `azurerm_api_management_api_policy` / `..._api_operation_policy` (via `file()`) |
| `../cloud-init.yaml`, `../cloud-init.prebaked.yaml` | the VM's `custom_data` (private IP + gateway host substituted with `replace()`) |
| `../nginx-credentials.mjs` | raw credential selection before proxy header translation; requires nginx njs |
| `../../../../infra/runner-image/install-nginx-njs.sh` | pinned, signing-key-verified nginx/njs bootstrap embedded in standard VM cloud-init |
| `../caller-policies.bicepparam` | opt-in shared caller/ownership package rendered from canonical Bicep policy sources |
| `../scripts/build-proxy-image.ps1` / `.sh` | Phase 6 pre-baked image (run once, pass the id via `proxy_image_id`) |

So policy logic (subkey proxy, dynamic `/v1/models`, reasoning-strip, auto-route) and the nginx
bootstrap are identical across both IaC routes — only the resource wiring differs.

## What it creates
- **On the existing APIM:** the `intellij-*` named values, the `intellij-byok` API (`subscription_required`, `api-key` header), its 5 operations, both policies, an App Insights **logger + API-scoped diagnostic**, and links to every configured existing product (`existing_product_name` + `additional_product_names`).
- **New:** a resource group + a **static-IP nginx proxy VM** (no public IP), from the Ubuntu marketplace image (installs nginx at boot) or a pre-baked gallery image for air-gapped subnets.

## Resource groups
| Resource group | Existing / created | Variables |
|---|---|---|
| **APIM RG** | existing | `apim_resource_group` — holds the APIM + all `/intellij` sub-resources (API, policies, named values, logger, diagnostic). |
| **App Insights RG** | existing (read-only) | `app_insights_resource_group` — the metrics target; nothing is created. |
| **Proxy VM RG** | created *or* existing | `vm_resource_group` (+ `create_vm_resource_group`) — the VM + NIC. |
| **Images RG** (air-gapped) | via `../scripts/build-proxy-image.*` | the Compute Gallery; separate one-time step. |

**One-RG / constrained access:** set `create_vm_resource_group = false` to deploy the VM into an
**existing** RG (no subscription-level RG-create rights needed). To put everything in one RG, set
`vm_resource_group` to the APIM RG. The `azurerm_resource_group.vm` resource is `count`-gated, so
Terraform won't try to manage the RG when `create_vm_resource_group = false`.

## Layout
```
terraform/
  versions.tf                 # azurerm + AzAPI providers
  variables.tf                # all inputs (mirror the Bicep params)
  main.tf                     # data sources + locals (named values, ops, cloud-init)
  apim.tf                     # APIM API + ops + policies + logger + diagnostic + product links
  proxy_vm.tf                 # RG + NIC(static IP) + Linux VM (marketplace or gallery image)
  outputs.tf                  # client_base_url, proxy_private_ip
  terraform.tfvars.example    # copy to terraform.tfvars and fill in
```

## Prerequisites
- Complete the parent [Network go/no-go validation](../README.md#network-gono-go-validation) before
  running `terraform plan` or `apply`. The proxy requires a client-reachable private IP and private
  TCP 443 reachability to Internal APIM; Bastion access alone does not satisfy this requirement.
- **Terraform ≥ 1.5**, **azurerm ≥ 3.80**, and **AzAPI 2.10.x** (installed by `terraform init`).
- The same Azure access as the Bicep route (see the parent [`README.md`](../README.md) §Prerequisites): APIM contributor, subnet `join/action`, App Insights reader, Contributor to create the VM RG. **No Foundry permissions.**
- Signed in for the target cloud (`az login`, or `ARM_*` env vars / a service principal for CI). For Gov set `arm_environment = "usgovernment"`.

## Shared Callers

Defaults remain `caller_auth_rollout="legacy"` and disabled `caller_auth_preparation`. For the
explicit [shared caller stages](../README.md#shared-caller-authentication), first render the current
nonsecret package from the repository root with Bicep 0.44.1 or later:

```bash
bicep build-params samples/intellij/standalone/caller-policies.bicepparam --outfile samples/intellij/standalone/caller-policies.json
```

The generated package is ignored by Git; regenerate after policy changes. Set complete trust
configuration and a unique JWT product ID. Shared mode supports Commercial and Government only.
Set `existing_backend_origin` to the exact HTTPS account origin and select `foundry_auth_mode`.
Use the secret manager/environment for `TF_VAR_response_owner_key`,
`TF_VAR_response_owner_previous_key` (explicit `__none__` initially), and `TF_VAR_foundry_api_key`
when needed. Terraform state and saved plans contain sensitive values despite `sensitive=true`;
protect/encrypt them and never commit them. Ownership keys must survive redeploys and rotations.

`shared` adds four protected Responses operations; `coexistence` links the guarded JWT product
last while keeping native key validation. JWT-only mode requires an enabled issuer and
`keyEnabled=false`. Existing native subscriptions and JWT identities keep independent budgets.

Before rollback, detach JWT product associations and verify absence before restoring legacy
policies. Do not rely on one unordered apply to replace authentication and remove open admission.
Retain the owner keys/utility policies for stored responses until their retention window ends.
Review destruction of utility operations and named values explicitly.

Ten isolated mock plans cover default/shared/coexistence and negative contracts. They use Terraform
1.11.4 (mock-provider tests require at least 1.7) with the checked-in provider lockfile. Validation
and all ten plans passed on 2026-09-23, including the shared installer reference. The test fixture
must preserve the repository directory layout for that reference. This is not a live Azure apply;
the separate [Linux image evidence](../README.md#shared-caller-authentication) does not establish
Terraform deployment acceptance. Never run these tests against customer state or `.tfvars`.

## Deploy
```bash
cd samples/intellij/standalone/terraform
cp terraform.tfvars.example terraform.tfvars      # then fill it in
#  - generate the VM key:  ssh-keygen -t ed25519 -f byok-proxy-key -N ""  -> paste .pub into vm_admin_ssh_public_key
#  - (air-gapped only) build the image first: ../scripts/build-proxy-image.ps1 ...  -> set proxy_image_id

terraform init
terraform plan
terraform apply
terraform output client_base_url                  # http://<proxy-ip>:8080/intellij/v1
```

If the customer network team supplies the NIC, set:

```hcl
proxy_nic_id          = "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/networkInterfaces/<nic>"
vm_subnet_id          = ""
proxy_static_private_ip = "<the NIC static private IP>"
```

Terraform reads and validates that NIC, attaches it to the VM, and creates no managed
`azurerm_network_interface`. The NIC stays customer-owned; it must be in the active subscription and
VM region, attached to a subnet, private-only, static, single-IP-config, and unattached (or already
attached to this same proxy VM on an idempotent rerun). When `proxy_nic_id = ""`, Terraform retains
the default behavior and creates the NIC from `vm_subnet_id` + `proxy_static_private_ip`.

> **Existing Terraform-managed NIC:** `proxy_nic_id` is a customer-ownership mode, not an automatic
> ownership transfer. If this state already manages `azurerm_network_interface.proxy`, setting
> `proxy_nic_id` to that same NIC ID without a state handoff will plan to delete the NIC. Back up the
> state, use `terraform state list` to find the NIC's exact address, remove that address with
> `terraform state rm '<address>'`, and confirm the next plan contains no NIC delete before applying.

Then validate from an in-VNet host and configure JetBrains AI Assistant exactly as in the parent
[`README.md`](../README.md#jetbrains-post-deployment-configuration). That runbook gives the exact URL,
API-key semantics, Core/Instant-helper/Completion assignments, Tool calling default, inline-completion
setting, context window, and expected metrics. The proxy rejects every non-`/intellij/*` path with 404.

## Notes
- **State:** use a remote backend (e.g. `azurerm` backend on a storage account) for anything beyond a
  local trial; `terraform.tfvars`, `*.tfstate*`, and `.terraform/` are gitignored.
- **Backend authentication:** `foundry_auth_mode="apiKey"` remains the default. Opt into
  `"managedIdentity"` only after the existing APIM identity has Foundry data-plane RBAC; this package
  creates no role grant. Shared ownership lookup requires explicit credentials and cannot rely on
  opaque credentials on a backend entity. If a required backend key is empty, Foundry returns
  `401 "Access denied due to invalid subscription key or wrong API endpoint"` (Azure OpenAI's own message,
  not an APIM subscription error). Keep it out of `terraform.tfvars` in VCS — pass it via
  `TF_VAR_foundry_api_key` or a secrets manager. The App Insights instrumentation key is read from a
  `data` source, not stored.
- **Metrics (`emit-metric`):** AzureRM doesn't expose the API diagnostic's required `metrics=true`
  property, so this route includes a managed `azapi_update_resource.diag_metrics` override. Do not
  remove it: request/dependency telemetry still works without the flag, but APIM silently skips every
  `copilot_byok_*` custom metric. AzAPI uses the same public/Gov/China/German cloud selected by
  `arm_environment`.
- **Re-deploys:** APIM/policy changes apply cleanly. Changing the **proxy VM's** cloud-init forces VM
  replacement (Azure `custom_data` is immutable) — Terraform will show the VM must be recreated.
- **VM size:** `Standard_B2s` isn't offered in every region (e.g. `usgovvirginia` needs a v6 size like
  `Standard_D2as_v6`).
