GKE (Standard) + Workload Identity Federation (WIF) + External Secrets Operator (ESO v0.18 o superior) + Argo CD con IP estática

Versión v2 — todas las variables llevan sufijo \_V2 para no chocar con tu primer entorno.
El nombre del clúster (gke-eso) y el PROJECT_NUM no cambian para que el issuer OIDC siga siendo válido.

Recurso Valor v2
PROJECT_ID_V2 noble-anvil-460215-s8
PROJECT_NUM 262274137731 (igual que antes)
CLUSTER_NAME gke-eso (igual)
CLUSTER_LOCATION_V2 us-central1-c
WORKLOAD_POOL_V2 noble-anvil-460215-s8.svc.id.goog
KSA_NAME_V2 / NS external-secrets-v2 / external-secrets-v2
SECRET_NAME_V2 my-secret-v2
K8S_SECRET_NAME_V2 my-k8s-secret-v2
ARGOCD_IP_NAME_V2 argocd-ip-v2
ARGOCD_IP_V2 (se obtiene tras reservar)

Uso de WIF sin GSA
Seguimos la opción “KSA como principal IAM”. Así evitamos los problemas de impersonación y el rol serviceAccountTokenCreator.

⸻

Índice rápido 1. Limpieza total (rollback) 2. Variables & comprobaciones iniciales 3. Crear clúster con WIF 4. Reservar la IP fija de Argo CD 5. ESO: instalar, validar CRDs y Pods 6. Crear SecretStore (solo projectID) 7. Crear y validar secreto en Secret Manager 8. Crear ExternalSecret y verificar sincronización 9. Desplegar Argo CD con la IP estática y usando el SecretStore 10. Validadores rápidos

⸻

1 · Rollback completo (opcional)

gcloud container clusters delete gke-eso \
 --zone us-central1-c --project noble-anvil-460215-s8 --quiet
gcloud compute addresses delete argocd-ip-v2 \
 --region us-central1 --project noble-anvil-460215-s8 --quiet
kubectl delete ns external-secrets-v2 argocd --ignore-not-found
gcloud secrets delete my-secret-v2 --project noble-anvil-460215-s8 --quiet

Por qué – Dejamos el proyecto limpio para probar los pasos desde cero.

⸻

2 · Variables y primer chequeo

export PROJECT_ID_V2="noble-anvil-460215-s8"
export PROJECT_NUM="262274137731" # NO se cambia
export CLUSTER_NAME="gke-eso"
export CLUSTER_LOCATION_V2="us-central1-c"
export WORKLOAD_POOL_V2="${PROJECT_ID_V2}.svc.id.goog"

export KSA_NAME_V2="external-secrets-v2"
export KSA_NAMESPACE_V2="external-secrets-v2"

export SECRET_NAME_V2="my-secret-v2"
export K8S_SECRET_NAME_V2="my-k8s-secret-v2"

export ARGOCD_IP_NAME_V2="argocd-ip-v2"

Validación

gcloud config set project $PROJECT_ID_V2
gcloud config list --format="value(core.project)" # → noble-anvil-460215-s8

⸻

3 · Crear clúster (WIF habilitado)

gcloud container clusters create $CLUSTER_NAME \
  --zone $CLUSTER_LOCATION_V2 \
  --workload-pool=$WORKLOAD_POOL_V2 \
 --num-nodes 2 --machine-type e2-medium \
 --enable-ip-alias \
 --project $PROJECT_ID_V2

gcloud container clusters get-credentials $CLUSTER_NAME \
 --zone $CLUSTER_LOCATION_V2 --project $PROJECT_ID_V2

Por qué – Activar WIF a nivel de clúster es requisito para que KSA emita tokens federados.

Validación

gcloud container clusters describe $CLUSTER_NAME \
 --zone $CLUSTER_LOCATION_V2 --format="value(workloadIdentityConfig.workloadPool)"

# → noble-anvil-460215-s8.svc.id.goog

⸻

4 · Reservar IP estática para Argo CD

gcloud compute addresses create $ARGOCD_IP_NAME_V2 \
  --region us-central1 --project $PROJECT_ID_V2
export ARGOCD_IP_V2=$(gcloud compute addresses describe $ARGOCD_IP_NAME_V2 \
 --region us-central1 --project $PROJECT_ID_V2 --format="value(address)")
echo "🚀 IP fija ArgoCD v2: $ARGOCD_IP_V2"

Por qué – Evita que la URL de Argo CD cambie en cada upgrade del Service.

⸻

5 · Instalar External Secrets Operator v0.18+

