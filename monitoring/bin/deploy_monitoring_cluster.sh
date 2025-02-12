#! /bin/bash

# Copyright © 2020, SAS Institute Inc., Cary, NC, USA.  All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

cd "$(dirname $BASH_SOURCE)/../.."
source monitoring/bin/common.sh
source bin/service-url-include.sh

if [ "$OPENSHIFT_CLUSTER" == "true" ]; then
  if [ "${CHECK_OPENSHIFT_CLUSTER:-true}" == "true" ]; then
    log_error "This script should not be run on OpenShift clusters"
    log_error "Run monitoring/bin/deploy_monitoring_openshift.sh instead"
    exit 1
  fi
fi

source bin/tls-include.sh
if verify_cert_manager $MON_NS prometheus alertmanager grafana; then
  log_debug "cert-manager check OK"
else
  log_error "cert-manager is required but is not available"
  exit 1
fi

helm2ReleaseCheck v4m-$MON_NS
helm2ReleaseCheck prometheus-$MON_NS
checkDefaultStorageClass

export HELM_DEBUG="${HELM_DEBUG:-false}"
export NGINX_NS="${NGINX_NS:-ingress-nginx}"

PROM_OPER_USER_YAML="${PROM_OPER_USER_YAML:-$USER_DIR/monitoring/user-values-prom-operator.yaml}"
if [ ! -f "$PROM_OPER_USER_YAML" ]; then
  log_debug "[$PROM_OPER_USER_YAML] not found. Using $TMP_DIR/empty.yaml"
  PROM_OPER_USER_YAML=$TMP_DIR/empty.yaml
fi

if [ "$HELM_DEBUG" == "true" ]; then
  helmDebug="--debug"
fi

if [ -z "$(kubectl get ns $MON_NS -o name 2>/dev/null)" ]; then
  kubectl create ns $MON_NS
fi

set -e
log_notice "Deploying monitoring to the [$MON_NS] namespace..."

# Add the prometheus-community helm repo
helmRepoAdd prometheus-community https://prometheus-community.github.io/helm-charts
log_info "Updating helm repositories..."
helm repo update

istioValuesFile=$TMP_DIR/empty.yaml
# Istio - Federate data from Istio's Prometheus instance
if [ "$ISTIO_ENABLED" == "true" ]; then
  log_info "Including Istio metric federation"
  istioValuesFile=$TMP_DIR/values-prom-operator-tmp.yaml
else
  log_debug "ISTIO_ENABLED flag not set"
  log_debug "Skipping deployment of federated scrape of Istio Prometheus instance"
fi

# Elasticsearch Datasource for Grafana
ELASTICSEARCH_DATASOURCE="${ELASTICSEARCH_DATASOURCE:-false}"
if [ "$ELASTICSEARCH_DATASOURCE" == "true" ]; then
  log_info "Provisioning Elasticsearch datasource for Grafana..."
  kubectl delete secret -n $MON_NS --ignore-not-found grafana-datasource-es
  kubectl create secret generic -n $MON_NS grafana-datasource-es --from-file monitoring/grafana-datasource-es.yaml
  kubectl label secret -n $MON_NS grafana-datasource-es grafana_datasource=1 sas.com/monitoring-base=kube-viya-monitoring
else
  log_debug "ELASTICSEARCH_DATASOURCE not set"
  log_debug "Skipping creation of Elasticsearch datasource for Grafana"
fi

# Check if Prometheus Operator CRDs are already installed
PROM_OPERATOR_CRD_UPDATE=${PROM_OPERATOR_CRD_UPDATE:-true}
PROM_OPERATOR_CRD_VERSION=${PROM_OPERATOR_CRD_VERSION:-v0.47.0}
if [ "$PROM_OPERATOR_CRD_UPDATE" == "true" ]; then
  log_info "Updating Prometheus Operator custom resource definitions"
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml
  kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/$PROM_OPERATOR_CRD_VERSION/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml
else
  log_debug "Prometheus Operator CRD update disabled"
fi

