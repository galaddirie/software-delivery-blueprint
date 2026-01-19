#!/usr/bin/env bash
shopt -s expand_aliases

# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Verify that the scripts are being run from Linux and not Mac
if [[ $OSTYPE != "linux-gnu" ]]; then
    echo "ERROR: This script and consecutive set up scripts have only been tested on Linux. Currently, only Linux (debian) is supported. Please run in Cloud Shell or in a VM running Linux".
    exit;
fi

export SCRIPT_DIR=$(dirname $(readlink -f $0 2>/dev/null) 2>/dev/null || echo "${PWD}/$(dirname $0)")
START_DIR=${PWD}
BASE_DIR="${SCRIPT_DIR}/../"
LOG_DIR="${SCRIPT_DIR}/../../logs/infra"
mkdir -p ${LOG_DIR}
TEMP_DIR="${BASE_DIR}/../temp"
mkdir -p ${TEMP_DIR}

if [ ! -f ${LOG_DIR}/vars.sh ]; then
    cp ${SCRIPT_DIR}/vars.sh ${LOG_DIR}/vars.sh
    source ${LOG_DIR}/vars.sh
else
    source ${LOG_DIR}/vars.sh
fi

export LOG_FILE=${LOG_DIR}/platform-bootstrap-$(date +%s).log
touch ${LOG_FILE}
exec 2>&1
exec &> >(tee -i ${LOG_FILE})

#functions.sh helps make the script interactive
source ${SCRIPT_DIR}/functions.sh

# Ensure monorepo name is defined
while [ -z ${MONOREPO_NAME} ]
    do
    read -p "$(echo -e "Please provide the name for the dev-platform monorepo: ")" MONOREPO_NAME
    done

# Ensure github user is defined
while [ -z ${GITHUB_USER} ]
    do
    read -p "$(echo -e "Please provide your github user: ")" GITHUB_USER
    done

# Ensure github personal access token is defined
while [ -z ${TOKEN} ]
    do
    read -p "$(echo -e "Please provide your github personal access token: ")" TOKEN
    done

# Ensure github org is defined
while [ -z ${GITHUB_ORG} ]
    do
    read -p "$(echo -e "Please provide your github org: ")" GITHUB_ORG
    done

# Ensure REGION is defined
while [ -z ${REGION} ]
    do
    read -p "$(echo -e "Please provide the region where resources will be created: ")" REGION
    done

while [ -z ${SEC_REGION} ]
    do
    read -p "$(echo -e "Please provide the secondary region for GKE multi cluster in prod: ")" SEC_REGION
    done

# Let the user chose the kind of trigger they want to create in Application factory
while [ -z ${TRIGGER_TYPE} ]
    do
    read -p "$(echo -e "Enter \"webhook\" for creating webhook triggers or \"github\" for github trigger: ")" TRIGGER_TYPE
    done

export PROJECT_ID=$(gcloud config list --format 'value(core.project)')
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format 'value(projectNumber)')
export ORG_ID=$(gcloud organizations list --format 'value(ID)')
export BILLING_ACCOUNT_ID="dummyvalue"

TEMPLATE_INFRA_REPO="platform-template"
TEMPLATE_ACM_REPO="acm-template"
ACM_DIR="acm"
TF_MODULES_DIR="terraform-modules"
PLATFORM_DIR="platform"
APP_FACTORY_DIR="app-factory"
TEMPLATES_DIR="templates"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SA_FOR_API_KEY="api-key-sa-${TIMESTAMP}"
GITHUB_SECRET_NAME="github-token"
CLOUD_DEPLOY="cloud-deploy-sa"
CLOUD_DEPLOY_SA="${CLOUD_DEPLOY}@${PROJECT_ID}.iam.gserviceaccount.com"
TEMPLATE_APP_REPO="app-factory-template"
CUSTOM_SA="devops-sa-${PROJECT_ID}"
INFRA_TRIGGER_NAME="create-infra"
TEAM_TRIGGER_NAME="add-team-files"
APP_TRIGGER_NAME="create-app"
PLAN_TRIGGER_NAME="tf-plan"
APPLY_TRIGGER_NAME="tf-apply"
APP_TEMPLATES=$(ls ${BASE_DIR} | grep  -- "app-template-")
APP_INFRA_TEMPLATE="infra-template"
TIMESTAMP=$(date "+%Y%m%d%H%M%S")
SA_FOR_API_KEY="api-key-sa-${TIMESTAMP}"
APP_TF_MODULES="terraform-modules"

