#!/usr/bin/env bash

#Description: Kyma Integration plan on GKE. This scripts implements a pipeline that consists of many steps. The purpose is to install and test Kyma on real GKE cluster.
#
#
#Expected vars:
#
# - REPO_OWNER - Set up by prow, repository owner/organization
# - REPO_NAME - Set up by prow, repository name
# - BUILD_TYPE - Set up by prow, pr/master/release
# - DOCKER_PUSH_REPOSITORY - Docker repository hostname
# - DOCKER_PUSH_DIRECTORY - Docker "top-level" directory (with leading "/")
# - KYMA_PROJECT_DIR - directory path with Kyma sources to use for installation
# - CLOUDSDK_CORE_PROJECT - GCP project for all GCP resources used during execution (Service Account, IP Address, DNS Zone, image registry etc.)
# - CLOUDSDK_COMPUTE_REGION - GCP compute region
# - CLOUDSDK_DNS_ZONE_NAME - GCP zone name (not its DNS name!)
# - GOOGLE_APPLICATION_CREDENTIALS - GCP Service Account key file path
# - MACHINE_TYPE (optional): GKE machine type
# - CLUSTER_VERSION (optional): GKE cluster version
# - KYMA_ARTIFACTS_BUCKET: GCP bucket
#
#Permissions: In order to run this script you need to use a service account with permissions equivalent to the following GCP roles:
# - Compute Admin
# - Kubernetes Engine Admin
# - Kubernetes Engine Cluster Admin
# - DNS Administrator
# - Service Account User
# - Storage Admin
# - Compute Network Admin

set -o errexit

discoverUnsetVar=false

for var in REPO_OWNER REPO_NAME DOCKER_PUSH_REPOSITORY KYMA_PROJECT_DIR CLOUDSDK_CORE_PROJECT CLOUDSDK_COMPUTE_REGION GOOGLE_APPLICATION_CREDENTIALS KYMA_ARTIFACTS_BUCKET GCR_PUSH_GOOGLE_APPLICATION_CREDENTIALS; do
    if [ -z "${!var}" ] ; then
        echo "ERROR: $var is not set"
        discoverUnsetVar=true
    fi
done
if [ "${discoverUnsetVar}" = true ] ; then
    exit 1
fi

#Exported variables
export TEST_INFRA_SOURCES_DIR="${KYMA_PROJECT_DIR}/test-infra"
export KYMA_SOURCES_DIR="${KYMA_PROJECT_DIR}/kyma"
export TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS="${TEST_INFRA_SOURCES_DIR}/prow/scripts/cluster-integration/helpers"
# shellcheck disable=SC1090
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/library.sh"

#!Put cleanup code in this function!
cleanup() {
    #!!! Must be at the beginning of this function !!!
    EXIT_STATUS=$?

    if [ "${ERROR_LOGGING_GUARD}" = "true" ]; then
        shout "AN ERROR OCCURED! Take a look at preceding log entries."
        echo
    fi

    #Turn off exit-on-error so that next step is executed even if previous one fails.
    set +e

    if [ -n "${CLEANUP_CLUSTER}" ]; then
        shout "Deprovision cluster: \"${CLUSTER_NAME}\""
        date

        #save disk names while the cluster still exists to remove them later
        DISKS=$(kubectl get pvc --all-namespaces -o jsonpath="{.items[*].spec.volumeName}" | xargs -n1 echo)
        export DISKS

        #Delete cluster
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/deprovision-gke-cluster.sh"

        #Delete orphaned disks
        #shout "Delete orphaned PVC disks..."
        #date
        #"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/delete-disks.sh"
    fi

    if [ -n "${CLEANUP_DOCKER_IMAGE}" ]; then
        shout "Delete temporary Kyma-Installer Docker image"
        date
        "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/delete-image.sh"
    fi

    MSG=""
    if [[ ${EXIT_STATUS} -ne 0 ]]; then MSG="(exit status: ${EXIT_STATUS})"; fi
    shout "Job is finished ${MSG}"
    date
    set -e

    exit "${EXIT_STATUS}"
}

trap cleanup EXIT INT

if [[ "${BUILD_TYPE}" == "pr" ]]; then
    shout "Execute Job Guard"
    "${TEST_INFRA_SOURCES_DIR}/development/jobguard/scripts/run.sh"
fi

# Enforce lowercase
readonly REPO_OWNER=$(echo "${REPO_OWNER}" | tr '[:upper:]' '[:lower:]')
export REPO_OWNER
readonly REPO_NAME=$(echo "${REPO_NAME}" | tr '[:upper:]' '[:lower:]')
export REPO_NAME

RANDOM_NAME_SUFFIX=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom | head -c10)

if [[ "$BUILD_TYPE" == "pr" ]]; then
    # In case of PR, operate on PR number
    readonly COMMON_NAME_PREFIX="gkeint-pr"
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${PULL_NUMBER}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    KYMA_INSTALLER_IMAGE="${DOCKER_PUSH_REPOSITORY}${DOCKER_PUSH_DIRECTORY}/gke-integration/${REPO_OWNER}/${REPO_NAME}:PR-${PULL_NUMBER}"
    export KYMA_INSTALLER_IMAGE
