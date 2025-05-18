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

# Extract the metadata parameters passed, for which we need the zone of the GCE VM
# on which the tests are supposed to run.
ZONE=$(curl -H "Metadata-Flavor: Google" http://metadata.google.internal/computeMetadata/v1/instance/zone)
echo "Got ZONE=\"${ZONE}\" from metadata server."
# The format for the above extracted zone is projects/{project-id}/zones/{zone}, thus, from this
# need extracted zone name.
ZONE_NAME=$(basename "$ZONE")
# This parameter is passed as the GCE VM metadata at the time of creation.(Logic is handled in louhi stage script)
RUN_ON_ZB_ONLY=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.run-on-zb-only)')
RUN_READ_CACHE_TESTS_ONLY=$(gcloud compute instances describe "$HOSTNAME" --zone="$ZONE_NAME" --format='get(metadata.run-read-cache-only)')
echo "RUN_ON_ZB_ONLY flag set to : \"${RUN_ON_ZB_ONLY}\""
echo "RUN_READ_CACHE_TESTS_ONLY flag set to : \"${RUN_READ_CACHE_TESTS_ONLY}\""


# Based on the os type(from vm instance name) in detail.txt, run the following commands to add su5
sudo adduser --ingroup google-sudoers --disabled-password --home=/home/su5 --gecos "" su5

# Run the following as su5
sudo -u su5 bash -c '
# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# Export the RUN_ON_ZB_ONLY variable so that it is available in the environment of the 'su5' user.
# Since we are running the subsequent script as 'su5' using sudo, the environment of 'su5' 
# would not automatically have access to the environment variables set by the original user (i.e. $RUN_ON_ZB_ONLY).
# By exporting this variable, we ensure that the value of RUN_ON_ZB_ONLY is passed into the 'su5' script 
# and can be used for conditional logic or decisions within that script.
export RUN_ON_ZB_ONLY='$RUN_ON_ZB_ONLY'
export RUN_READ_CACHE_TESTS_ONLY='$RUN_READ_CACHE_TESTS_ONLY'

RELEASEVERSION=500.0.0
COMMITHASH=25bce721fa383479979f4a33e6693a5d07c3034c

#Copy details.txt to su5 home directory and create logs.txt
cd ~/
touch logs.txt
touch logs-hns.txt
touch logs-zonal.txt
LOG_FILE='~/logs.txt'

if [[ "$RUN_ON_ZB_ONLY" == "true" ]]; then
  LOG_FILE='~/logs-zonal.txt'
fi
  
echo "User: $USER" &>> ${LOG_FILE}
echo "Current Working Directory: $(pwd)"  &>> ${LOG_FILE}


# Based on the os type in detail.txt, run the following commands for setup


#  For Debian and Ubuntu os
# architecture can be amd64 or arm64
architecture=$(dpkg --print-architecture)

sudo apt update

#Install fuse
sudo apt install -y fuse

# download and install gcsfuse deb package
gcloud storage cp gs://gcsfuse-release-packages/v${RELEASEVERSION}/gcsfuse_${RELEASEVERSION}_${architecture}.deb .
sudo dpkg -i gcsfuse_${RELEASEVERSION}_${architecture}.deb |& tee -a ${LOG_FILE}

# install wget
sudo apt install -y wget

#install git
sudo apt install -y git

# install python3-setuptools tools.
sudo apt-get install -y gcc python3-dev python3-setuptools
# Downloading composite object requires integrity checking with CRC32c in gsutil.
# it requires to install crcmod.
sudo apt install -y python3-crcmod

#install build-essentials
sudo apt install -y build-essential


# install go
wget -O go_tar.tar.gz https://go.dev/dl/go1.24.0.linux-${architecture}.tar.gz
sudo tar -C /usr/local -xzf go_tar.tar.gz
export PATH=${PATH}:/usr/local/go/bin
#Write gcsfuse and go version to log file
gcsfuse --version |& tee -a ${LOG_FILE}
go version |& tee -a ${LOG_FILE}

# Clone and checkout gcsfuse repo
export PATH=${PATH}:/usr/local/go/bin
git clone https://github.com/anushka567/gcsfuse.git |& tee -a ${LOG_FILE}
cd gcsfuse


git checkout ${COMMITHASH} |& tee -a ${LOG_FILE}

TEST_DIR_PARALLEL=(
  "monitoring"
  "local_file"
  "log_rotation"
  "mounting"
  "gzip"
  "write_large_files"
  "rename_dir_limit"
  "read_large_files"
  "explicit_dir"
  "implicit_dir"
  "interrupt"
  "operations"
  "kernel_list_cache"
  "concurrent_operations"
  "mount_timeout"
  "stale_handle"
  "stale_handle_streaming_writes"
  "negative_stat_cache"
  "streaming_writes"
)
# These tests never become parallel as they are changing bucket permissions.
TEST_DIR_NON_PARALLEL=(
  "readonly"
  "managed_folders"
  "readonly_creds"
  "list_large_dir"
)