# Optional workload node placement support
MON_NODE_PLACEMENT_ENABLE=${MON_NODE_PLACEMENT_ENABLE:-${NODE_PLACEMENT_ENABLE:-false}}
if [ "$MON_NODE_PLACEMENT_ENABLE" == "true" ]; then
  log_info "Enabling monitoring components for workload node placement"
  wnpValuesFile="monitoring/node-placement/values-prom-operator-wnp.yaml"
else
  log_debug "Workload node placement support is disabled"
  wnpValuesFile="$TMP_DIR/empty.yaml"
fi

# Optional TLS Support
tlsValuesFile=$TMP_DIR/empty.yaml
if [ "$TLS_ENABLE" == "true" ]; then
  apps=( prometheus alertmanager grafana )
  create_tls_certs $MON_NS monitoring ${apps[@]}

  tlsValuesFile=monitoring/tls/values-prom-operator-tls.yaml
  log_debug "Including TLS response file $tlsValuesFile"

  log_info "Provisioning TLS-enabled Prometheus datasource for Grafana..."
  kubectl delete cm -n $MON_NS --ignore-not-found grafana-datasource-prom-https
  kubectl create cm -n $MON_NS grafana-datasource-prom-https --from-file monitoring/tls/grafana-datasource-prom-https.yaml
  kubectl label cm -n $MON_NS grafana-datasource-prom-https grafana_datasource=1 sas.com/monitoring-base=kube-viya-monitoring

  # node-exporter TLS
  log_info "Enabling Prometheus node-exporter for TLS..."
  kubectl delete cm -n $MON_NS node-exporter-tls-web-config --ignore-not-found
  sleep 1
  kubectl create cm -n $MON_NS node-exporter-tls-web-config --from-file monitoring/tls/node-exporter-web.yaml
  kubectl label cm -n $MON_NS node-exporter-tls-web-config sas.com/monitoring-base=kube-viya-monitoring
fi

nodePortValuesFile=$TMP_DIR/empty.yaml
PROM_NODEPORT_ENABLE=${PROM_NODEPORT_ENABLE:-false}
if [ "$PROM_NODEPORT_ENABLE" == "true" ]; then
  log_debug "Enabling NodePort access for Prometheus and Alertmanager..."
  nodePortValuesFile=monitoring/values-prom-nodeport.yaml
fi

if helm3ReleaseExists prometheus-operator $MON_NS; then
  promRelease=prometheus-operator
  promName=prometheus-operator
else
  promRelease=v4m-prometheus-operator
  promName=v4m
fi
log_info "User response file: [$PROM_OPER_USER_YAML]"
log_info "Deploying the Kube Prometheus Stack. This may take a few minutes..."
if helm3ReleaseExists $promRelease $MON_NS; then
  log_info "Upgrading via Helm...($(date) - timeout 20m)"
else
  grafanaPwd="$GRAFANA_ADMIN_PASSWORD"
  if [ "$grafanaPwd" == "" ]; then
    log_debug "Generating random Grafana admin password..."
    showPass="true"
    grafanaPwd="$(randomPassword)"
  fi
  log_info "Installing via Helm...($(date) - timeout 20m)"
fi
KUBE_PROM_STACK_CHART_VERSION=${KUBE_PROM_STACK_CHART_VERSION:-15.0.0}
helm $helmDebug upgrade --install $promRelease \
  --namespace $MON_NS \
  -f monitoring/values-prom-operator.yaml \
  -f $istioValuesFile \
  -f $tlsValuesFile \
  -f $nodePortValuesFile \
  -f $wnpValuesFile \
  -f $PROM_OPER_USER_YAML \
  --atomic \
  --timeout 20m \
  --set nameOverride=$promName \
  --set fullnameOverride=$promName \
  --set prometheus-node-exporter.fullnameOverride=$promName-node-exporter \
  --set kube-state-metrics.fullnameOverride=$promName-kube-state-metrics \
  --set grafana.fullnameOverride=$promName-grafana \
  --set grafana.adminPassword="$grafanaPwd" \
  --version $KUBE_PROM_STACK_CHART_VERSION \
  prometheus-community/kube-prometheus-stack

