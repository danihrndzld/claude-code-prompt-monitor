#!/usr/bin/env bash
# Inventario de solo lectura del cluster para decidir cómo desplegar el monitoreo de prompts.
# Requiere oc con sesión abierta:  brew install openshift-cli && oc login https://api.<cluster>:6443
# Uso: ./discovery.sh | tee data/discovery-$(date +%F).txt
set -uo pipefail
command -v oc >/dev/null || { echo "falta oc: brew install openshift-cli"; exit 1; }
oc whoami >/dev/null 2>&1 || { echo "sin sesión: oc login primero"; exit 1; }
sec() { printf '\n== %s ==\n' "$1"; }

sec "Cluster y usuario"
oc version 2>/dev/null | head -3; oc whoami; oc whoami --show-server
oc get clusterversion 2>/dev/null | tail -1

sec "Dominio de Routes (define otel.<dominio> y prompt-logger.<dominio>)"
oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}{"\n"}' 2>/dev/null

sec "Operadores instalados relevantes"
oc get csv -A 2>/dev/null | grep -iE 'opentelemetry|logging|loki|grafana|clickhouse|odf|ocs|noobaa|kong|gpu|tempo|rhods|opendatahub' || echo "(ninguno visible o sin permiso)"

sec "CRDs relevantes"
oc get crd 2>/dev/null | grep -iE 'opentelemetrycollector|lokistack|clusterlogforwarder|grafana|clickhouse|objectbucketclaim|noobaa|kongplugin|datasciencecluster' || echo "(ninguno)"

sec "StorageClasses (PVC del colector y del LokiStack)"
oc get storageclass 2>/dev/null

sec "Object storage: NooBaa y ObjectBucketClaims existentes"
oc get noobaa -A 2>/dev/null; oc get obc -A 2>/dev/null || echo "(sin OBC)"

sec "LokiStacks y colectores OTel ya desplegados"
oc get lokistack -A 2>/dev/null; oc get opentelemetrycollector -A 2>/dev/null

sec "Namespaces candidatos"
oc get ns 2>/dev/null | grep -iE 'monitor|logging|observab|rhoai|redhat-ods|seguridad' || echo "(ninguno con esos nombres)"

sec "OpenShift AI"
oc get datasciencecluster -A 2>/dev/null || echo "(sin RHOAI visible)"

sec "Permisos del usuario actual"
for v in "create namespace" "create deployment -n prompts-monitoreo" "create route -n prompts-monitoreo" \
         "create persistentvolumeclaim -n prompts-monitoreo" "create obc -n prompts-monitoreo" \
         "create lokistack -n prompts-monitoreo" "create networkpolicy -n prompts-monitoreo"; do
  printf '%-52s %s\n' "$v" "$(oc auth can-i $v 2>/dev/null)"
done

sec "Certificado del router (para NODE_EXTRA_CA_CERTS si la CA es interna)"
oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.spec.defaultCertificate.name}{"\n"}' 2>/dev/null || echo "(sin permiso)"
