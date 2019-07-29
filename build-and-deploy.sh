#!/bin/bash

profile=$profile
account=$(aws sts get-caller-identity --profile sandpit --query Account --output text)
region=ap-southeast-2
esdomain=$esdomain
s3bucket=$s3bucket
myip=$(curl -s https://www.cloudflare.com/cdn-cgi/trace | grep ip| sed 's/^ip=//')
flowlogs_log_group=flow-logs
### Access Policy for ES Domain
access_policy="{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"AWS\":\"*\"},\"Action\":\"es:*\",\"Resource\":\"arn:aws:es:ap-southeast-2:$account:domain/$domain/*\",\"Condition\":{\"IpAddress\":{\"aws:SourceIp\":\"$myip\"}}}]}"

function CreateESDomain {
    aws es create-elasticsearch-domain \
    --domain-name $domain \
    --elasticsearch-version=6.7 \
    --profile $profile \
    --region $region \
    --access-policies=$access_policy \
    --elasticsearch-cluster-config '{"InstanceType": "i3.large.elasticsearch","InstanceCount": 1,"DedicatedMasterEnabled": false,"ZoneAwarenessEnabled": false}' \

    echo -e "\033[32mWaiting 10s to allow cluster to be discoverable..."
    sleep 10

    isprocessing=$(aws es describe-elasticsearch-domain --domain-name $domain --profile $profile --region $region --query DomainStatus.Processing)
    echo -en "ES Cluster is still processing: $isprocessing\n\n"
    processing_time=0

    while [[ $isprocessing == true ]]
    do
    echo -en "Post-deployment processing usually takes 360s. So far you have waited: $processing_time\r"
    sleep 5
    isprocessing=$(aws es describe-elasticsearch-domain --domain-name $domain --profile $profile --region $region --query DomainStatus.Processing)
    ((processing_time=$processing_time+5))
    done

    echo -en "\033[32mCluster Ready\n"

}

function AddFlowlogIndex {
    echo Creating Flowlogs Index Mapping...
    sleep 5
    es_endpoint=$(aws es describe-elasticsearch-domain --domain-name $domain --profile $profile --region $region --query DomainStatus.Endpoint --output text)
    echo $es_endpoint
    if $(curl -s "https://$es_endpoint/flowlogs" -H 'Content-Type: application/json' --upload-file mappings.json| grep -q true);
        then echo -e "\033[32mFlowlog Index mapping created successfully!";
        else echo -e "\033[31mFlowlog Index mapping creation failed!";
    fi
}

function CreateS3Bucket {
    aws s3 mb s3://$s3bucket --profile $profile --region $region
}

function PackageAndDeployLambdas {
    npm install decorator && npm install ingestor
    sam package --template-file template.yaml --s3-bucket $s3bucket --output-template-file packaged.yaml --profile $profile --region $region
    sam deploy --template-file packaged.yaml --stack-name vpc-flow-log-appender --capabilities CAPABILITY_IAM --profile $profile --region $region
}

function AddCloudwatchSubscription {
    local func_name=$(aws lambda list-functions  --profile $profile --region $region --query 'Functions[]|[?contains(FunctionName, `vpc-flow-log-appender-FlowLogIngestion`)].FunctionName' --output text)
    aws lambda add-permission \
        --function-name $func_name \
        --statement-id "cloudwatch-to-ingestor" \
        --principal "logs.$region.amazonaws.com" \
        --action "lambda:InvokeFunction" \
        --source-arn "arn:aws:logs:$region:$account:log-group:$flowlogs_log_group:*" \
        --source-account "$account" \
        --profile $profile \
        --region $region

    aws logs put-subscription-filter \
        --log-group-name $flowlogs_log_group \
        --filter-name flowlog-appender-subscription \
        --filter-pattern '[version, account_id, interface_id, srcaddr != "-", dstaddr != "-", srcport != "-", dstport != "-", protocol, packets, bytes, start, end, action, log_status]' \
        --destination-arn arn:aws:lambda:$region:$account:function:$func_name  \
        --profile $profile \
        --region $region
}

CreateESDomain
AddFlowlogIndex
CreateS3Bucket
PackageAndDeployLambdas
AddCloudwatchSubscription