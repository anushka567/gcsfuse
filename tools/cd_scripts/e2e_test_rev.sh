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

#details.txt file contains the release version and commit hash of the current release.
gcloud storage cp gs://gcsfuse-release-packages/version-detail/details.txt .
# Writing VM instance name to details.txt (Format: release-test-<os-name>)
curl http://metadata.google.internal/computeMetadata/v1/instance/name -H "Metadata-Flavor: Google" >>details.txt

# Based on the os type(from vm instance name) in detail.txt, run the following commands to add su2
if grep -q ubuntu details.txt || grep -q debian details.txt; then
	#  For ubuntu and debian os
	sudo adduser --ingroup google-sudoers --disabled-password --home=/home/su2 --gecos "" su2
else
	#  For rhel and centos
	sudo adduser -g google-sudoers --home-dir=/home/su2 su2
fi

# Run the following as su2
sudo -u su2 bash -c '
# Exit immediately if a command exits with a non-zero status.
set -e
# Print commands and their arguments as they are executed.
set -x

# Export the RUN_ON_ZB_ONLY variable so that it is available in the environment of the 'su2' user.
# Since we are running the subsequent script as 'su2' using sudo, the environment of 'su2' 
# would not automatically have access to the environment variables set by the original user (i.e. $RUN_ON_ZB_ONLY).
# By exporting this variable, we ensure that the value of RUN_ON_ZB_ONLY is passed into the 'su2' script 
# and can be used for conditional logic or decisions within that script.
export RUN_ON_ZB_ONLY='$RUN_ON_ZB_ONLY'
export RUN_READ_CACHE_TESTS_ONLY='$RUN_READ_CACHE_TESTS_ONLY'

#Copy details.txt to su2 home directory and create logs.txt
cd ~/
cp /details.txt .
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

if grep -q ubuntu details.txt || grep -q debian details.txt;
then
#  For Debian and Ubuntu os
    # architecture can be amd64 or arm64
    architecture=$(dpkg --print-architecture)

    sudo apt update

    #Install fuse
    sudo apt install -y fuse

    # download and install gcsfuse deb package
    gcloud storage cp gs://gcsfuse-release-packages/v$(sed -n 1p details.txt)/gcsfuse_$(sed -n 1p details.txt)_${architecture}.deb .
    sudo dpkg -i gcsfuse_$(sed -n 1p details.txt)_${architecture}.deb |& tee -a ${LOG_FILE}

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
else
#  For rhel and centos
    # uname can be aarch or x86_64
    uname=$(uname -i)

    if [[ $uname == "x86_64" ]]; then
      architecture="amd64"
    elif [[ $uname == "aarch64" ]]; then
      architecture="arm64"
    fi

    sudo yum makecache
    sudo yum -y update

    #Install fuse
    sudo yum -y install fuse

    #download and install gcsfuse rpm package
    gcloud storage cp gs://gcsfuse-release-packages/v$(sed -n 1p details.txt)/gcsfuse-$(sed -n 1p details.txt)-1.${uname}.rpm .
    sudo yum -y localinstall gcsfuse-$(sed -n 1p details.txt)-1.${uname}.rpm

    #install wget
    sudo yum -y install wget

    #install git
    sudo yum -y install git

    #install Development tools
    sudo yum -y install gcc gcc-c++ make
fi

# install go
wget -O go_tar.tar.gz https://go.dev/dl/go1.24.0.linux-${architecture}.tar.gz
sudo tar -C /usr/local -xzf go_tar.tar.gz
export PATH=${PATH}:/usr/local/go/bin
#Write gcsfuse and go version to log file
gcsfuse --version |& tee -a ${LOG_FILE}
go version |& tee -a ${LOG_FILE}

# Clone and checkout gcsfuse repo
export PATH=${PATH}:/usr/local/go/bin
git clone https://github.com/googlecloudplatform/gcsfuse |& tee -a ${LOG_FILE}
cd gcsfuse

# Installation of crcmod is working through pip only on rhel and centos.
# For debian and ubuntu, we are installing through sudo apt.
if grep -q rhel details.txt || grep -q centos details.txt;
then
    # install python3-setuptools tools and python3-pip
    sudo yum -y install gcc python3-devel python3-setuptools redhat-rpm-config
    sudo yum -y install python3-pip
    # Downloading composite object requires integrity checking with CRC32c in gsutil.
    # it requires to install crcmod.
    pip3 install --require-hashes -r tools/cd_scripts/requirements.txt --user
fi

git checkout $(sed -n 2p ~/details.txt) |& tee -a ${LOG_FILE}

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
  local exit_code=0
  local -n test_array=$1
  local BUCKET_NAME=$2
  local zonal=$3
  for test_dir_np in "${test_array[@]}"
  do
    test_path_non_parallel="./tools/integration_tests/$test_dir_np"
    # To make it clear whether tests are running on a flat or HNS or zonal bucket, We kept the log file naming
    # convention to include the bucket name as a suffix (e.g., package_name_bucket_name).
    local log_file="/tmp/${test_dir_np}_${BUCKET_NAME}.log"
    echo $log_file >> $TEST_LOGS_FILE
    # Executing integration tests
    GODEBUG=asyncpreemptoff=1 go test $test_path_non_parallel -p 1 --zonal=${zonal} --integrationTest -v --testbucket=$BUCKET_NAME --testInstalledPackage=true -timeout $INTEGRATION_TEST_TIMEOUT > "$log_file" 2>&1
    exit_code_non_parallel=$?
    if [ $exit_code_non_parallel != 0 ]; then
      exit_code=$exit_code_non_parallel
    fi
  done
  return $exit_code
}