# Create a temporary file to store the log file name.
TEST_LOGS_FILE=$(mktemp)

INTEGRATION_TEST_TIMEOUT=240m

function run_non_parallel_tests() {
  local exit_code=0 # Initialize to 0 for success
  local BUCKET_NAME=$1
  local zonal=$2

  if [[ -z $3 ]]; then
    return 0
  fi
  declare -n test_array=$3 # nameref to the array

  for test_dir_np in "${test_array[@]}"
  do
    test_path_non_parallel="./tools/integration_tests/$test_dir_np"
    local log_file="/tmp/${test_dir_np}_${BUCKET_NAME}.log"
    echo "$log_file" >> "$TEST_LOGS_FILE" # Use double quotes for log_file
    GODEBUG=asyncpreemptoff=1 go test "$test_path_non_parallel" -p 1 --zonal="${zonal}" --integrationTest -v --testbucket="$BUCKET_NAME" --testInstalledPackage=true -timeout "$INTEGRATION_TEST_TIMEOUT" > "$log_file" 2>&1
    exit_code_non_parallel=$?
    if [ $exit_code_non_parallel -ne 0 ]; then
      exit_code=$exit_code_non_parallel
    fi
  done
  return $exit_code
}

function run_parallel_tests() {
  local exit_code=0
  local BUCKET_NAME=$1
  local zonal=$2
  local array_name=$3 # This is the name of the array
  if [[ -z $array_name ]]; then
    return 0
  fi
  declare -n test_array=$array_name # nameref to the array
  local pids=()

  for test_dir_p in "${test_array[@]}"
  do
    test_path_parallel="./tools/integration_tests/$test_dir_p"
    local log_file="/tmp/${test_dir_p}_${BUCKET_NAME}.log"
    echo "$log_file" >> "$TEST_LOGS_FILE"
    GODEBUG=asyncpreemptoff=1 go test "$test_path_parallel" -p 1 --zonal="${zonal}" --integrationTest -v --testbucket="$BUCKET_NAME" --testInstalledPackage=true -timeout "$INTEGRATION_TEST_TIMEOUT" > "$log_file" 2>&1 &
    pid=$!
    pids+=("$pid")
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
    exit_code_parallel=$?
    if [ $exit_code_parallel -ne 0 ]; then
      exit_code=$exit_code_parallel
    fi
  done
  return $exit_code
}

function run_e2e_tests() {
  local testcase=$1
  declare -n test_dir_parallel=$2
  declare -n test_dir_non_parallel=$3
  local is_zonal=$4
  local overall_exit_code=0

  local bkt_non_parallel="read-cache-only-$testcase"
  echo "Bucket name to run non-parallel tests sequentially: $bkt_non_parallel"

  local bkt_parallel="read-cache-only-$testcase-parallel"
  echo "Bucket name to run parallel tests: $bkt_parallel"

  echo "Running parallel tests..."
  run_parallel_tests  "$bkt_parallel" "$is_zonal" "$2" & # Pass the name of the array
  parallel_tests_pid=$!

  echo "Running non parallel tests ..."
  run_non_parallel_tests  "$bkt_non_parallel" "$is_zonal" "$3" & # Pass the name of the array
  non_parallel_tests_pid=$!

  wait "$parallel_tests_pid"
  local parallel_tests_exit_code=$?
  wait "$non_parallel_tests_pid"
  local non_parallel_tests_exit_code=$?

  if [ "$non_parallel_tests_exit_code" -ne 0 ]; then
    overall_exit_code=$non_parallel_tests_exit_code
  fi

  if [ "$parallel_tests_exit_code" -ne 0 ]; then
    overall_exit_code=$parallel_tests_exit_code
  fi
  return $overall_exit_code
}

function gather_test_logs() {
  readarray -t test_logs_array < "$TEST_LOGS_FILE"
  rm "$TEST_LOGS_FILE"
  for test_log_file in "${test_logs_array[@]}"
  do
    log_file=${test_log_file}
    if [ -f "$log_file" ]; then
      if [[ "$test_log_file" == *"hns"* ]]; then
        output_file="$HOME/logs-hns.txt"
      elif [[ "$test_log_file" == *"zonal"* ]]; then
        output_file="$HOME/logs-zonal.txt"
      else
        output_file="$HOME/logs.txt"
      fi

      echo "=== Log for ${test_log_file} ===" >> "$output_file"
      cat "$log_file" >> "$output_file"
      echo "=========================================" >> "$output_file"
    fi
  done
}