sleep 2

if [ "$TLS_ENABLE" == "true" ]; then
  log_info "Patching Grafana ServiceMonitor for TLS..."
  kubectl patch servicemonitor -n $MON_NS $promName-grafana --type=json \
    -p='[{"op": "replace", "path": "/spec/endpoints/0/scheme", "value":"https"},{"op": "replace", "path": "/spec/endpoints/0/tlsConfig", "value":{}},{"op": "replace", "path": "/spec/endpoints/0/tlsConfig/insecureSkipVerify", "value":true}]'
fi

log_info "Deploying cluster ServiceMonitors..."

# NGINX
set +e
kubectl get ns $NGINX_NS 2>/dev/null
if [ $? == 0 ]; then
  nginxFound=true
fi
set -e

if [ "$nginxFound" == "true" ]; then
  log_info "NGINX found. Deploying podMonitor to [$NGINX_NS] namespace..."
  kubectl apply -n $NGINX_NS -f monitoring/monitors/kube/podMonitor-nginx.yaml 2>/dev/null
fi

# Eventrouter ServiceMonitor
kubectl apply -n $MON_NS -f monitoring/monitors/kube/podMonitor-eventrouter.yaml 2>/dev/null

# Elasticsearch ServiceMonitor
kubectl apply -n $MON_NS -f monitoring/monitors/logging/serviceMonitor-elasticsearch.yaml

# Fluent Bit ServiceMonitors
kubectl apply -n $MON_NS -f monitoring/monitors/logging/serviceMonitor-fluent-bit.yaml
kubectl apply -n $MON_NS -f monitoring/monitors/logging/serviceMonitor-fluent-bit-v2.yaml

# Rules
log_info "Adding Prometheus recording rules..."
for f in monitoring/rules/viya/rules-*.yaml; do
  kubectl apply -n $MON_NS -f $f
done

echo ""
monitoring/bin/deploy_dashboards.sh

set +e
# call function to get HTTP/HTTPS ports from ingress controller
get_ingress_ports

# get URLs for Grafana, Prometheus and AlertManager
gf_url=$(get_service_url $MON_NS v4m-grafana  "/" "false")
# pr_url=$(get_url $MON_NS v4m-prometheus  "/" "false")
# am_url=$(get_url $MON_NS v4m-alertmanager  "/" "false")
set -e

if ! deployV4MInfo "$MON_NS"; then
  log_warn "Unable to update SAS Viya Monitoring version info"
fi

# Print URL to access web apps
log_notice ""
log_notice "================================================================================"
log_notice "==                    Accessing the monitoring applications                   =="
log_notice "==                                                                            =="
log_notice "== ***GRAFANA***                                                              =="
if [ ! -z "$gf_url" ]; then
   log_notice "==  You can access Grafana via the following URL:                             =="
   log_notice "==   $gf_url  =="
   log_notice "==                                                                            =="
else
   log_notice "== It was not possible to determine the URL needed to access Grafana. Note    =="
   log_notice "== that this is not necessarily a sign of a problem; it may only reflect an   =="
   log_notice "== ingress or network access configuration that this script does not handle.  =="
   log_notice "==                                                                            =="
fi
log_notice "== Note: These URLs may be incorrect if your ingress and/or other network     =="
log_notice "==       configuration includes options this script does not handle.          =="
log_notice "================================================================================"
log_notice ""
echo ""

log_notice "Successfully deployed components to the [$MON_NS] namespace"
if [ "$showPass" == "true" ]; then
  # Find the grafana pod
  grafanaPod="$(kubectl get po -n $MON_NS -l app.kubernetes.io/name=grafana --template='{{range .items}}{{.metadata.name}}{{end}}')"

  log_notice ""
  log_notice "Generated Grafana admin password is: $grafanaPwd"
  log_notice "Change the password at any time by running (replace password):"
  log_notice "kubectl exec -n $MON_NS $grafanaPod -c grafana -- bin/grafana-cli admin reset-admin-password myNewPassword"
fi