function run_parallel_tests() {
  local exit_code=0
  local -n test_array=$1
  local BUCKET_NAME=$2
  local zonal=$3
  local pids=()

  for test_dir_p in "${test_array[@]}"
  do
    test_path_parallel="./tools/integration_tests/$test_dir_p"
    # To make it clear whether tests are running on a flat or HNS bucket, We kept the log file naming
    # convention to include the bucket name as a suffix (e.g., package_name_bucket_name).
    local log_file="/tmp/${test_dir_p}_${BUCKET_NAME}.log"
    echo $log_file >> $TEST_LOGS_FILE
    # Executing integration tests
    GODEBUG=asyncpreemptoff=1 go test $test_path_parallel -p 1 --zonal=${zonal} --integrationTest -v --testbucket=$BUCKET_NAME --testInstalledPackage=true -timeout $INTEGRATION_TEST_TIMEOUT > "$log_file" 2>&1 &
    pid=$!  # Store the PID of the background process
    pids+=("$pid")  # Optionally add the PID to an array for later
  done
  # Wait for processes and collect exit codes
  for pid in "${pids[@]}"; do
    wait $pid
    exit_code_parallel=$?
    if [ $exit_code_parallel != 0 ]; then
      exit_code=$exit_code_parallel
    fi
  done
  return $exit_code
}

function run_e2e_tests() {
  testcase= $1 // hns/flat/zonal/emulator
  test_dir_parallel=$2
  test_dir_non_parallel=$3
  is_zonal=$4

  bkt_non_parallel=$(sed -n 3p ~/details.txt)-$testcase
  echo "Bucket name to run tests sequentially: "$bkt_non_parallel

  bkt_parallel=$(sed -n 3p ~/details.txt)-$testcase-parallel
  echo "Bucket name to run tests parallelly: "$bkt_parallel

  echo "Running parallel tests..."
  run_parallel_tests $test_dir_parallel "$bkt_parallel" $is_zonal &
  parallel_tests_pid=$!

  echo "Running non parallel tests ..."
  run_non_parallel_tests $test_dir_non_parallel "$bkt_non_parallel" $is_zonal &
  non_parallel_tests_pid=$!

  # Wait for all tests to complete.
  wait $parallel_tests_pid
  parallel_tests_exit_code=$?
  wait $non_parallel_tests_pid
  non_parallel_tests_exit_code=$?

  if [ $non_parallel_tests_exit_code != 0 ]; then
    return $non_parallel_tests_exit_code
  fi

  if [ $parallel_tests_exit_code != 0 ]; then
    return $parallel_tests_exit_code
  fi
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

function wait_on_pid_and_log(declare -A testcase_pids){
    declare -A testcase_status
    for testcase in "${!testcase_pids[@]}"
    do
        local pid="${testcase_pids["$testcase"]}"
        echo "Waiting for PID $pid (Testcase: $testcase)..."
        wait $pid
        status=$?
        testcase_status[$testcase]=status

    done

    gather_test_logs

    for testcase in "${!testcase_pids[@]}"
    do
        if [ "${testcase_pids["$testcase"]}" != 0 ];
        then 
            echo "Test failures detected in $testcase bucket." &>> ~/logs-$testcase.txt
        else
            touch success-$testcase.txt
            gcloud storage cp success-$testcase.txt gs://gcsfuse-release-packages/v$(sed -n 1p ~/details.txt)/$(sed -n 3p ~/details.txt)/
        fi

    done
}


func log_based_on_exit_status(){
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
    testcase=$1
    test_dir_parallel=$2
    test_dir_non_parallel=$3
    zonal=$4

    run_e2e_tests $testcase $test_dir_parallel $test_dir_non_parallel $zonal 
    e2e_tests_exit_code=$?
    return $e2e_tests_exit_code
}

# if I dont use it here, then wait will make it blocking
function run_tests_in_background_and_return_pid(){
    testcase=$1
    test_dir_parallel=$2
    test_dir_non_parallel=$3
    zonal=$4

    run_e2e_tests $testcase $test_dir_parallel $test_dir_non_parallel $zonal &
    e2e_tests_pid=$!
    return $e2e_tests_pid
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
    test_dir_parallel = ()
    test_dir_non_parallel = ("read_cache")
    declare -A exit_status
    run_tests_in_foreground_and_return_exit_code "flat" $test_dir_parallel $test_dir_non_parallel false 
    exit_status["flat"]=$?
    run_tests_in_foreground_and_return_exit_code "hns" $test_dir_parallel $test_dir_non_parallel false 
    exit_status["hns"]=$?
    run_tests_in_foreground_and_return_exit_code "zonal" $test_dir_parallel $test_dir_non_parallel true 
    exit_status["zonal"]=$?
    
    log_based_on_exit_status $exit_status
  

else   
    test_dir_parallel = $TEST_DIR_PARALLEL
    test_dir_non_parallel = $TEST_DIR_NON_PARALLEL
    if [[ "$RUN_ON_ZB_ONLY" == "true"]]; then
        declare -A exit_status
        run_tests_in_foreground_and_return_exit_code "zonal" $test_dir_parallel $test_dir_non_parallel true 
        exit_status["zonal"]=$?
    
        log_based_on_exit_status $exit_status
    else
        declare -A testcase_pids
        declare -A exit_status
        run_tests_in_background_and_return_pid "flat" $test_dir_parallel $test_dir_non_parallel false 
        testcase_pid["flat"]=$?
        run_tests_in_background_and_return_pid "hns" $test_dir_parallel $test_dir_non_parallel false 
        testcase_pid["hns"]=$?

        return_exit_status_for_pid testcase_pids exit_status
        
        log_based_on_exit_status $exit_status

        run_e2e_tests_for_emulator_and_log
    fi

fi

'