title_no_wait "#######################################################"
title_no_wait "             Bootstrapping platform                    "
title_no_wait "#######################################################"
#Storing variables in the state file so the script start from where it left off in even of a failure
grep -q "export MONOREPO_NAME=.*" ${LOG_DIR}/vars.sh || echo -e "export MONOREPO_NAME=${MONOREPO_NAME}" >> ${LOG_DIR}/vars.sh
grep -q "export GITHUB_USER=.*" ${LOG_DIR}/vars.sh || echo -e "export GITHUB_USER=${GITHUB_USER}" >> ${LOG_DIR}/vars.sh
grep -q "export TOKEN=.*" ${LOG_DIR}/vars.sh|| echo -e "export TOKEN=${TOKEN}" >> ${LOG_DIR}/vars.sh
grep -q "export GITHUB_ORG=.*" ${LOG_DIR}/vars.sh || echo -e "export GITHUB_ORG=${GITHUB_ORG}" >> ${LOG_DIR}/vars.sh
grep -q "export REGION=.*" ${LOG_DIR}/vars.sh || echo -e "export REGION=${REGION}" >> ${LOG_DIR}/vars.sh
grep -q "export SEC_REGION=.*" ${LOG_DIR}/vars.sh || echo -e "export SEC_REGION=${SEC_REGION}" >> ${LOG_DIR}/vars.sh
grep -q "export PROJECT_ID.*" ${LOG_DIR}/vars.sh || echo -e "export PROJECT_ID=${PROJECT_ID}" >> ${LOG_DIR}/app_vars.sh
grep -q "export PROJECT_NUMBER=.*" ${LOG_DIR}/vars.sh || echo -e "export PROJECT_NUMBER=${PROJECT_NUMBER}" >> ${LOG_DIR}/app_vars.sh

if [[ "${TRIGGER_TYPE,,}" == "webhook" ]] || [[ "${TRIGGER_TYPE,,}" == "github" ]]; then
    grep -q "export TRIGGER_TYPE=.*" ${LOG_DIR}/vars.sh || echo -e "export TRIGGER_TYPE=${TRIGGER_TYPE}" >> ${LOG_DIR}/vars.sh
else
   title_no_wait "The trigger type ${TRIGGER_TYPE} is invalid. Specify webhook or github"
   exit 1
fi


#FUNCTIONS DEFINITIONS BELOW
generate_api_key () {
    title_no_wait "Creating a Service Account for creating an API key ..."
    print_and_execute "gcloud iam service-accounts create ${SA_FOR_API_KEY}  --display-name \"API Key ${SA_FOR_API_KEY}\""

    title_no_wait "Granting access to cloudbuild SA for accessing the API key ..."
    print_and_execute "gcloud projects add-iam-policy-binding ${1} \
                       --member serviceAccount:${SA_FOR_API_KEY}@${1}.iam.gserviceaccount.com \
                       --role roles/serviceusage.apiKeysAdmin"

    title_no_wait "Creating credentials for the SA ..."
    print_and_execute "gcloud iam service-accounts keys create ~/credentials.json \
                       --iam-account ${SA_FOR_API_KEY}@${1}.iam.gserviceaccount.com"

    if [[ `which oauth2l | wc -l` -eq 0 ]]; then
        title_no_wait "oauth2l not installed"
        title_no_wait "Download and install oauth2l ..."
        print_and_execute "git clone  https://${GITHUB_USER}:${TOKEN}@github.com/google/oauth2l ${START_DIR}/oauth2l-${TIMESTAMP}"
        print_and_execute "cd ${START_DIR}/oauth2l-${TIMESTAMP}"
        print_and_execute "make dev"
        print_and_execute "oauth2l fetch --credentials ~/credentials.json --scope cloud-platform"
        print_and_execute "alias gcurl='curl -S -H \"$(oauth2l header --json ~/credentials.json cloud-platform userinfo.email)\" -H \"Content-Type: application/json\"'"

    else
        title_no_wait "oauth2l is already installed ..."
        print_and_execute "oauth2l fetch --credentials ~/credentials.json --scope cloud-platform"
        print_and_execute "alias gcurl='curl -S -H \"$(oauth2l header --json ~/credentials.json cloud-platform userinfo.email)\" -H \"Content-Type: application/json\"'"
    fi

    title_no_wait "checking if we are all set to create API key ..."
    print_and_execute "type gcurl"
    if [ $? -ne 0 ]; then
        title_no_wait "gcurl alias not set. Problem in using oauth2l. Exiting"
        exit 1
    fi

    title_no_wait "Creating a API key for webhook ..."
    print_and_execute "operation_id=$(gcurl https://apikeys.googleapis.com/v2/projects/${2}/locations/global/keys -X POST -d '{"displayName" : "webhook","restrictions": {"api_targets": [{"service": "cloudbuild.googleapis.com"}]}}' | jq .name)"
    title_no_wait "Polling for the operation to complete ..."
    status="false"
    while  [ ${status} != "true" ]
    do
        title_no_wait "Waiting for operation to create API to complete. Sleeping for 5"
        print_and_execute "echo ${operation_id}"
        print_and_execute "status=$(gcurl https://apikeys.googleapis.com/v2/${operation_id} | jq .done)"
        if [[ -z ${status} ]]; then
            title_no_wait "Unable to fetch the status of API key create operation. Possibly the command to create API key had issues. Aborting"
            exit
        fi
        sleep 5
    done
    print_and_execute "API_KEY=$(gcurl https://apikeys.googleapis.com/v2/${operation_id} | jq .response.keyString)"
}

