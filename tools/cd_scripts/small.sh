#! /bin/bash
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Print commands and their arguments as they are executed.
set -x
# Exit immediately if a command exits with a non-zero status.
set -e

# Extract the metadata parameters passed
# First , we need to extract the GCE VM Zone.
ZONE=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
ZONE_NAME=$(basename $ZONE)
RUN_E2E_TESTS_FOR_ZB_ONLY=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.run-on-zb-only)')
echo "Running tests for zonal buckets only? : $RUN_E2E_TESTS_FOR_ZB_ONLY"

if [[ "$RUN_E2E_TESTS_FOR_ZB_ONLY" == "true" ]]; then
  echo "Running integration tests for Zonal bucket only..."
else
  echo "Running integration tests for other buckets..."
fi

#details.txt file contains the release version and commit hash of the current release.
gsutil cp  gs://gcsfuse-release-packages/version-detail/details.txt .
# Writing VM instance name to details.txt (Format: release-test-<os-name>)
curl http://metadata.google.internal/computeMetadata/v1/instance/name -H "Metadata-Flavor: Google" >> details.txt

# Based on the os type(from vm instance name) in detail.txt, run the following commands to add starterscriptuser
if grep -q ubuntu details.txt || grep -q debian details.txt;
then
#  For ubuntu and debian os
    sudo adduser --ingroup google-sudoers --disabled-password --home=/home/starterscriptuser --gecos "" starterscriptuser
else
#  For rhel and centos
    sudo adduser -g google-sudoers --home-dir=/home/starterscriptuser starterscriptuser
fi

# Run the following as starterscriptuser
sudo -u starterscriptuser bash -c '
RUN_E2E_TESTS_FOR_ZB_ONLY='$1'
# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# Based on the os type in detail.txt, run the following commands for setup

if [[ "$RUN_E2E_TESTS_FOR_ZB_ONLY" == "true" ]]; then
  echo "THis is okay"
else
  echo "This is not okay"
fi
  
' "$RUN_E2E_TESTS_FOR_ZB_ONLY"
