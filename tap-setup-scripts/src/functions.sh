#!/bin/bash

function banner {
  local line
  # echo ""
  for line in "$@"
  do
    echo "### $line"
  done
  echo ""
}

function message {
  local line
  for line in "$@"
  do
    echo ">>> $line"
  done
}

function fatal {
  message "ERROR: $*"
  exit 1
}

function requireValue {
  local varName

  for varName in $*
  do
    if [[ -z "${!varName}" ]]
    then
      fatal "Variable $varName is missing at line $(caller)"
    fi
  done
}

function fail {
  echo $1 >&2
  exit 1
}

# Wait until there is no (non-error) output from a command
function waitForRemoval {
  local n=1
  local max=5
  local delay=5
  echo "Waiting for $@"
  while [[ -n $("$@" 2> /dev/null || true) ]]
  do
    if [[ $n -lt $max ]]; then
      ((n++))
      echo "Command failed. Attempt $n/$max:"
      sleep $delay;
    else
     fail "The command has failed after $n attempts."
    fi
  done
}

function installTanzuCLI {
  requireValue ESSENTIALS_VERSION TAP_VERSION

  banner "Downloading kapp, secretgen configuration bundle & tanzu cli"

  mkdir -p $DOWNLOADS

  if [[ ! -f $DOWNLOADS/tanzu-cluster-essentials/install.sh ]]
  then
    pivnet login --api-token="$PIVNET_TOKEN"

    ESSENTIALS_FILE_NAME="tanzu-cluster-essentials-linux-$(dpkg --print-architecture)-$ESSENTIALS_VERSION.tgz"

    ESSENTIALS_FILE_ID=$(pivnet product-files \
      -p tanzu-cluster-essentials \
      -r $ESSENTIALS_VERSION \
     --format=json | jq ".[] | select(.name == \"$ESSENTIALS_FILE_NAME\").id" )

    pivnet download-product-files \
      --download-dir $DOWNLOADS \
      --product-slug='tanzu-cluster-essentials' \
      --release-version=$ESSENTIALS_VERSION \
      --product-file-id=$ESSENTIALS_FILE_ID

    mkdir -p $DOWNLOADS/tanzu-cluster-essentials
    tar xvf $DOWNLOADS/$ESSENTIALS_FILE_NAME -C $DOWNLOADS/tanzu-cluster-essentials
    sudo cp $DOWNLOADS/tanzu-cluster-essentials/imgpkg /usr/local/bin/
    sudo cp $DOWNLOADS/tanzu-cluster-essentials/kapp /usr/local/bin/
    sudo cp $DOWNLOADS/tanzu-cluster-essentials/kbld /usr/local/bin/
    sudo cp $DOWNLOADS/tanzu-cluster-essentials/ytt /usr/local/bin/
  else
    echo "tanzu-cluster-essentials already present"
  fi

  TANZU_DIR=$DOWNLOADS/tanzu
  if [[ ! -f /usr/local/bin/tanzu ]]
  then
    mkdir -p $TANZU_DIR
    export TANZU_CLI_NO_INIT=true

    pivnet login --api-token="$PIVNET_TOKEN"

    TANZUCLI_FILE_NAME="tanzu-framework-linux-$(dpkg --print-architecture).tar"
    TANZUCLI_FILE_ID=$(pivnet product-files \
      -p tanzu-application-platform \
      -r $TAP_VERSION \
      --format=json | jq '.[] | select(.name == "tanzu-framework-bundle-linux").id' )

    pivnet download-product-files \
      --download-dir $DOWNLOADS \
      --product-slug='tanzu-application-platform' \
      --release-version=$TAP_VERSION \
      --product-file-id=$TANZUCLI_FILE_ID

    tar xvf $DOWNLOADS/$TANZUCLI_FILE_NAME -C $TANZU_DIR
    export TANZU_CLI_NO_INIT=true
    MOST_RECENT_CLI=$(find $TANZU_DIR/cli/core/ -name tanzu-core-linux_$(dpkg --print-architecture) | xargs ls -t | head -n 1)
    echo "Installing Tanzu CLI"
    sudo install -m 0755 $MOST_RECENT_CLI /usr/local/bin/tanzu
    pushd $TANZU_DIR
    tanzu plugin install --local cli all
    popd
  else
    echo "tanzu-framework-linux already present"
  fi
}

