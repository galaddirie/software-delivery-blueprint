#!/bin/sh

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

github_org=${1}
application_name=${2}
github_user=${3}
github_email=${4}
namespace=${5}
ksa=${6}
env=${7}
index=${8}
region=${9}
monorepo_name=${10}
app_runtime=${11}

repo=${application_name}
#The following code is to avoid race condition to the commits done to acm repo in different folders by this script
sleep_time=20
sleep_index=$((${index}+1))
sleep_total=$((${sleep_time}*${sleep_index}))
sleep $sleep_total

# Clone the newly created app repo
git clone https://github.com/${github_org}/${repo} ${repo}

# Clone the monorepo to get the template
git clone -b dev https://github.com/${github_org}/${monorepo_name} monorepo-temp

for branch in "main"
do
  (
    cd ${repo}
    git checkout -b ${branch} 2>/dev/null || git checkout ${branch}

    # Copy files from monorepo template directory
    cp -r ../monorepo-temp/templates/app-templates/${app_runtime}/* .

    find . -type f -name "*.yaml" -exec  sed -i "s/YOUR_APPLICATION/${application_name}/g" {} +
    find ./k8s/${env} -type f -name "*.yaml" -exec  sed -i "s/NAMESPACE/${namespace}/g" {} +
    find ./k8s/${env} -type f -name "*.yaml" -exec  sed -i "s/SERVICEACCOUNT/${ksa}/g" {} +
    find . -type f -name "cloudbuild.yaml" -exec  sed -i "s/YOUR_REGION/${region}/g" {} +
    git add .
    git config --global user.name ${github_user}
    git config --global user.email ${github_email}
    git commit -m "IGNORE running the trigger.Setting up app code repo for the first time."
    git push origin ${branch}
  )
done