create_webhook () {
    trigger=$1
    project_id=$2
    project_number=$3
    repo=$4
    echo "Trigger is $trigger"
    title_no_wait "Creating a secret for webhook ..."
    SECRET_NAME=webhook-secret-${trigger}
    SECRET_VALUE=$(sed "s/[^a-zA-Z0-9]//g" <<< $(openssl rand -base64 15))
    SECRET_PATH=projects/${project_number}/secrets/${SECRET_NAME}/versions/1
    print_and_execute "printf ${SECRET_VALUE} | gcloud secrets create ${SECRET_NAME} --data-file=-"
    title_no_wait "Providing read access to Cloudbuild service account on the secret ..."
    print_and_execute "gcloud secrets add-iam-policy-binding ${SECRET_NAME} \
         --member=serviceAccount:service-${project_number}@gcp-sa-cloudbuild.iam.gserviceaccount.com \
         --role='roles/secretmanager.secretAccessor'"

    title_no_wait "Creating a webhook trigger ..."
    if [ "${trigger}" = "${TEAM_TRIGGER_NAME}" ]; then
        print_and_execute "gcloud alpha builds triggers create webhook --name=\"${TEAM_TRIGGER_NAME}\"  --inline-config=\"${BASE_DIR}/${TEMPLATE_APP_REPO}/add-team-tf-files-webhook.yaml\" --secret=${SECRET_PATH} --substitutions='_REPO_NAME=${MONOREPO_NAME},_TEAM_NAME=\$(body.message.team),_GITHUB_ORG=${GITHUB_ORG},_GITHUB_USER=${GITHUB_USER},_APP_FACTORY_DIR=${APP_FACTORY_DIR}'"
    elif [ "${trigger}" = "${APP_TRIGGER_NAME}" ]; then
        print_and_execute "gcloud alpha builds triggers create webhook --name=\"${APP_TRIGGER_NAME}\"  --inline-config=\"${BASE_DIR}/${TEMPLATE_APP_REPO}/add-app-tf-files-webhook.yaml\" --secret=${SECRET_PATH} --substitutions='_REPO_NAME=${MONOREPO_NAME},_APP_NAME=\$(body.message.app),_APP_RUNTIME=\$(body.message.runtime),_GITHUB_ORG=${GITHUB_ORG},_GITHUB_USER=${GITHUB_USER},_REGION=${REGION},_TRIGGER_TYPE=\$(body.message.trigger_type),_GITHUB_TEAM=\$(body.message.github_team),_APP_FACTORY_DIR=${APP_FACTORY_DIR}'"
    elif [ "${trigger}" = "${PLAN_TRIGGER_NAME}" ]; then
        print_and_execute "gcloud alpha builds triggers create webhook --name=\"${PLAN_TRIGGER_NAME}\"  --inline-config=\"${BASE_DIR}/${TEMPLATE_APP_REPO}/tf-plan-webhook.yaml\" --secret=${SECRET_PATH} --substitutions='_GITHUB_USER=${GITHUB_USER},_REPO_NAME=${MONOREPO_NAME},_GITHUB_ORG=${GITHUB_ORG},_APP_FACTORY_DIR=${APP_FACTORY_DIR}'"
    elif [ "${trigger}" = "${APPLY_TRIGGER_NAME}" ]; then
        print_and_execute "gcloud alpha builds triggers create webhook --name=\"${APPLY_TRIGGER_NAME}\"  --inline-config=\"${BASE_DIR}/${TEMPLATE_APP_REPO}/tf-apply-webhook.yaml\" --secret=${SECRET_PATH} --substitutions='_GITHUB_USER=${GITHUB_USER},_REPO_NAME=${MONOREPO_NAME},_GITHUB_ORG=${GITHUB_ORG},_APP_FACTORY_DIR=${APP_FACTORY_DIR}'"
    elif [ "${trigger}" = "${INFRA_TRIGGER_NAME}" ]; then
        print_and_execute "gcloud alpha builds triggers create webhook --name=\"${INFRA_TRIGGER_NAME}\"  --inline-config=\"${BASE_DIR}/${TEMPLATE_INFRA_REPO}/cloudbuild-webhook.yaml\" --secret=${SECRET_PATH} --substitutions='_REF=\$(body.ref),_REPO=\$(body.repository.full_name),_COMMIT_MSG=\$(body.head_commit.message),_PLATFORM_DIR=${PLATFORM_DIR}'  --subscription-filter='(!_COMMIT_MSG.matches(\"IGNORE\"))'"
    else
        title_no_wait "Invalid trigger name passed"
        print_and_execute "exit 1"
    fi
    ## Retrieve the URL
    if [ "${trigger}" = "${INFRA_TRIGGER_NAME}" ]; then
        WEBHOOK_URL="https://cloudbuild.googleapis.com/v1/projects/${project_id}/triggers/${trigger}:webhook?key=${API_KEY}&secret=${SECRET_VALUE}"

        title_no_wait "Creating a github trigger ..."

        print_and_execute "curl -H \"Authorization: token ${TOKEN}\" \
         -d '{\"config\": {\"url\": \"${WEBHOOK_URL}\", \"content_type\": \"json\"},\"active\": true,\"events\": [\"push\"]}' \
         -X POST https://api.github.com/repos/$GITHUB_ORG/${repo}/hooks"
    fi

}