function log_based_on_exit_status() {
  gather_test_logs
  local -n exit_status_array=$1
  for testcase in "${!exit_status_array[@]}"
    do
        if [ "${exit_status_array["$testcase"]}" != 0 ];
        then 
            echo "Test failures detected in $testcase bucket." &>> ~/logs-$testcase.txt
        else
            touch success-$testcase.txt
            gcloud storage cp success-$testcase.txt gs://gcsfuse-release-packages/v${RELEASEVERSION}/ubuntu-vm/
        fi

    done

}

function run_tests_in_foreground_and_return_exit_code() {
    local testcase=$1
    local test_dir_parallel_name=$2 # Name of the parallel array
    local test_dir_non_parallel_name=$3 # Name of the non-parallel array
    local zonal=$4

    # Pass the names of the arrays, not the arrays themselves
    run_e2e_tests "$testcase" "$test_dir_parallel_name" "$test_dir_non_parallel_name" "$zonal"
    local e2e_tests_exit_code=$?
    return "$e2e_tests_exit_code"
}

# if I dont use it here, then wait will make it blocking
function run_tests_in_background_and_return_pid(){
    local testcase=$1
    local test_dir_parallel_name=$2
    local test_dir_non_parallel_name=$3
    local zonal=$4

    # Pass the names of the arrays
    run_e2e_tests "$testcase" "$test_dir_parallel_name" "$test_dir_non_parallel_name" "$zonal" &
    local e2e_tests_pid=$!
    echo "$e2e_tests_pid" # Echo the PID so it can be captured
}


function return_exit_status_for_pid(){
  local -n testcase_pid=$1
  local -n testcase_status=$2
  for scenario in "${testcase_pid[@]}"; do
    local pid=${testcase_pid[$scenario]}
    wait $pid
    testcase_status=$?
  done
  
}

function run_e2e_tests_for_emulator_and_log() {
  ./tools/integration_tests/emulator_tests/emulator_tests.sh true > ~/logs-emulator.txt
  emulator_test_status=$?
  if [ $e2e_tests_emulator_status != 0 ];
    then
        echo "Test failures detected in emulator based tests." &>> ~/logs-emulator.txt
    else
        touch success-emulator.txt
        gcloud storage cp success-emulator.txt gs://gcsfuse-release-packages/v$(sed -n 1p ~/details.txt)/$(sed -n 3p ~/details.txt)/
    fi
    gcloud storage cp ~/logs-emulator.txt gs://gcsfuse-release-packages/v$(sed -n 1p ~/details.txt)/$(sed -n 3p ~/details.txt)/
}

if [[ "$RUN_READ_CACHE_TESTS_ONLY" == "true" ]]; then
    read_cache_test_dir_parallel=() # Empty for read cache
    read_cache_test_dir_non_parallel=("read_cache")

    declare -A exit_status
    # Pass the NAMES of the arrays to the functions
    run_tests_in_foreground_and_return_exit_code "flat" "read_cache_test_dir_parallel" "read_cache_test_dir_non_parallel" false
    exit_status["flat"]=$?

    run_tests_in_foreground_and_return_exit_code "hns" "read_cache_test_dir_parallel" "read_cache_test_dir_non_parallel" false
    exit_status["hns"]=$?

    run_tests_in_foreground_and_return_exit_code "zonal" "read_cache_test_dir_parallel" "read_cache_test_dir_non_parallel" true
    exit_status["zonal"]=$?

    log_based_on_exit_status exit_status
  

else   
    local_test_dir_parallel_name="TEST_DIR_PARALLEL" # Use the name of the global array in su5
    local_test_dir_non_parallel_name="TEST_DIR_NON_PARALLEL" # Use the name of the global array in su5

    if [[ "$RUN_ON_ZB_ONLY" == "true" ]]; then
        declare -A exit_status_zonal
        run_tests_in_foreground_and_return_exit_code "zonal" "$local_test_dir_parallel_name" "$local_test_dir_non_parallel_name" true
        exit_status_zonal["zonal"]=$?

        log_based_on_exit_status exit_status_zonal
    else
        declare -A testcase_pids # To store PIDs
        declare -A exit_status # To store exit statuses

        # Capture PID using command substitution
        testcase_pids["flat"]=$(run_tests_in_background_and_echo_pid "flat" "$local_test_dir_parallel_name" "$local_test_dir_non_parallel_name" false)
        testcase_pids["hns"]=$(run_tests_in_background_and_echo_pid "hns" "$local_test_dir_parallel_name" "$local_test_dir_non_parallel_name" false)

        # Wait for PIDs and populate exit_status associative array
        return_exit_status_for_pid testcase_pids exit_status

        log_based_on_exit_status exit_status

        run_e2e_tests_for_emulator_and_log
    fi

fi

'
