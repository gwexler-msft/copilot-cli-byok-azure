# Self-healing DNS reconciler for the subkey proxy ACI.
#
# Baked into each env's shared ACR by `az acr build` (repo convention, #94) and run as a scheduled
# Container Apps Job in the runner environment (cae-runner), which pulls it via the job's
# user-assigned managed identity (AcrPull). It runs in Container Apps rather than as an in-ACI
# sidecar because a VNet-injected ACI cannot obtain a managed-identity token in-container (IMDS is
# unreachable there). Building server-side on ACR Tasks keeps the base-image pull off the VNet, and
# shipping the reconcile logic as a real file (not an inline shell string) avoids CRLF/quoting bugs.
FROM mcr.microsoft.com/azure-cli:latest

# Python stdlib only (no `az login` — it can't use the Container Apps identity endpoint). The
# azure-cli base is used simply because it ships a known-good python3 and pulls under restricted egress.
COPY reconcile.py /usr/local/bin/reconcile.py
RUN chmod +x /usr/local/bin/reconcile.py

ENTRYPOINT ["python3", "/usr/local/bin/reconcile.py"]