title_no_wait "STARTING"
title_no_wait "Adding git configs"
print_and_execute "git config --global user.email ${GITHUB_USER}@github.com"
print_and_execute "git config --global user.name ${GITHUB_USER}"


# Creating monorepo in your org and committing all templates to it
title_no_wait "Checking if ${MONOREPO_NAME} already exists..."
repo_id_exists=$(curl -s -H "Authorization: token ${TOKEN}" -H "Accept: application/json" "https://api.github.com/repos/${GITHUB_ORG}/${MONOREPO_NAME}" | jq '.id')
if [ ${repo_id_exists} = "null" ]; then
    title_no_wait "${MONOREPO_NAME} does not exist. Creating it..."
    print_and_execute "repo_id=$(curl -s -H "Authorization: token ${TOKEN}" -H "Accept: application/json" \
        -d "{ \
            \"name\": \"${MONOREPO_NAME}\", \
            \"private\": true \
        }" \
    -X POST https://api.github.com/orgs/${GITHUB_ORG}/repos | jq '.id')"

    sleep 5
    if [ ${repo_id} = "null" ]; then
        echo "Unable to create git repo.Exiting"
        exit 1
    else
        grep -q "export MONOREPO_NAME=.*" ${LOG_DIR}/vars.sh || echo -e "export MONOREPO_NAME=${MONOREPO_NAME}" >> ${LOG_DIR}/vars.sh
    fi
else
    echo "The repo ${MONOREPO_NAME} already exists, not creating it"
fi

title_no_wait "Cloning recently created monorepo..."
print_and_execute "rm -rf ${TEMP_DIR}/${MONOREPO_NAME} && git clone  https://${GITHUB_USER}:${TOKEN}@github.com/${GITHUB_ORG}/${MONOREPO_NAME} ${TEMP_DIR}/${MONOREPO_NAME}"
cd ${TEMP_DIR}/${MONOREPO_NAME}
print_and_execute "git checkout dev 2>/dev/null || git checkout -b dev"

title_no_wait "Organizing monorepo structure..."
mkdir -p ${TF_MODULES_DIR} ${ACM_DIR} ${PLATFORM_DIR} ${APP_FACTORY_DIR} ${TEMPLATES_DIR}/app-templates ${TEMPLATES_DIR}/${APP_INFRA_TEMPLATE}

title_no_wait "Copying terraform modules..."
cp -r ${BASE_DIR}/${TF_MODULES_DIR}/* ${TF_MODULES_DIR}/

title_no_wait "Copying acm-template..."
cp -r ${BASE_DIR}/${TEMPLATE_ACM_REPO}/* ${ACM_DIR}/

title_no_wait "Copying platform-template..."
cp -r ${BASE_DIR}/${TEMPLATE_INFRA_REPO}/* ${PLATFORM_DIR}/

title_no_wait "Copying app-factory-template..."
cp -r ${BASE_DIR}/${TEMPLATE_APP_REPO}/* ${APP_FACTORY_DIR}/

title_no_wait "Copying app templates..."
for REPO in ${APP_TEMPLATES}
do
    APP_TYPE=$(echo ${REPO} | sed 's/app-template-//')
    mkdir -p ${TEMPLATES_DIR}/app-templates/${APP_TYPE}
    cp -r ${BASE_DIR}/${REPO}/* ${TEMPLATES_DIR}/app-templates/${APP_TYPE}/
done

title_no_wait "Copying infra template..."
cp -r ${BASE_DIR}/${APP_INFRA_TEMPLATE}/* ${TEMPLATES_DIR}/${APP_INFRA_TEMPLATE}/

title_no_wait "Committing and pushing all templates to monorepo dev branch..."
print_and_execute "git add . && git commit -m \"Initial monorepo setup\""
print_and_execute "git push -u origin dev"

title_no_wait "Pushing staging branch to monorepo..."
print_and_execute "git checkout staging 2>/dev/null || git checkout -b staging"
print_and_execute "git push -u origin staging"

title_no_wait "Pushing prod branch to monorepo..."
print_and_execute "git checkout prod 2>/dev/null || git checkout -b prod"
print_and_execute "git push -u origin prod"

title_no_wait "Switching back to dev branch..."
print_and_execute "git checkout dev"

#Secure staging and prod branch but disallowing direct push to them
title_no_wait "Applying branch protection to staging..."
print_and_execute "curl -s -X PUT -u $GITHUB_USER:$TOKEN -H \"Accept: application/vnd.github.v3+json\" \
https://api.github.com/repos/$GITHUB_ORG/$MONOREPO_NAME/branches/staging/protection \
 -d \"{ \
      \\\"restrictions\\\": null,\\\"required_status_checks\\\": null, \
      \\\"required_pull_request_reviews\\\" : {\\\"dismissal_restrictions\\\": {}, \
      \\\"dismiss_stale_reviews\\\": false,\\\"require_code_owner_reviews\\\": true,\
      \\\"required_approving_review_count\\\": 1,\\\"bypass_pull_request_allowances\\\": {}}, \
      \\\"enforce_admins\\\": null
      }\" \
      "

title_no_wait "Applying branch protection to prod..."
print_and_execute "curl -s -X PUT -u $GITHUB_USER:$TOKEN -H \"Accept: application/vnd.github.v3+json\" \
https://api.github.com/repos/$GITHUB_ORG/$MONOREPO_NAME/branches/prod/protection \
 -d \"{ \
      \\\"restrictions\\\": null,\\\"required_status_checks\\\": null, \
      \\\"required_pull_request_reviews\\\" : {\\\"dismissal_restrictions\\\": {}, \
      \\\"dismiss_stale_reviews\\\": false,\\\"require_code_owner_reviews\\\": true,\
      \\\"required_approving_review_count\\\": 1,\\\"bypass_pull_request_allowances\\\": {}}, \
      \\\"enforce_admins\\\": null
      }\" \
      "
#Setting up the infrastructure setup project
title_no_wait "Setting project..."
print_and_execute "gcloud config set project ${PROJECT_ID}"

title_no_wait "Enabling APIs..."
print_and_execute "gcloud services enable cloudresourcemanager.googleapis.com \
cloudbilling.googleapis.com \
cloudbuild.googleapis.com \
iam.googleapis.com \
secretmanager.googleapis.com \
container.googleapis.com \
apikeys.googleapis.com \
cloudidentity.googleapis.com \
gkehub.googleapis.com \
anthosconfigmanagement.googleapis.com \
clouddeploy.googleapis.com \
multiclusteringress.googleapis.com \
multiclusterservicediscovery.googleapis.com \
artifactregistry.googleapis.com \
serviceusage.googleapis.com"

print_and_execute "sleep 10"

#title_no_wait "Add Cloud build service account as billing account user on the org"
#print_and_execute "gcloud organizations add-iam-policy-binding ${ORG_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/billing.user --condition=None"

#title_no_wait "Give cloudbuild service account projectCreator role at Org level..."
#print_and_execute "gcloud organizations add-iam-policy-binding ${ORG_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/resourcemanager.projectCreator --condition=None"

title_no_wait "Give cloudbuild service account secretmanager admin role on project ${PROJECT_ID} ..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/secretmanager.admin"

title_no_wait "Give cloudbuild service account security admin role to be able to set policy..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/iam.securityAdmin"

title_no_wait "Give cloudbuild service account role to be able to create VPC..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/servicenetworking.serviceAgent"
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/compute.networkAdmin"

title_no_wait "Give cloudbuild service account role to create new service accounts..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/iam.serviceAccountAdmin"

title_no_wait "Give cloudbuild service account role to create GKE cluster..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/container.clusterAdmin"

title_no_wait "Give cloudbuild service account role to associate SA with GKE nodes..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/iam.serviceAccountUser"

title_no_wait "Give cloudbuild service account role to create hub membership..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/gkehub.editor"

title_no_wait "Give cloudbuild service account role to create Cloud Deploy targets..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/clouddeploy.operator"

title_no_wait "Give cloudbuild service account role to create and destroy GCS bucket..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/storage.admin"

title_no_wait "Give cloudbuild service account role to create APIkeys..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com --role=roles/serviceusage.apiKeysAdmin"
title_no_wait "Creating a service account for Cloud Deploy"
print_and_execute "gcloud iam service-accounts create \"${CLOUD_DEPLOY}\"  --display-name \"Service Account for CloudDeploy\""

title_no_wait "Adding clouddeploy SA to secretmanager..."
print_and_execute "printf \"projects/${PROJECT_ID}/serviceAccounts/${CLOUD_DEPLOY_SA}\" | gcloud secrets create clouddeploy-sa-id --data-file=-"
print_and_execute "printf \"${CLOUD_DEPLOY_SA}\" | gcloud secrets create clouddeploy-sa --data-file=-"

title_no_wait "Give clouddeploy service account required roles for performing the deployment..."
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${CLOUD_DEPLOY_SA} --role=roles/logging.logWriter"
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${CLOUD_DEPLOY_SA} --role=roles/clouddeploy.jobRunner"
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${CLOUD_DEPLOY_SA} --role=roles/storage.objectViewer"
print_and_execute "gcloud projects add-iam-policy-binding ${PROJECT_ID}  --member=serviceAccount:${CLOUD_DEPLOY_SA} --role=roles/container.developer"


title_no_wait "Adding secrets to the secretsmanager..."
print_and_execute "printf ${TOKEN} | gcloud secrets create github-token --data-file=-"
print_and_execute "printf ${GITHUB_USER} | gcloud secrets create github-user --data-file=-"
print_and_execute "printf ${GITHUB_USER}@github.com | gcloud secrets create github-email --data-file=-"
print_and_execute "printf ${GITHUB_ORG} | gcloud secrets create github-org --data-file=-"
print_and_execute "printf ${MONOREPO_NAME} | gcloud secrets create acm-repo --data-file=-"

INFRA_TF_BUCKET="${PROJECT_ID}-multi-tenant-platform-tf-state"

title_no_wait "Creating GCS bucket for holding terraform state files..."
print_and_execute "gsutil mb -p ${PROJECT_ID} -l ${REGION}  gs://${INFRA_TF_BUCKET}"

#Perform sed operation to replace templated variables with real values in the monorepo
cd ${TEMP_DIR}/${MONOREPO_NAME}
title_no_wait "Checkout dev branch for platform configuration..."
print_and_execute "git checkout dev"

title_no_wait "Replacing variables in variables.tf under dev, staging and prod folder in platform directory..."
#print_and_execute "sed -i \"s/YOUR_IAM_GROUP/${IAM_GROUP}@${ORG_NAME}/\"  ${PLATFORM_DIR}/env/*/variables.tf"
#print_and_execute "sed -i \"s/YOUR_BILLING_ACCOUNT/${BILLING_ACCOUNT_ID}/\"  ${PLATFORM_DIR}/env/*/variables.tf"
#print_and_execute "sed -i \"s/YOUR_ORG_ID/${ORG_ID}/\"  ${PLATFORM_DIR}/env/*/variables.tf"
print_and_execute "sed -i \"s/YOUR_ACM_REPO/${MONOREPO_NAME}/\" ${PLATFORM_DIR}/env/*/variables.tf"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/YOUR_GITHUB_ORG/${GITHUB_ORG}/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/terraform-modules.git/${MONOREPO_NAME}.git/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/terraform-modules/${MONOREPO_NAME}/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/landing-zone\/render/\/\/terraform-modules\/landing-zone\/render?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/artifact-registry\/render/\/\/terraform-modules\/artifact-registry\/render?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/cloud-deploy-targets/\/\/terraform-modules\/cloud-deploy-targets?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/gke\//\/\/terraform-modules\/gke?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/vpc\//\/\/terraform-modules\/vpc?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/project\//\/\/terraform-modules\/project?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/mci\//\/\/terraform-modules\/mci?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/\/\/acm\//\/\/terraform-modules\/acm?ref=dev/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/YOUR_REGION/${REGION}/g\" {} +"
print_and_execute "find ${PLATFORM_DIR} -type f -exec  sed -i \"s/YOUR_SECONDARY_REGION/${SEC_REGION}/g\" {} +"

title_no_wait "Replacing tf bucket in backend.tf in platform directory..."
INFRA_TF_BUCKET="${PROJECT_ID}-multi-tenant-platform-tf-state"
print_and_execute "gsutil mb -p ${PROJECT_ID} -l ${REGION} gs://${INFRA_TF_BUCKET}"
sed -i "s/YOUR_PLATFORM_INFRA_TERRAFORM_STATE_BUCKET/${INFRA_TF_BUCKET}/" ${PLATFORM_DIR}/env/*/backend.tf

title_no_wait "Replacing variables in app-factory directory..."
print_and_execute "find ${APP_FACTORY_DIR} -type f -exec  sed -i \"s/YOUR_PROJECT_ID/${PROJECT_ID}/g\" {} +"
print_and_execute "find ${APP_FACTORY_DIR} -type f -exec  sed -i \"s/YOUR_MONOREPO_NAME/${MONOREPO_NAME}/g\" {} +"
print_and_execute "sed -i \"s/YOUR_GITHUB_ORG/${GITHUB_ORG}/\" ${APP_FACTORY_DIR}/github.tf"

APP_TF_BUCKET="${PROJECT_ID}-app-factory-tf"
title_no_wait "Creating GCS bucket for holding app factory terraform state files..."
print_and_execute "gsutil mb -p ${PROJECT_ID} -l ${REGION} gs://${APP_TF_BUCKET}"
sed -i "s/YOUR_APP_INFRA_TERRAFORM_STATE_BUCKET/${APP_TF_BUCKET}/" ${APP_FACTORY_DIR}/backend.tf

title_no_wait "Replacing variables in app templates..."
print_and_execute "find ${TEMPLATES_DIR} -type f -exec  sed -i \"s/YOUR_GITHUB_ORG/${GITHUB_ORG}/g\" {} +"
print_and_execute "find ${TEMPLATES_DIR} -type f -exec  sed -i \"s/terraform-modules.git/${MONOREPO_NAME}.git/g\" {} +"
print_and_execute "find ${TEMPLATES_DIR} -type f -exec  sed -i \"s/terraform-modules/${MONOREPO_NAME}/g\" {} +"
print_and_execute "find ${TEMPLATES_DIR} -type f -exec  sed -i \"s/\/\/gcs/\/\/terraform-modules\/gcs?ref=dev/g\" {} +"

title_no_wait "Committing and pushing initial configurations to monorepo dev branch..."
git add .
git config --global user.name ${GITHUB_USER}
git config --global user.email "${GITHUB_USER}@github.com"
git commit -m "Initial monorepo configuration"
git push origin dev

if [[ "${TRIGGER_TYPE,,}" == "webhook" ]]; then
    generate_api_key ${PROJECT_ID} ${PROJECT_NUMBER}
    create_webhook ${INFRA_TRIGGER_NAME} ${PROJECT_ID} ${PROJECT_NUMBER} ${MONOREPO_NAME}
    create_webhook ${TEAM_TRIGGER_NAME} ${PROJECT_ID} ${PROJECT_NUMBER} ${MONOREPO_NAME}
    create_webhook ${APP_TRIGGER_NAME} ${PROJECT_ID} ${PROJECT_NUMBER} ${MONOREPO_NAME}
    create_webhook ${PLAN_TRIGGER_NAME} ${PROJECT_ID} ${PROJECT_NUMBER} ${MONOREPO_NAME}
    create_webhook ${APPLY_TRIGGER_NAME} ${PROJECT_ID} ${PROJECT_NUMBER} ${MONOREPO_NAME}
elif [[ "${TRIGGER_TYPE,,}" == "github" ]]; then
    title_and_wait "ATTENTION : We need to connect Cloud Build in ${PROJECT_ID} with your monorepo. As of now, there is no way of doing it automatically, press ENTER for instructions for doing it manually."
    title_and_wait_step "Go to https://console.cloud.google.com/cloud-build/triggers/connect?project=${PROJECT_NUMBER} \
    Select \"Source\" as github and press continue. \
    If it asks for authentication, enter your github credentials. \
    Under \"Select Repository\" , on \"github account\" drop down click on \"+Add\" and choose ${GITHUB_ORG}. \
    Click on \"repository\" drop down and select ${MONOREPO_NAME}. \
    Click the checkbox to agree to the terms and conditions and click connect. \
    Click Done. \
    "
    title_no_wait "Creating Cloud Build trigger for platform..."
    print_and_execute "gcloud beta builds triggers create github --name=\"${INFRA_TRIGGER_NAME}\" --repo-owner=\"${GITHUB_ORG}\" --repo-name=\"${MONOREPO_NAME}\" --branch-pattern=\".*\" --build-config=\"${PLATFORM_DIR}/cloudbuild-github.yaml\" --included-files=\"${PLATFORM_DIR}/**\" --substitutions=\"_PLATFORM_DIR=${PLATFORM_DIR}\""

    title_no_wait "Creating Cloud Build triggers for App Factory..."
    print_and_execute "gcloud alpha builds triggers create manual --name=\"${TEAM_TRIGGER_NAME}\" --repo=\"https://github.com/${GITHUB_ORG}/${MONOREPO_NAME}\" --build-config=\"${APP_FACTORY_DIR}/add-team-tf-files-github-trigger.yaml\" --branch=\"dev\" \
    --repo-type=\"GITHUB\" --substitutions \"_GITHUB_ORG\"=\"${GITHUB_ORG}\",\"_GITHUB_USER\"=\"${GITHUB_USER}\",\"_TEAM_NAME\"=\"\",\"_APP_FACTORY_DIR\"=\"${APP_FACTORY_DIR}\" "

    print_and_execute "gcloud alpha builds triggers create manual --name=\"${APP_TRIGGER_NAME}\" --repo=\"https://github.com/${GITHUB_ORG}/${MONOREPO_NAME}\" --build-config=\"${APP_FACTORY_DIR}/add-app-tf-files-github-trigger.yaml\" --branch=\"dev\" \
    --repo-type=\"GITHUB\" --substitutions \"_APP_NAME\"=\"\",\"_APP_RUNTIME\"=\"\",\"_GITHUB_ORG\"=\"${GITHUB_ORG}\",\"_GITHUB_USER\"=\"${GITHUB_USER}\",\"_INFRA_PROJECT_ID\"=\"${PROJECT_ID}\",\"_REGION\"=\"${REGION}\",\"_TRIGGER_TYPE\"=\"webhook\",\"_GITHUB_TEAM\"=\"\",\"_APP_FACTORY_DIR\"=\"${APP_FACTORY_DIR}\" "

    print_and_execute "gcloud alpha builds triggers create manual --name=\"${PLAN_TRIGGER_NAME}\" --repo=\"https://github.com/${GITHUB_ORG}/${MONOREPO_NAME}\" --branch=\"dev\" --build-config=\"${APP_FACTORY_DIR}/tf-plan-github-trigger.yaml\" \
    --repo-type=\"GITHUB\" --substitutions \"_GITHUB_USER\"=\"${GITHUB_USER}\",\"_APP_FACTORY_DIR\"=\"${APP_FACTORY_DIR}\" "

    print_and_execute "gcloud alpha builds triggers create manual --name=\"${APPLY_TRIGGER_NAME}\" --repo=\"https://github.com/${GITHUB_ORG}/${MONOREPO_NAME}\" --branch=\"dev\" --build-config=\"${APP_FACTORY_DIR}/tf-apply-github-trigger.yaml\" \
    --repo-type=\"GITHUB\" --substitutions \"_GITHUB_USER\"=\"${GITHUB_USER}\",\"_APP_FACTORY_DIR\"=\"${APP_FACTORY_DIR}\" "
fi

title_no_wait "Removing temp directory"
print_and_execute "rm -rf ${TEMP_DIR}"
title_no_wait "#######################################################"
title_no_wait "      Finished Bootstrapping Monorepo                  "
title_no_wait "#######################################################"