function verifyTools {
  banner "echo all tool versions"

  ytt version
  echo ''
  kapp version
  echo ''
  kbld version
  echo ''
  imgpkg version
  echo ''
  aws --version
  echo ''
  kubectl version --client
  echo ''
  uuidgen --version
  echo ''
  jq --version
  echo ''
  yq --version
  echo ''
  curl --version
  echo ''
  tanzu version
  tanzu plugin list
  echo ''
}

function readUserInputs {
  banner "Reading $INPUTS/user-input-values.yaml"

  AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

  CLUSTER_NAME=$(yq -r .cluster.name $INPUTS/user-input-values.yaml)

  DOMAIN_NAME=$(yq -r .dns.domain_name $INPUTS/user-input-values.yaml)
  ZONE_ID=$(yq -r .dns.zone_id $INPUTS/user-input-values.yaml)

  TANZUNET_REGISTRY_SECRETS_MANAGER_ARN=$(yq -r .tanzunet.secrets.credentials_arn $INPUTS/user-input-values.yaml)
  TANZUNET_REGISTRY_USERNAME=$(aws secretsmanager get-secret-value --secret-id "$TANZUNET_REGISTRY_SECRETS_MANAGER_ARN" --query "SecretString" --output text | jq -r .username)
  TANZUNET_REGISTRY_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$TANZUNET_REGISTRY_SECRETS_MANAGER_ARN" --query "SecretString" --output text | jq -r .password)
  PIVNET_TOKEN=$(aws secretsmanager get-secret-value --secret-id "$TANZUNET_REGISTRY_SECRETS_MANAGER_ARN" --query "SecretString" --output text | jq -r .token)

  TANZUNET_REGISTRY_SERVER=$(yq -r .tanzunet.server $INPUTS/user-input-values.yaml)
  TANZUNET_RELOCATE_IMAGES=$(yq -r .tanzunet.relocate_images $INPUTS/user-input-values.yaml)
  ESSENTIALS_BUNDLE=$(yq -r .cluster_essentials_bundle.bundle $INPUTS/user-input-values.yaml)
  ESSENTIALS_FILE_HASH=$(yq -r .cluster_essentials_bundle.file_hash $INPUTS/user-input-values.yaml)
  ESSENTIALS_VERSION=$(yq -r .cluster_essentials_bundle.version $INPUTS/user-input-values.yaml)

  ESSENTIALS_URI="$ESSENTIALS_BUNDLE@$ESSENTIALS_FILE_HASH"

  TAP_PACKAGE_NAME=$(yq -r .tap.name $INPUTS/user-input-values.yaml)
  TAP_NAMESPACE=$(yq -r .tap.namespace $INPUTS/user-input-values.yaml)
  TAP_REPOSITORY=$(yq -r .tap.repository $INPUTS/user-input-values.yaml)
  TAP_VERSION=$(yq -r .tap.version $INPUTS/user-input-values.yaml)

  TAP_URI="$TAP_REPOSITORY:$TAP_VERSION"

  TAP_ECR_REGISTRY_REPOSITORY=$(yq -r .repositories.tap_packages $INPUTS/user-input-values.yaml)
  ESSENTIALS_ECR_REGISTRY_REPOSITORY=$(yq -r .repositories.cluster_essentials $INPUTS/user-input-values.yaml)
  TBS_ECR_REGISTRY_REPOSITORY=$(yq -r .repositories.build_service $INPUTS/user-input-values.yaml)
  DEV_NAMESPACE_ARN=$(yq -r .repositories.workload.arn $INPUTS/user-input-values.yaml)

  SAMPLE_APP_NAME=$(yq -r .repositories.workload.name $INPUTS/user-input-values.yaml)
  DEVELOPER_NAMESPACE=$(yq -r .repositories.workload.namespace $INPUTS/user-input-values.yaml)
  SAMPLE_APP_ECR_REGISTRY_REPOSITORY=$(yq -r .repositories.workload.repository $INPUTS/user-input-values.yaml)
  SAMPLE_APP_BUNDLE_ECR_REGISTRY_REPOSITORY=$(yq -r .repositories.workload.bundle_repository $INPUTS/user-input-values.yaml)
}

