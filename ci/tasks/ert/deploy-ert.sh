#!/bin/bash
set -e

# Setup OM Tool
sudo cp tool-om/om-linux /usr/local/bin
sudo chmod 755 /usr/local/bin/om-linux

# Set Vars

# Set JSON Config Template and insert Concourse Parameter Values
json_file_path="gcp-concourse/json-opsman/${gcp_pcf_terraform_template}"
json_file_template="${json_file_path}/ert-template.json"
json_file="${json_file_path}/ert.json"

cp ${json_file_template} ${json_file}

perl -pi -e "s/{{gcp_region}}/${gcp_region}/g" ${json_file}
perl -pi -e "s/{{gcp_zone_1}}/${gcp_zone_1}/g" ${json_file}
perl -pi -e "s/{{gcp_zone_2}}/${gcp_zone_2}/g" ${json_file}
perl -pi -e "s/{{gcp_zone_3}}/${gcp_zone_3}/g" ${json_file}
perl -pi -e "s/{{gcp_terraform_prefix}}/${gcp_terraform_prefix}/g" ${json_file}
if [[ ! ${pcf_ert_ssl_cert} == "generate" ]]; then
   my_pcf_ert_ssl_cert=$(echo ${pcf_ert_ssl_cert} | sed 's/\s\+/\\\\r\\\\n/g' | sed 's/\\\\r\\\\nCERTIFICATE/ CERTIFICATE/g')
   my_pcf_ert_ssl_key=$(echo ${pcf_ert_ssl_key} | sed 's/\s\+/\\\\r\\\\n/g' | sed 's/\\\\r\\\\nRSA\\\\r\\\\nPRIVATE\\\\r\\\\nKEY/ RSA PRIVATE KEY/g')
   perl -pi -e "s|{{pcf_ert_ssl_cert}}|${my_pcf_ert_ssl_cert}|g" ${json_file}
   perl -pi -e "s|{{pcf_ert_ssl_key}}|${my_pcf_ert_ssl_key}|g" ${json_file}
fi
perl -pi -e "s/{{pcf_ert_domain}}/${pcf_ert_domain}/g" ${json_file}
perl -pi -e "s/{{gcp_storage_access_key}}/${gcp_storage_access_key}/g" ${json_file}
perl -pi -e "s/{{gcp_storage_secret_key}}/${gcp_storage_secret_key}/g" ${json_file}



if [[ ! -f ${json_file} ]]; then
  echo "Error: cant find file=[${json_file}]"
  exit 1
fi

function fn_om_linux_curl {

    local curl_method=${1}
    local curl_path=${2}
    local curl_data=${3}

     curl_cmd="om-linux --target https://opsman.$pcf_ert_domain -k \
            --username \"$pcf_opsman_admin\" \
            --password \"$pcf_opsman_admin_passwd\"  \
            curl \
            --request ${curl_method} \
            --path ${curl_path}"

    if [[ ! -z ${curl_data} ]]; then
       curl_cmd="${curl_cmd} \
            --data '${curl_data}'"
    fi

    echo ${curl_cmd} > /tmp/rqst_cmd.log
    exec_out=$( ( (eval ${curl_cmd} | tee /tmp/rqst_stdout.log) 3>&1 1>&2 2>&3 | tee /tmp/rqst_stderr.log) &>/dev/null)

    if [[ $(cat /tmp/rqst_stderr.log | grep "Status:" | awk '{print$2}') != "200" ]]; then
      echo "Error Call Failed ...."
      echo $(cat /tmp/rqst_stderr.log)
      #exit 1
    else
      echo $(cat /tmp/rqst_stdout.log)
    fi
}



echo "=============================================================================================="
echo "Deploying ERT @ https://opsman.$pcf_ert_domain ..."
echo "=============================================================================================="
# Get cf Product Guid
guid_cf=$(fn_om_linux_curl "GET" "/api/v0/staged/products" \
            | jq '.[] | select(.type == "cf") | .guid' | tr -d '"' | grep "cf-.*")

echo "=============================================================================================="
echo "Found ERT Deployment with guid of ${guid_cf}"
echo "=============================================================================================="

# Set Networks & AZs
echo "=============================================================================================="
echo "Setting Availability Zones & Networks for: ${guid_cf}"
echo "=============================================================================================="

json_net_and_az=$(cat ${json_file} | jq .networks_and_azs)
fn_om_linux_curl "PUT" "/api/v0/staged/products/${guid_cf}/networks_and_azs" "${json_net_and_az}"

# Set ERT Properties
echo "=============================================================================================="
echo "Setting Properties for: ${guid_cf}"
echo "=============================================================================================="

json_properties=$(cat ${json_file} | jq .properties)
fn_om_linux_curl "PUT" "/api/v0/staged/products/${guid_cf}/properties" "${json_properties}"

# Set Resource Configs
echo "=============================================================================================="
echo "Setting Resource Job Properties for: ${guid_cf}"
echo "=============================================================================================="
json_jobs_configs=$(cat ${json_file} | jq .jobs )
json_job_guids=$(fn_om_linux_curl "GET" "/api/v0/staged/products/${guid_cf}/jobs" | jq .)

for job in $(echo ${json_jobs_configs} | jq . | jq 'keys' | jq .[] | tr -d '"'); do

 json_job_guid_cmd="echo \${json_job_guids} | jq '.jobs[] | select(.name == \"${job}\") | .guid' | tr -d '\"'"
 json_job_guid=$(eval ${json_job_guid_cmd})
 json_job_config_cmd="echo \${json_jobs_configs} | jq '.[\"${job}\"]' "
 json_job_config=$(eval ${json_job_config_cmd})
 echo "---------------------------------------------------------------------------------------------"
 echo "Setting ${json_job_guid} with --data=${json_job_config}..."
 fn_om_linux_curl "PUT" "/api/v0/staged/products/${guid_cf}/jobs/${json_job_guid}/resource_config" "${json_job_config}"

done


# Apply Changes in Opsman
echo "=============================================================================================="
echo "Applying OpsMan Changes to Deploy: ${guid_cf}"
echo "=============================================================================================="
om-linux --target https://opsman.$pcf_ert_domain -k \
       --username "$pcf_opsman_admin" \
       --password "$pcf_opsman_admin_passwd" \
  apply-changes
