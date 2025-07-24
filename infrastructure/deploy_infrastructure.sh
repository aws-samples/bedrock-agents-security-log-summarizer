#!/bin/bash
set -e  # Exit on any error

echo "=== Bedrock Agents Security Log Summarizer Deployment ==="
echo "Starting deployment at $(date)"

# Create the bucket with a random string (lowercase for S3 compliance)
BUCKET_NAME=bedrock-agent-lambda-$(uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
echo "Generated bucket name: $BUCKET_NAME"

echo "Checking if S3 bucket $BUCKET_NAME exists..."

# Check if the bucket exists
if aws s3api head-bucket --bucket $BUCKET_NAME 2>/dev/null; then
    echo "Bucket $BUCKET_NAME already exists. Skipping creation."
else
    echo "Bucket $BUCKET_NAME does not exist. Creating it..."
    aws s3 mb s3://$BUCKET_NAME --region us-east-1
    
    # Wait for bucket to be available
    echo "Waiting for bucket to be available..."
    sleep 10
fi

# Upload the ZIP file
echo "Zipping and Uploading Lambda function ZIP file to S3 bucket..."
zip -q lambda_function.zip lambda_function.py
aws s3 cp lambda_function.zip s3://$BUCKET_NAME/ 

# Verify the upload
echo "Verifying file upload..."
aws s3 ls s3://$BUCKET_NAME/ --no-cli-pager

# To avoid circular dependencies, we are using two CloudFormation templates.
# The first one deploys S3, Lambda, Glue and Athena, the second the Bedrock Agent.
# The following updates the CloudFormation template with the Lambda bucket name
TEMPLATE_FILE1="infrastructure_1.yaml"
UPDATED_TEMPLATE_FILE1="updated_template_1.yaml"
TEMPLATE_FILE2="infrastructure_2.yaml"

echo "Updating CloudFormation template with S3 bucket name..."
sed "s/YOUR-LAMBDA-CODE-BUCKET/$BUCKET_NAME/g" $TEMPLATE_FILE1 > $UPDATED_TEMPLATE_FILE1
echo "Updated template saved to $UPDATED_TEMPLATE_FILE1"

# Ensure unique deployments
STACK_NAME1="demo-security-stack-lambda-glue-$(date +%Y%m%d%H%M%S)"
STACK_NAME2="demo-security-stack-bedrock-$(date +%Y%m%d%H%M%S)"

echo "Deploying CloudFormation Stack 1: $STACK_NAME1"
echo "Using template: $UPDATED_TEMPLATE_FILE1"

# Deploy Stack 1 (Infrastructure)
aws cloudformation create-stack \
    --stack-name $STACK_NAME1 \
    --template-body file://$UPDATED_TEMPLATE_FILE1 \
    --capabilities CAPABILITY_IAM \
    --region us-east-1

echo "CloudFormation Stack 1 creation initiated. Stack name: $STACK_NAME1"
echo "Waiting for Stack 1 creation to complete..."

# Wait for Stack 1 creation to complete
aws cloudformation wait stack-create-complete --stack-name $STACK_NAME1 --region us-east-1

if [ $? -eq 0 ]; then
    echo "✅ Stack 1 creation completed successfully!"
    
    # Get Stack 1 outputs
    echo "Getting Stack 1 outputs..."
    aws cloudformation describe-stacks --stack-name $STACK_NAME1 --region us-east-1 --query 'Stacks[0].Outputs' --no-cli-pager
    
    # Get the Lambda function name and other resources
    LAMBDA_FUNCTION_NAME=$(aws cloudformation describe-stacks --stack-name $STACK_NAME1 --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`LambdaFunctionName`].OutputValue' --output text)
    LOGS_BUCKET=$(aws cloudformation describe-stacks --stack-name $STACK_NAME1 --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`LogsBucketName`].OutputValue' --output text)
    GLUE_DATABASE=$(aws cloudformation describe-stacks --stack-name $STACK_NAME1 --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`GlueDatabaseName`].OutputValue' --output text)
    
    echo "Lambda Function: $LAMBDA_FUNCTION_NAME"
    echo "Logs S3 Bucket: $LOGS_BUCKET"
    echo "Glue Database: $GLUE_DATABASE"
    
    # Update Lambda function code
    echo "Updating Lambda function code..."
    aws lambda update-function-code \
        --function-name $LAMBDA_FUNCTION_NAME \
        --s3-bucket $BUCKET_NAME \
        --s3-key lambda_function.zip \
        --region us-east-1 \
        --no-cli-pager
    
    echo "Waiting for Lambda function update to complete..."
    aws lambda wait function-updated --function-name $LAMBDA_FUNCTION_NAME --region us-east-1
    
    # Upload sample data
    echo "Uploading sample data to S3 bucket..."
    if [ -d "../data" ]; then
        aws s3 sync ../data s3://$LOGS_BUCKET/
        echo "Sample data uploaded successfully"
        
        # Start Glue crawler
        CRAWLER_NAME="SecurityLogsCrawler-$STACK_NAME1"
        echo "Starting Glue crawler: $CRAWLER_NAME"
        aws glue start-crawler --name $CRAWLER_NAME --region us-east-1
        
        echo "Glue crawler started. Waiting for it to complete..."
        
        # Wait for crawler to complete (optional - can be done manually)
        echo "You can monitor crawler progress in the AWS Glue console."
        echo "Proceeding with Stack 2 deployment..."
        
    else
        echo "⚠️  Warning: ../data directory not found. Please upload sample data manually to s3://$LOGS_BUCKET/"
    fi
    
    # Deploy Stack 2 (Bedrock Agent)
    echo ""
    echo "Deploying CloudFormation Stack 2: $STACK_NAME2"
    echo "Using template: $TEMPLATE_FILE2"
    
    aws cloudformation create-stack \
        --stack-name $STACK_NAME2 \
        --template-body file://$TEMPLATE_FILE2 \
        --capabilities CAPABILITY_IAM \
        --parameters ParameterKey=Stack1Name,ParameterValue=$STACK_NAME1 \
        --region us-east-1
    
    echo "CloudFormation Stack 2 creation initiated. Stack name: $STACK_NAME2"
    echo "Waiting for Stack 2 creation to complete..."
    
    # Wait for Stack 2 creation to complete
    aws cloudformation wait stack-create-complete --stack-name $STACK_NAME2 --region us-east-1
    
    if [ $? -eq 0 ]; then
        echo "✅ Stack 2 creation completed successfully!"
        
        # Get Stack 2 outputs
        echo "Getting Stack 2 outputs..."
        aws cloudformation describe-stacks --stack-name $STACK_NAME2 --region us-east-1 --query 'Stacks[0].Outputs' --no-cli-pager
        
        BEDROCK_AGENT_ID=$(aws cloudformation describe-stacks --stack-name $STACK_NAME2 --region us-east-1 --query 'Stacks[0].Outputs[?OutputKey==`BedrockAgentId`].OutputValue' --output text)
        
        echo "Bedrock Agent ID: $BEDROCK_AGENT_ID"
        
        # Create delete script with actual values
        echo "Creating cleanup script..."
        sed "s/YOUR-LAMBDA-CODE-BUCKET/$BUCKET_NAME/g" delete_infrastructure.template > delete_infrastructure_updated.sh
        sed -i.bak "s/STACK_NAME1_PLACEHOLDER/$STACK_NAME1/g" delete_infrastructure_updated.sh
        sed -i.bak "s/STACK_NAME2_PLACEHOLDER/$STACK_NAME2/g" delete_infrastructure_updated.sh
        chmod +x delete_infrastructure_updated.sh
        
        echo ""
        echo "🎉 Deployment completed successfully!"
        echo ""
        echo "📋 Summary:"
        echo "  - Stack 1 Name: $STACK_NAME1"
        echo "  - Stack 2 Name: $STACK_NAME2"
        echo "  - Lambda Function: $LAMBDA_FUNCTION_NAME"
        echo "  - Bedrock Agent ID: $BEDROCK_AGENT_ID"
        echo "  - Logs Bucket: $LOGS_BUCKET"
        echo "  - Lambda Code Bucket: $BUCKET_NAME"
        echo ""
        echo "📝 Next Steps:"
        echo "  1. Wait for the Glue crawler to complete (check AWS Glue console)"
        echo "  2. Test the Bedrock agent in the AWS Bedrock console"
        echo "  3. Use questions from questions.txt for testing"
        echo ""
        echo "🗑️  To clean up resources later, run:"
        echo "  ./delete_infrastructure_updated.sh"
        
    else
        echo "❌ Stack 2 creation failed!"
        echo "Check the CloudFormation console for error details."
        exit 1
    fi
    
else
    echo "❌ Stack 1 creation failed!"
    echo "Check the CloudFormation console for error details."
    exit 1
fi

echo "Deployment script completed at $(date)"