function parseUserInputs {
  requireValue AWS_ACCOUNT AWS_REGION GENERATED INPUTS TANZUNET_REGISTRY_USERNAME TANZUNET_REGISTRY_PASSWORD \
    SAMPLE_APP_ECR_REGISTRY_REPOSITORY

  banner "getting ECR registry credentials"

  ECR_REGISTRY_HOSTNAME=${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com
  ECR_REGISTRY_USERNAME=AWS
  ECR_REGISTRY_PASSWORD=$(aws ecr get-login-password)

  rm -rf $GENERATED
  mkdir -p $GENERATED

  cat $INPUTS/user-input-values.yaml > $GENERATED/user-input-values.yaml

  kubectl apply -f $RESOURCES/metadata-store-ready-only.yaml
  METADATA_STORE_ACCESS_TOKEN=$(kubectl get secret \
    $(kubectl get sa -n metadata-store metadata-store-read-client -o json \
    | jq -r '.secrets[0].name') -n metadata-store -o json \
    | jq -r '.data.token' \
    | base64 -d)

  banner "Generating tap-values.yaml"

  ytt -f $INPUTS/tap-values.yaml -f $GENERATED/user-input-values.yaml \
    --data-value ecr_registry.username=$ECR_REGISTRY_USERNAME \
    --data-value ecr_registry.password=$ECR_REGISTRY_PASSWORD \
    --data-value repositories.workload.server=$(echo $SAMPLE_APP_ECR_REGISTRY_REPOSITORY | cut -d '/' -f1) \
    --data-value repositories.workload.ootb_repo_prefix=$(echo $SAMPLE_APP_ECR_REGISTRY_REPOSITORY | cut -d '/' -f2-3) \
    --data-value tanzunet.username=$TANZUNET_REGISTRY_USERNAME \
    --data-value tanzunet.password=$TANZUNET_REGISTRY_PASSWORD \
    --data-value metadata_store.access_token="Bearer $METADATA_STORE_ACCESS_TOKEN" \
    --ignore-unknown-comments > $GENERATED/tap-values.yaml
}

function installTanzuClusterEssentials {
  requireValue TAP_VERSION ESSENTIALS_ECR_REGISTRY_REPOSITORY \
    ESSENTIALS_FILE_HASH TANZUNET_RELOCATE_IMAGES \
    ECR_REGISTRY_HOSTNAME ECR_REGISTRY_USERNAME ECR_REGISTRY_PASSWORD \
    ESSENTIALS_BUNDLE TANZUNET_REGISTRY_SERVER \
    TANZUNET_REGISTRY_USERNAME TANZUNET_REGISTRY_PASSWORD

  banner "Deploy kapp, secretgen configuration bundle & install tanzu CLI"

  pushd $DOWNLOADS/tanzu-cluster-essentials
  # tanzu-cluster-essentials install.sh script needs INSTALL_BUNDLE & below INSTALL_XXX params

  ESSENTIALS_REGISTRY_REPOSITORY=$ESSENTIALS_BUNDLE
  ESSENTIALS_REGISTRY_HOSTNAME=$TANZUNET_REGISTRY_SERVER
  ESSENTIALS_REGISTRY_USERNAME=$TANZUNET_REGISTRY_USERNAME
  ESSENTIALS_REGISTRY_PASSWORD=$TANZUNET_REGISTRY_PASSWORD

  if [[ $TANZUNET_RELOCATE_IMAGES == "Yes" ]]
  then
    echo "Changed ESSENTIALS_REGISTRY_REPOSITORY to ECR Repository"
    ESSENTIALS_REGISTRY_REPOSITORY=$ESSENTIALS_ECR_REGISTRY_REPOSITORY
    ESSENTIALS_REGISTRY_HOSTNAME=$ECR_REGISTRY_HOSTNAME
    ESSENTIALS_REGISTRY_USERNAME=$ECR_REGISTRY_USERNAME
    ESSENTIALS_REGISTRY_PASSWORD=$ECR_REGISTRY_PASSWORD
  fi

  INSTALL_BUNDLE=$ESSENTIALS_REGISTRY_REPOSITORY@$ESSENTIALS_FILE_HASH \
    INSTALL_REGISTRY_HOSTNAME=$ESSENTIALS_REGISTRY_HOSTNAME \
    INSTALL_REGISTRY_USERNAME=$ESSENTIALS_REGISTRY_USERNAME \
    INSTALL_REGISTRY_PASSWORD=$ESSENTIALS_REGISTRY_PASSWORD ./install.sh --yes
  popd
}

function verifyK8ClusterAccess {
  requireValue CLUSTER_NAME

  banner "Verify EKS Cluster ${CLUSTER_NAME} access"
  aws eks update-kubeconfig --name ${CLUSTER_NAME}
  kubectl config current-context
  kubectl get nodes
}

function createTapNamespace {
  requireValue TAP_NAMESPACE DEVELOPER_NAMESPACE

  banner "Creating $TAP_NAMESPACE namespace"

  (kubectl get ns $TAP_NAMESPACE 2> /dev/null) ||
    kubectl create ns $TAP_NAMESPACE

  banner "Creating $DEVELOPER_NAMESPACE namespace"

  (kubectl get ns $DEVELOPER_NAMESPACE 2> /dev/null) ||
    kubectl create ns $DEVELOPER_NAMESPACE
}

function loadPackageRepository {
  requireValue TAP_REPOSITORY TAP_ECR_REGISTRY_REPOSITORY TAP_VERSION \
  TAP_NAMESPACE TANZUNET_RELOCATE_IMAGES

  TAP_REGISTRY_REPOSITORY=$TAP_REPOSITORY
  if [[ $TANZUNET_RELOCATE_IMAGES == "Yes" ]]
  then
    echo "Changed TAP_REGISTRY_REPOSITORY to ECR Repository"
    TAP_REGISTRY_REPOSITORY=$TAP_ECR_REGISTRY_REPOSITORY
  fi
  banner "Removing any current TAP package repository"

  tanzu package repository delete tanzu-tap-repository -n $TAP_NAMESPACE --yes || true
  waitForRemoval tanzu package repository get tanzu-tap-repository -n $TAP_NAMESPACE -o json

  banner "Adding TAP package repository"

  tanzu package repository add tanzu-tap-repository \
      --url $TAP_REGISTRY_REPOSITORY:$TAP_VERSION \
      --namespace $TAP_NAMESPACE
  tanzu package repository get tanzu-tap-repository --namespace $TAP_NAMESPACE
  while [[ $(tanzu package available list --namespace $TAP_NAMESPACE -o json) == '[]' ]]
  do
    message "Waiting for packages..."
    sleep 5
  done
}

function createTapRegistrySecret {
  requireValue TANZUNET_REGISTRY_USERNAME TANZUNET_REGISTRY_PASSWORD TANZUNET_REGISTRY_SERVER TAP_NAMESPACE

  banner "Creating tap-registry registry secret"

  tanzu secret registry delete tap-registry --namespace $TAP_NAMESPACE -y
  waitForRemoval kubectl get secret tap-registry --namespace $TAP_NAMESPACE -o json

  tanzu secret registry add tap-registry \
    --username "$TANZUNET_REGISTRY_USERNAME" --password "$TANZUNET_REGISTRY_PASSWORD" \
    --server $TANZUNET_REGISTRY_SERVER \
    --export-to-all-namespaces --namespace $TAP_NAMESPACE --yes
}

# This function is not used - can be removed
function createTapECRRegistrySecret {
  requireValue ECR_REGISTRY_USERNAME ECR_REGISTRY_PASSWORD ECR_REGISTRY_HOSTNAME TAP_NAMESPACE

  banner "Creating tap-registry registry secret"

  tanzu secret registry delete tap-registry --namespace $TAP_NAMESPACE -y
  waitForRemoval kubectl get secret tap-registry --namespace $TAP_NAMESPACE -o json

  tanzu secret registry add tap-registry \
    --username "$ECR_REGISTRY_USERNAME" --password "$ECR_REGISTRY_PASSWORD" \
    --server $ECR_REGISTRY_HOSTNAME \
    --export-to-all-namespaces --namespace $TAP_NAMESPACE --yes
}

function tapInstallFull {
  requireValue TAP_PACKAGE_NAME TAP_VERSION TAP_NAMESPACE

  banner "Installing TAP values from $GENERATED/tap-values.yaml..."

  first_time=$(tanzu package installed get $TAP_PACKAGE_NAME -n $TAP_NAMESPACE -o json 2>/dev/null)

  if [[ -z $first_time ]]
  then
    tanzu package install $TAP_PACKAGE_NAME -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file $GENERATED/tap-values.yaml -n $TAP_NAMESPACE || true
  else
    tanzu package installed update $TAP_PACKAGE_NAME -p tap.tanzu.vmware.com -v $TAP_VERSION --values-file $GENERATED/tap-values.yaml -n $TAP_NAMESPACE || true
  fi

  banner "Checking state of all packages"
  local RETRIES=10
  local DELAY=15
  local EXIT="false"

  while [[ $RETRIES -gt 0 && $EXIT == "false" ]]
  do
    echo "Number of RETRIES=$RETRIES"
    EXIT="true"
    rm -rf $GENERATED/tap-packages-installed-list.txt
    tanzu package installed list --namespace $TAP_NAMESPACE -o json |
      jq -r '.[] | (.name + " " + .status)' > $GENERATED/tap-packages-installed-list.txt || true

    while read package status
    do
      if [ "$status" != "Reconcile succeeded" ]
      then
        message "package($package) failed to reconcile ($status), waiting for reconcile"
        # reconcilePackageInstall $TAP_NAMESPACE $package
        # kctrl package installed kick -i $package -n $TAP_NAMESPACE -y
        EXIT="false"
      fi
    done < $GENERATED/tap-packages-installed-list.txt
    ((RETRIES=RETRIES-1))
    sleep $DELAY
  done

  banner "Checking for ERRORs in all packages"
  tanzu package installed list --namespace $TAP_NAMESPACE -o json |
    jq -r '.[] | (.name + " " + .status)' |
    while read package status
    do
      if [ "$status" != "Reconcile succeeded" ]
      then
        message "ERROR: At least one package ($package) failed to reconcile ($status)"
        exit 1
      fi
    done
  banner "TAP Installation is Complete."
}

function tapWorkloadInstallFull {
  requireValue ECR_REGISTRY_USERNAME ECR_REGISTRY_PASSWORD ECR_REGISTRY_HOSTNAME \
    DEVELOPER_NAMESPACE SAMPLE_APP_NAME DEV_NAMESPACE_ARN

  banner "Installing Sample Workload"

  kubectl -n $DEVELOPER_NAMESPACE apply -f $RESOURCES/developer-namespace.yaml
  kubectl -n $DEVELOPER_NAMESPACE apply -f $RESOURCES/pipeline.yaml
  kubectl -n $DEVELOPER_NAMESPACE apply -f $RESOURCES/scan-policy.yaml
  kubectl -n $DEVELOPER_NAMESPACE annotate serviceaccount default eks.amazonaws.com/role-arn=$DEV_NAMESPACE_ARN --overwrite

  tanzu apps workload apply -f $RESOURCES/workload-aws.yaml -n $DEVELOPER_NAMESPACE --yes
}

function tapWorkloadUninstallFull {
  requireValue DEVELOPER_NAMESPACE SAMPLE_APP_NAME

  banner "Deleting workload $SAMPLE_APP_NAME from Developer namespace"
  tanzu apps workload delete $SAMPLE_APP_NAME -n $DEVELOPER_NAMESPACE --yes

  banner "Removing registry-credentials secret from Developer namespace"
  tanzu secret registry delete registry-credentials --namespace $DEVELOPER_NAMESPACE --yes
  waitForRemoval kubectl get secret registry-credentials --namespace $DEVELOPER_NAMESPACE -o json

  kubectl -n $DEVELOPER_NAMESPACE delete -f $RESOURCES/developer-namespace.yaml
  kubectl -n $DEVELOPER_NAMESPACE delete -f $RESOURCES/pipeline.yaml
  kubectl -n $DEVELOPER_NAMESPACE delete -f $RESOURCES/scan-policy.yaml
}

function tapUninstallFull {
  requireValue TAP_PACKAGE_NAME TAP_NAMESPACE

  banner "Uninstalling TAP..."
  tanzu package installed delete $TAP_PACKAGE_NAME -n $TAP_NAMESPACE --yes
  waitForRemoval tanzu package installed get $TAP_PACKAGE_NAME -n $TAP_NAMESPACE -o json
  kubectl delete -f $RESOURCES/metadata-store-ready-only.yaml
}

function deleteTapRegistrySecret {
  requireValue TAP_NAMESPACE

  banner "Removing tap-registry registry secret"

  tanzu secret registry delete tap-registry --namespace $TAP_NAMESPACE -y
  waitForRemoval kubectl get secret tap-registry --namespace $TAP_NAMESPACE -o json
}

function deletePackageRepository {
  requireValue TAP_NAMESPACE

  banner "Removing current TAP package repository"

  tanzu package repository delete tanzu-tap-repository -n $TAP_NAMESPACE --yes
  waitForRemoval tanzu package repository get tanzu-tap-repository -n $TAP_NAMESPACE -o json
}

function deleteTanzuClusterEssentials {

  banner "Removing kapp-controller & secretgen-controller"
  pushd $DOWNLOADS/tanzu-cluster-essentials
  ./uninstall.sh --yes
  popd
}

function deleteTapNamespace {
  requireValue TAP_NAMESPACE

  banner "Removing Developer namespace"
  kubectl delete ns $DEVELOPER_NAMESPACE
  waitForRemoval kubectl get ns $DEVELOPER_NAMESPACE -o json

  banner "Removing TAP namespace"
  kubectl delete namespace $TAP_NAMESPACE
  waitForRemoval kubectl get namespace $TAP_NAMESPACE -o json
}


function relocateTAPPackages {
  # Relocate the images with the Carvel tool imgpkg
  # ECR_REPOSITORY to be pre-created

  requireValue TANZUNET_REGISTRY_USERNAME TANZUNET_REGISTRY_PASSWORD TANZUNET_REGISTRY_SERVER \
    ESSENTIALS_URI ESSENTIALS_ECR_REGISTRY_REPOSITORY \
    TAP_URI TAP_ECR_REGISTRY_REPOSITORY

  banner "Relocating images, this will take time in minutes (30-45min)..."

  # Replace “docker login” with IMGPKG_REGISTRY_HOSTNAME_0;
  # see details https://carvel.dev/imgpkg/docs/v0.29.0/auth/#via-environment-variables.

  export IMGPKG_REGISTRY_HOSTNAME_0="$TANZUNET_REGISTRY_SERVER"
  export IMGPKG_REGISTRY_USERNAME_0="$TANZUNET_REGISTRY_USERNAME"
  export IMGPKG_REGISTRY_PASSWORD_0="$TANZUNET_REGISTRY_PASSWORD"

  # --concurrency 2 or 1 is required for ECR
  echo "Relocating Tanzu Cluster Essentials Bundle"
  imgpkg copy --concurrency 2 -b ${ESSENTIALS_URI} --to-repo ${ESSENTIALS_ECR_REGISTRY_REPOSITORY}

  echo "Relocating TAP packages"
  imgpkg copy --concurrency 1 -b ${TAP_URI} --to-repo ${TAP_ECR_REGISTRY_REPOSITORY}
  echo "Ignore the non-distributable skipped layer warning- non-issue"
}

function printOutputParams {
  # envoy loadbalancer ip
  requireValue INPUTS GENERATED DOMAIN_NAME ZONE_ID

  elb_hostname=$(kubectl get svc envoy -n tanzu-system-ingress -o jsonpath='{ .status.loadBalancer.ingress[0].hostname }')
  echo "Create Route53 DNS CNAME record for *.$DOMAIN_NAME with $elb_hostname"

  pushd $GENERATED
  cat <<EOF > ./tap-gui-route53-wildcard-resource-record-set-config.json
{
  "Comment": "UPSERT TAP GUI records",
  "Changes": [
    {
      "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "*.$DOMAIN_NAME",
          "Type": "CNAME",
          "TTL": 300,
        "ResourceRecords": [{ "Value": "$elb_hostname"}]
      }
    }
  ]
}
EOF
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "file://./tap-gui-route53-wildcard-resource-record-set-config.json"
  popd

  tap_gui_url=$(yq -r .tap_gui.app_config.backend.baseUrl $GENERATED/tap-values.yaml)
  echo "TAP GUI URL $tap_gui_url"
}

