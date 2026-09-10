#!/usr/bin/env python3
"""One-shot DNS reconciler for the subkey proxy ACI.

Runs as a scheduled Container Apps Job in the runner environment (cae-runner). It keeps
proxy.byok.internal pointed at the proxy ACI's CURRENT private IP, which changes whenever the
container group is recreated out-of-band.

Auth: Container Apps injects IDENTITY_ENDPOINT + IDENTITY_HEADER for the job's user-assigned
managed identity. We fetch an ARM token from that endpoint directly (the `az login --identity`
CLI path only understands IMDS 169.254.169.254, which Container Apps does NOT expose, and a
VNet-injected ACI can't reach IMDS either — which is why this can't be an in-ACI sidecar). We then
call ARM REST to read the ACI IP and repoint the private-DNS A record. Python stdlib only.

Env vars (set on the job in Bicep):
  AZ_CLOUD         AzureCloud | AzureUSGovernment
  MI_CLIENT_ID     client id of the reconciler user-assigned managed identity
  SUBSCRIPTION_ID  subscription of the proxy ACI + DNS zone
  RG               resource group holding the proxy ACI + private DNS zone
  CG               proxy container group (ACI) name
  ZONE             private DNS zone name (e.g. byok.internal)
  LABEL            A-record host label (e.g. proxy)
"""
import json
import os
import sys
import urllib.parse
import urllib.request

CLOUD = os.environ["AZ_CLOUD"]
CLIENT_ID = os.environ["MI_CLIENT_ID"]
SUB = os.environ["SUBSCRIPTION_ID"]
RG = os.environ["RG"]
CG = os.environ["CG"]
ZONE = os.environ["ZONE"]
LABEL = os.environ["LABEL"]

ARM = "https://management.usgovcloudapi.net" if CLOUD == "AzureUSGovernment" else "https://management.azure.com"


def _get_token():
    endpoint = os.environ["IDENTITY_ENDPOINT"]
    header = os.environ["IDENTITY_HEADER"]
    q = urllib.parse.urlencode({"resource": ARM, "api-version": "2019-08-01", "client_id": CLIENT_ID})
    req = urllib.request.Request(f"{endpoint}?{q}", headers={"X-IDENTITY-HEADER": header})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["access_token"]


def _arm(method, path, api_version, token, body=None):
    url = f"{ARM}{path}?api-version={api_version}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def main():
    token = _get_token()

    cg_path = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.ContainerInstance/containerGroups/{CG}"
    ip = _arm("GET", cg_path, "2023-05-01", token)["properties"]["ipAddress"]["ip"]
    if not ip:
        print(f"dns-reconciler: could not read IP for {CG}", file=sys.stderr)
        return 0

    a_path = f"/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Network/privateDnsZones/{ZONE}/A/{LABEL}"
    try:
        current = [r["ipv4Address"] for r in _arm("GET", a_path, "2018-09-01", token)["properties"].get("aRecords", [])]
    except urllib.error.HTTPError as e:
        current = [] if e.code == 404 else (_ for _ in ()).throw(e)

    if current == [ip]:
        print(f"dns-reconciler: {LABEL}.{ZONE} already -> {ip}; no drift")
        return 0

    print(f"dns-reconciler: drift detected ({current} -> {ip}); repointing {LABEL}.{ZONE}")
    _arm("PUT", a_path, "2018-09-01", token, body={"properties": {"ttl": 60, "aRecords": [{"ipv4Address": ip}]}})
    print(f"dns-reconciler: {LABEL}.{ZONE} now -> {ip}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