helm repo add external-secrets <https://charts.external-secrets.io>
helm repo update
kubectl create namespace $KSA_NAMESPACE_V2

helm upgrade --install external-secrets-v2 external-secrets/external-secrets \
 --namespace $KSA_NAMESPACE_V2 \
  --set installCRDs=true \
  --set serviceAccount.create=true \
  --set serviceAccount.name=$KSA_NAME_V2

Por qué – Creamos KSA dentro del chart, así Helm gestiona su ciclo de vida.

Validación

kubectl get deployment -n $KSA_NAMESPACE_V2 # pods Running
kubectl get crds | grep externalsecrets # CRDs presentes

⸻

6 · Crear SecretStore (sin auth)

# secretstore-v2.yaml

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

Por qué – Con el modelo “KSA como principal”, ESO usará el token federado del pod sin necesitar más datos de auth:.

⸻

7 · Crear el secreto en Secret Manager

echo -n "super-secret-value-v2" | gcloud secrets create $SECRET_NAME_V2 \
 --replication-policy="automatic" \
 --data-file=- --project $PROJECT_ID_V2
gcloud secrets versions list $SECRET_NAME_V2 --project $PROJECT_ID_V2

# → versión 1 ENABLED

Por qué – Debe existir una versión ENABLED o ESO fallará con PermissionDenied/NOT_FOUND.

⸻

8 · Asignar rol secretAccessor al KSA federado

gcloud projects add-iam-policy-binding $PROJECT_ID_V2 \
  --member="principal://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/${PROJECT_ID_V2}.svc.id.goog/subject/ns/${KSA_NAMESPACE_V2}/sa/${KSA_NAME_V2}" \
 --role="roles/secretmanager.secretAccessor"

Validación

gcloud projects get-iam-policy $PROJECT_ID_V2 --format json \
 | grep -A2 secretAccessor | grep $KSA_NAME_V2

# → línea con ns/external-secrets-v2/sa/external-secrets-v2

⸻

9 · Crear ExternalSecret

# external-secret-v2.yaml

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
data: - secretKey: my-secret-key
remoteRef:
key: ${SECRET_NAME_V2}

envsubst < external-secret-v2.yaml | kubectl apply -f -

Validación (sincronía)

kubectl wait externalsecret my-secret \
 -n $KSA_NAMESPACE_V2 \
 --for=condition=Ready=True --timeout=60s

kubectl get secret $K8S_SECRET_NAME_V2 -n $KSA_NAMESPACE_V2 \
 -o jsonpath='{.data.my-secret-key}' | base64 -d && echo

# → super-secret-value-v2

Si wait expira, revisa con
kubectl describe externalsecret my-secret -n $KSA_NAMESPACE_V2

⸻

10 · Instalar Argo CD con IP fija y consumir secretos

10.1 Helm values

argocd-values-v2.yaml

server:
service:
type: LoadBalancer
loadBalancerIP: ${ARGOCD_IP_V2}

configs:
secret: # utiliza el mismo SecretStore si quisieras sincronizar creds
create: false

helm repo add argo <https://argoproj.github.io/argo-helm>
helm repo update
kubectl create namespace argocd

envsubst < argocd-values-v2.yaml \
 | helm upgrade --install argo-cd-v2 argo/argo-cd -n argocd -f -

Validación

kubectl get svc argo-cd-v2-server -n argocd -o wide | grep $ARGOCD_IP_V2
kubectl -n argocd get secret argo-cd-v2-initial-admin-secret \
 -o jsonpath='{.data.password}' | base64 -d && echo

# Accede a https://$ARGOCD_IP_V2

⸻

11 · Validadores rápidos en un script

validate-wif-v2.sh

# !/usr/bin/env bash

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

⸻

12 · Resumen de “por qué” cada paso

Paso Razón
Clúster con --workload-pool Activa WIF para que los pods obtengan identidades OIDC.
KSA dedicada Principio de menor privilegio; solo ESO necesita leer secretos.
Rol secretAccessor al KSA federado Otorga permiso mínimo para secretmanager.versions.access.
No usamos GSA La versión ≥ 0.18 de ESO soporta tokens directos STS, reduciendo IAM.
SecretStore sin auth ESO toma las credenciales del pod (federación).
Validaciones tras cada paso Detectan de inmediato: • permisos faltantes • secreto inexistente • CRD faltante
IP estática Mantiene URL constante de Argo CD entre upgrades.

⸻

Con esta guía v2, alineada a la documentación oficial y a todas las lecciones aprendidas, podrás crear, validar, depurar y recrear el stack completo en tu proyecto sin confusión con la versión anterior.
# argocd-gke-wif