function deleteRoute53Record {
  # envoy loadbalancer ip
  requireValue GENERATED DOMAIN_NAME ZONE_ID

  elb_hostname=$(kubectl get svc envoy -n tanzu-system-ingress -o jsonpath='{ .status.loadBalancer.ingress[0].hostname }')
  echo "Delete Route53 DNS CNAME record for *.$DOMAIN_NAME with $elb_hostname"

  pushd $GENERATED
  cat <<EOF > ./tap-gui-route53-wildcard-resource-record-delete-config.json
{
  "Comment": "DELETE TAP GUI records",
  "Changes": [
    {
      "Action": "DELETE",
        "ResourceRecordSet": {
          "Name": "*.$DOMAIN_NAME",
          "Type": "CNAME",
          "TTL": 300,
        "ResourceRecords": [{ "Value": "$elb_hostname"}]
      }
    }
  ]
}
EOF
  aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch "file://./tap-gui-route53-wildcard-resource-record-delete-config.json"
  popd
}

function runTestCases {
  requireValue DEVELOPER_NAMESPACE SAMPLE_APP_NAME  DOMAIN_NAME

  TAP_GUI_URL="http://tap-gui.${DOMAIN_NAME}"
  WORKLOAD_URL="http://${SAMPLE_APP_NAME}.${DEVELOPER_NAMESPACE}.${DOMAIN_NAME}"

  echo "Running Tests..."
  echo TAP_GUI_URL $TAP_GUI_URL
  echo WORKLOAD_URL $WORKLOAD_URL

  #test-1:
  rx_str=`curl -LI $TAP_GUI_URL  -o /dev/null -w '%{http_code}\n' -s`
  expected_str="200"

  echo "Test1: Access TAP GUI"
  if [[ "$rx_str" == "$expected_str" ]]
  then
    echo "Test1 Pass"
  else
    echo "Test1 Fail"
  fi

  #test-2:
  rx_str=`curl -LI  $WORKLOAD_URL -o /dev/null -w '%{http_code}\n' -s`
  expected_str="200"

  echo "Test2: Access Sample Workload GUI"
  if [[ "$rx_str" == "$expected_str" ]]
  then
    echo "Test2 Pass"
  else
    echo "Test2 Fail"
  fi

  #test-3: workload output
  rx_str=`curl -s $WORKLOAD_URL`
  expected_str="Greetings from Spring Boot + Tanzu!"

  echo "Test3: Verify Sample Workload Output"
  if [[ "$rx_str" == "$expected_str" ]]
  then
    echo "Test3 Pass"
  else
    echo "Test3 Fail"
  fi
}
