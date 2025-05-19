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
kubectl get secret $K8S_SECRET_NAME_V2 -n $KSA_NAMESPACE_V2 -o jsonpath='{.data.my-secret-key}' | base64 -d && echo
