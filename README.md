# Bedrock Agents Security Log Summarizer Demo
This demo shows the use of Amazon Bedrock Agents to allow natural language queries of security logs, using AWS Glue and Amazon Athena to retrieve the information stored in a S3 bucket, and Claude 3 Haiku as the LLM powering Bedrock Agents. 

## Disclaimer
This code is for demonstration purposes only, some of the IAM roles are overly permissive and not meant for production use.

## Architecture
![alt text](img/architecture.png "Architecture")

## Deployment

### Enable LLM model
Before Bedrock LLM models can be used, they need to be enabled. This only needs to be done once per AWS account.

On the AWS console, go to Bedrock, scroll down and at the left bottom of the page, click on "Model Access" and select to enable "Claude 3 Haiku". 

### Deploy Infrastructure 

There are two CloudFormation templates provided, to get around the circular dependencies between the AWS Lambda function and Amazon Bedrock. A bash script is used to orchestrate this deployment and upload the sample files.

Go to the AWS console, open a terminal, clone or upload this repository, and run:
```
cd infrastructure
./deploy_infrastructure.sh
```

The deployment script will:
- Create S3 buckets for logs and Athena query results
- Deploy Lambda function with proper IAM permissions
- Set up AWS Glue database and crawler
- Configure Athena workgroup
- Deploy Bedrock Agent with Action Groups
- Upload sample data and start the Glue crawler

## Testing
Go to AWS Console > Bedrock > Agents and paste one of the questions from the file _questions.txt_. You can validate the responses by checking the values in the _data_ folder.

Example questions:
- "What were the actions of user01 on 2024-10-17?"
- "Show me all actions on October 17, 2024"
- "What happened during hour 1 on 2024-10-17?"

## Next Steps
In order to extend the functionality of this agent, you can edit the Lambda function in _infrastructure/lambda_function.py_ and update the deployment.

## Deleting
The deployment script will generate a _delete_infrastructure_updated.sh_ script with the actual stack names and bucket names. This can be used to delete the created resources once you are done.

Run:
```
./delete_infrastructure_updated.sh
```

### Manual Cleanup (if needed)
If the automated cleanup script fails, you may need to manually:
- Empty all S3 buckets (logs, Athena output, and Lambda code buckets)
- Delete the Athena workgroup in AWS Console > Athena > Administration > Workgroups
- Delete the CloudFormation stacks in order (Stack 2 first, then Stack 1)

### Note on Deleting
The deletion script should remove all resources in the case of a successful deployment. If your deployment failed, you may need to manually clean up partially created resources before the CloudFormation stacks can be deleted.

## Architecture Details

### Two-Stack Approach
The solution uses two CloudFormation stacks to avoid circular dependencies:
- **Stack 1** (`infrastructure_1.yaml`): S3 buckets, Lambda function, Glue database/crawler, Athena workgroup
- **Stack 2** (`infrastructure_2.yaml`): Bedrock Agent with Action Groups that reference the Lambda function from Stack 1

### Key Components
- **AWS Glue**: Automatically discovers and catalogs log schema
- **Amazon Athena**: Executes SQL queries directly against S3 data
- **AWS Lambda**: Processes Bedrock Agent requests and executes Athena queries
- **Amazon Bedrock Agent**: Provides natural language interface powered by Claude 3 Haiku
- **S3**: Stores security logs and Athena query results

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
