# 🛡️ GKE + External Secrets Operator (ESO) + Argo CD with WIF (No GSA)

This guide walks you step-by-step through setting up a GKE cluster with [External Secrets Operator](https://external-secrets.io) and [Argo CD](https://argo-cd.readthedocs.io/en/stable/), using **Workload Identity Federation (WIF)** without a Google Service Account (GSA). We follow the “KSA as IAM principal” model to simplify setup and reduce permission complexity.

---

## 📋 Quick Index

1. Full rollback (optional)
2. Variables & initial checks
3. Create GKE cluster with WIF
4. Reserve a static IP for Argo CD
5. Install External Secrets Operator (ESO)
6. Create a SecretStore (no credentials)
7. Create secret in Secret Manager
8. Grant secretAccessor role to federated KSA
9. Create and sync ExternalSecret
10. Install Argo CD with fixed IP
11. Quick validation script
12. Why each step matters

---

## 1 · Full Rollback (optional)

```bash
gcloud container clusters delete gke-eso \
  --zone us-central1-c --project noble-anvil-460215-s8 --quiet

gcloud compute addresses delete argocd-ip-v2 \
  --region us-central1 --project noble-anvil-460215-s8 --quiet

kubectl delete ns external-secrets-v2 argocd --ignore-not-found

gcloud secrets delete my-secret-v2 --project noble-anvil-460215-s8 --quiet

Cleans up the project to restart from scratch.

⸻

2 · Variables & Initial Checks

export PROJECT_ID_V2="noble-anvil-460215-s8"
export PROJECT_NUM="262274137731"
export CLUSTER_NAME="gke-eso"
export CLUSTER_LOCATION_V2="us-central1-c"
export WORKLOAD_POOL_V2="${PROJECT_ID_V2}.svc.id.goog"

export KSA_NAME_V2="external-secrets-v2"
export KSA_NAMESPACE_V2="external-secrets-v2"

export SECRET_NAME_V2="my-secret-v2"
export K8S_SECRET_NAME_V2="my-k8s-secret-v2"

export ARGOCD_IP_NAME_V2="argocd-ip-v2"

gcloud config set project $PROJECT_ID_V2
gcloud config list --format="value(core.project)"


⸻

3 · Create GKE Cluster with WIF Enabled

gcloud container clusters create $CLUSTER_NAME \
  --zone $CLUSTER_LOCATION_V2 \
  --workload-pool=$WORKLOAD_POOL_V2 \
  --num-nodes 2 --machine-type e2-medium \
  --enable-ip-alias \
  --project $PROJECT_ID_V2

gcloud container clusters get-credentials $CLUSTER_NAME \
  --zone $CLUSTER_LOCATION_V2 --project $PROJECT_ID_V2

Verify:

gcloud container clusters describe $CLUSTER_NAME \
  --zone $CLUSTER_LOCATION_V2 \
  --format="value(workloadIdentityConfig.workloadPool)"


⸻

4 · Reserve Static IP for Argo CD

gcloud compute addresses create $ARGOCD_IP_NAME_V2 \
  --region us-central1 --project $PROJECT_ID_V2

export ARGOCD_IP_V2=$(gcloud compute addresses describe $ARGOCD_IP_NAME_V2 \
  --region us-central1 --project $PROJECT_ID_V2 --format="value(address)")

echo "🚀 ArgoCD Static IP v2: $ARGOCD_IP_V2"

This keeps Argo CD’s URL stable across upgrades.

⸻

5 · Install External Secrets Operator v0.18+

helm repo add external-secrets https://charts.external-secrets.io
helm repo update

kubectl create namespace $KSA_NAMESPACE_V2

helm upgrade --install external-secrets-v2 external-secrets/external-secrets \
  --namespace $KSA_NAMESPACE_V2 \
  --set installCRDs=true \
  --set serviceAccount.create=true \
  --set serviceAccount.name=$KSA_NAME_V2

Verify:

kubectl get deployment -n $KSA_NAMESPACE_V2
kubectl get crds | grep externalsecrets


⸻

6 · Create SecretStore (no credentials required)

secretstore-v2.yaml

apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcp-secret-store-v2
  namespace: ${KSA_NAMESPACE_V2}
spec:
  provider:
    gcpsm:
      projectID: ${PROJECT_ID_V2}

envsubst < secretstore-v2.yaml | kubectl apply -f -
kubectl get secretstore gcp-secret-store-v2 -n $KSA_NAMESPACE_V2


⸻

7 · Create the Secret in Google Secret Manager

echo -n "super-secret-value-v2" | gcloud secrets create $SECRET_NAME_V2 \
  --replication-policy="automatic" \
  --data-file=- --project $PROJECT_ID_V2

gcloud secrets versions list $SECRET_NAME_V2 --project $PROJECT_ID_V2


⸻

8 · Grant secretAccessor Role to Federated KSA

gcloud projects add-iam-policy-binding $PROJECT_ID_V2 \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${PROJECT_ID_V2}.svc.id.goog/subject/ns/${KSA_NAMESPACE_V2}/sa/${KSA_NAME_V2}" \
  --role="roles/secretmanager.secretAccessor"

Verify:

gcloud projects get-iam-policy $PROJECT_ID_V2 --format json \
  | grep -A2 secretAccessor | grep $KSA_NAME_V2


⸻

9 · Create ExternalSecret

external-secret-v2.yaml

apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-secret
  namespace: ${KSA_NAMESPACE_V2}
spec:
  secretStoreRef:
    name: gcp-secret-store-v2
    kind: SecretStore
  target:
    name: ${K8S_SECRET_NAME_V2}
    creationPolicy: Owner
  data:
    - secretKey: my-secret-key
      remoteRef:
        key: ${SECRET_NAME_V2}

envsubst < external-secret-v2.yaml | kubectl apply -f -

kubectl wait externalsecret my-secret \
  -n $KSA_NAMESPACE_V2 \
  --for=condition=Ready=True --timeout=60s

kubectl get secret $K8S_SECRET_NAME_V2 -n $KSA_NAMESPACE_V2 \
  -o jsonpath='{.data.my-secret-key}' | base64 -d && echo


⸻

10 · Install Argo CD with Static IP

argocd-values-v2.yaml

server:
  service:
    type: LoadBalancer
    loadBalancerIP: ${ARGOCD_IP_V2}

configs:
  secret:
    create: false

helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

kubectl create namespace argocd

envsubst < argocd-values-v2.yaml \
  | helm upgrade --install argo-cd-v2 argo/argo-cd -n argocd -f -

kubectl get svc argo-cd-v2-server -n argocd -o wide | grep $ARGOCD_IP_V2

kubectl -n argocd get secret argo-cd-v2-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

Access: https://$ARGOCD_IP_V2

⸻

11 · Quick Validation Script

validate-wif-v2.sh

#!/usr/bin/env bash
set -e

echo "🔍 KSA → token test"
kubectl run --rm -i --restart=Never \
  -n $KSA_NAMESPACE_V2 test-token \
  --image=google/cloud-sdk:slim -- \
  gcloud secrets versions access latest \
  --secret=$SECRET_NAME_V2 --project=$PROJECT_ID_V2

echo "✅ Token OK"
echo

echo "🔍 ExternalSecret status"
kubectl get externalsecret my-secret -n $KSA_NAMESPACE_V2

echo "🔍 Secret data:"
kubectl get secret $K8S_SECRET_NAME_V2 -n $KSA_NAMESPACE_V2 \
  -o jsonpath='{.data.my-secret-key}' | base64 -d && echo


⸻

12 · Summary of Why Each Step Matters

Step Purpose
GKE with --workload-pool Enables WIF to issue federated OIDC tokens
Dedicated KSA Follows least privilege principle
secretAccessor role Grants read access to secrets
No GSA needed ESO v0.18+ supports native STS token-based auth
SecretStore without credentials ESO fetches pod credentials via federation
Per-step validation Early detection of missing permissions, CRDs, or secrets
Static IP Keeps Argo CD’s public endpoint constant across deployments


⸻

✅ Expected Outcome
 • ExternalSecret synced successfully
 • Argo CD deployed with static IP
 • Secret from Google Secret Manager available in Kubernetes
```