elif [[ "$BUILD_TYPE" == "release" ]]; then
    readonly COMMON_NAME_PREFIX="gkeint-rel"
    readonly SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
    readonly RELEASE_VERSION=$(cat "${SCRIPT_DIR}/../../RELEASE_VERSION")
    shout "Reading release version from RELEASE_VERSION file, got: ${RELEASE_VERSION}"
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
else
    # Otherwise (master), operate on triggering commit id
    readonly COMMON_NAME_PREFIX="gkeint-commit"
    readonly COMMIT_ID=$(cd "$KYMA_SOURCES_DIR" && git rev-parse --short HEAD)
    COMMON_NAME=$(echo "${COMMON_NAME_PREFIX}-${COMMIT_ID}-${RANDOM_NAME_SUFFIX}" | tr "[:upper:]" "[:lower:]")
    KYMA_INSTALLER_IMAGE="${DOCKER_PUSH_REPOSITORY}${DOCKER_PUSH_DIRECTORY}/gke-integration/${REPO_OWNER}/${REPO_NAME}:COMMIT-${COMMIT_ID}"
    export KYMA_INSTALLER_IMAGE
fi


### Cluster name must be less than 40 characters!
export CLUSTER_NAME="${COMMON_NAME}"

export GCLOUD_NETWORK_NAME="${COMMON_NAME_PREFIX}-net"
export GCLOUD_SUBNET_NAME="${COMMON_NAME_PREFIX}-subnet"

### For provision-gke-cluster.sh
export GCLOUD_PROJECT_NAME="${CLOUDSDK_CORE_PROJECT}"
export GCLOUD_COMPUTE_ZONE="${CLOUDSDK_COMPUTE_ZONE}"

#Local variables
KYMA_SCRIPTS_DIR="${KYMA_SOURCES_DIR}/installation/scripts"
KYMA_RESOURCES_DIR="${KYMA_SOURCES_DIR}/installation/resources"

INSTALLER_YAML="${KYMA_RESOURCES_DIR}/installer.yaml"
INSTALLER_CR="${KYMA_RESOURCES_DIR}/installer-cr-cluster.yaml.tpl"

#Used to detect errors for logging purposes
ERROR_LOGGING_GUARD="true"

shout "Authenticate"
date
init

if [[ "$BUILD_TYPE" != "release" ]]; then
    shout "Build Kyma-Installer Docker image"
    date
    CLEANUP_DOCKER_IMAGE="true"
    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-image.sh"
fi

NETWORK_EXISTS=$("${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/network-exists.sh")
if [ "$NETWORK_EXISTS" -gt 0 ]; then
    shout "Create ${GCLOUD_NETWORK_NAME} network with ${GCLOUD_SUBNET_NAME} subnet"
    date
    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-network-with-subnet.sh"
else
    shout "Network ${GCLOUD_NETWORK_NAME} exists"
fi


shout "Provision cluster: \"${CLUSTER_NAME}\""
date
export GCLOUD_SERVICE_KEY_PATH="${GOOGLE_APPLICATION_CREDENTIALS}"
if [ -z "$MACHINE_TYPE" ]; then
      export MACHINE_TYPE="${DEFAULT_MACHINE_TYPE}"
fi
if [ -z "${CLUSTER_VERSION}" ]; then
      export CLUSTER_VERSION="${DEFAULT_CLUSTER_VERSION}"
fi
CLEANUP_CLUSTER=""
"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/provision-gke-cluster.sh"

shout "Apply Kyma config"
date

kubectl create namespace "kyma-installer"

"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "installation-config-overrides" \
    --data "global.domainName=${DOMAIN}" \
    --data "global.loadBalancerIP=${GATEWAY_IP_ADDRESS}"

"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "core-test-ui-acceptance-overrides" \
    --data "test.acceptance.ui.logging.enabled=true" \
    --label "component=core"

"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "cluster-certificate-overrides" \
    --data "global.tlsCrt=${TLS_CERT}" \
    --data "global.tlsKey=${TLS_KEY}"

cat << EOF > "$PWD/kyma_istio_operator"
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  components:
    ingressGateways:
      - name: istio-ingressgateway
        k8s:
          service:
            loadBalancerIP: ${GATEWAY_IP_ADDRESS}
            type: LoadBalancer
EOF

"${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map-file.sh" --name "istio-overrides" \
    --label "component=istio" \
    --file "$PWD/kyma_istio_operator"

if [[ "$BUILD_TYPE" == "release" ]]; then
    echo "Use released artifacts"
    gsutil cp "${KYMA_ARTIFACTS_BUCKET}/${RELEASE_VERSION}/kyma-installer-cluster.yaml" /tmp/kyma-gke-integration/downloaded-installer.yaml
    kubectl apply -f /tmp/kyma-gke-integration/downloaded-installer.yaml
else
    echo "Manual concatenating yamls"
    "${KYMA_SCRIPTS_DIR}"/concat-yamls.sh "${INSTALLER_YAML}" "${INSTALLER_CR}" \
    | sed -e 's;image: eu.gcr.io/kyma-project/.*/installer:.*$;'"image: ${KYMA_INSTALLER_IMAGE};" \
    | sed -e "s/__VERSION__/0.0.1/g" \
    | sed -e "s/__.*__//g" \
    | kubectl apply -f-
fi

shout "Installation triggered"
date
"${KYMA_SCRIPTS_DIR}"/is-installed.sh --timeout 30m

shout "Test Kyma"
date
"${KYMA_SCRIPTS_DIR}"/testing.sh

shout "Success"

#!!! Must be at the end of the script !!!
ERROR_LOGGING_GUARD="false"
