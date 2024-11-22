#!/bin/bash
set -x

# Create the bucket with a random string
BUCKET_NAME=bedrock-agent-lambda-$(uuidgen | cut -d'-' -f1)
# Update delete file for future cleanup
sed "s/YOUR-LAMBDA-CODE-BUCKET/$BUCKET_NAME/g" delete_infrastructure.template > delete_infrastructure_updated.temp
echo "Checking if S3 bucket $BUCKET_NAME exists..."

# Check if the bucket exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists. Skipping creation."
else
    echo "Bucket $BUCKET_NAME does not exist. Creating it..."
    aws s3 mb s3://$BUCKET_NAME --region us-east-1
    # Upload the ZIP file
    echo "Zipping and Uploading Lambda function ZIP file to S3 bucket..."
    zip lambda_function.zip lambda_function.py
    aws s3 cp lambda_function.zip s3://$BUCKET_NAME/ 
fi

# Verify the upload
echo "Verifying file upload..."
aws s3 ls s3://$BUCKET_NAME/

# To avoid circular dependencies, we are using two CloudFormation templates.
# The first one deploys S3, Lambda, Glue and Athena, the second the Bedrock Agent.
# The following updates the CloudFormation template with the Lambda bucket name
TEMPLATE_FILE1="infrastructure_1.yaml"  # CloudFormation template file name
UPDATED_TEMPLATE_FILE="updated_template.yaml"  # Output updated template file name
TEMPLATE_FILE2="infrastructure_2.yaml" 

echo "Updating CloudFormation template with S3 bucket name..."
sed "s/YOUR-LAMBDA-CODE-BUCKET/$BUCKET_NAME/g" $TEMPLATE_FILE1 > $UPDATED_TEMPLATE_FILE
echo "Updated template saved to $UPDATED_TEMPLATE_FILE"

# Ensure unique deployments
STACK_NAME1="demo-security-stack-lambda-glue-$(date +%Y%m%d%H%M%S)"
STACK_NAME2="demo-security-stack-bedrock-$(date +%Y%m%d%H%M%S)"
# Update delete file for future cleanup
sed "s/YOUR-STACK-NAME1/$STACK_NAME1/g" delete_infrastructure_updated.temp > delete_infrastructure_updated.temp2
sed "s/YOUR-STACK-NAME2/$STACK_NAME2/g" delete_infrastructure_updated.temp2 > delete_infrastructure_updated.sh

# Internal cleanup
rm delete_infrastructure_updated.temp
rm delete_infrastructure_updated.temp2

# Deploy the CloudFormation stack
echo "Deploying CloudFormation stack: $STACK_NAME1"
aws cloudformation deploy \
    --template-file $UPDATED_TEMPLATE_FILE \
    --stack-name $STACK_NAME1 \
    --capabilities CAPABILITY_NAMED_IAM
echo "CloudFormation stack deployment initiated."

# Extract the values that will be referenced in the second stack
OUTPUTS=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME1 \
  --query "Stacks[0].Outputs" \
  --output json)
LAMBDA_FUNCTION_ARN=$(echo "$OUTPUTS" | jq -r '.[] | select(.OutputKey=="LambdaFunctionArn") | .OutputValue')

# Deploy the second stack
echo "Deploying CloudFormation stack: $STACK_NAME2"
aws cloudformation deploy \
  --template-file $TEMPLATE_FILE2 \
  --stack-name $STACK_NAME2 \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides LambdaFunctionArn="$LAMBDA_FUNCTION_ARN"

# Upload local files from the "/data" directory to the logs S3 bucket
echo "Uploading files from /data to the logs bucket..."
LOGS_BUCKET_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name $STACK_NAME1 \
    --query "StackResources[?LogicalResourceId=='LogsBucket'].PhysicalResourceId" \
    --output text)

if [ -d "../data/logs" ]; then
    aws s3 cp ../data/logs s3://$LOGS_BUCKET_NAME/logs/ --recursive
    echo "Files uploaded to S3 bucket: $LOGS_BUCKET_NAME/logs/"
else
    echo "Directory ../data/logs does not exist. Skipping upload."
fi

# Start the Glue crawler
echo "Starting Glue crawler..."
GLUE_CRAWLER_NAME=$(aws cloudformation describe-stack-resources \
    --stack-name $STACK_NAME1 \
    --query "StackResources[?LogicalResourceId=='GlueCrawler'].PhysicalResourceId" \
    --output text)

# Additional checks for specific resources
echo "Checking if Glue Crawler is ready..."
for i in {1..10}; do
    if aws glue get-crawler --name $GLUE_CRAWLER_NAME > /dev/null 2>&1; then
        echo "Glue Crawler is ready."
        break
    else
        echo "Waiting for Glue Crawler to be ready..."
        sleep 5
    fi
done

if [ -n "$GLUE_CRAWLER_NAME" ]; then
# Update crawler config to use one table for all paths https://docs.aws.amazon.com/glue/latest/dg/crawler-grouping-policy.html
# Currently this option is not available in Cloud Formation
    aws glue update-crawler \
        --name $GLUE_CRAWLER_NAME \
        --configuration '{"Version": 1.0, "Grouping": {"TableGroupingPolicy": "CombineCompatibleSchemas" }}' 
    aws glue start-crawler --name $GLUE_CRAWLER_NAME
    echo "Glue crawler $GLUE_CRAWLER_NAME started."
else
    echo "Glue crawler not found in the stack resources. Skipping."
fi
