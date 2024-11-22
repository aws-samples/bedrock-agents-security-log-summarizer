import os
import json
import boto3
import time
import logging

# Initialize Athena and S3 clients
athena = boto3.client('athena')
s3 = boto3.client('s3')

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables, set through CloudFormation
DATABASE = os.environ.get('DATABASE', 'default_database')  # Default to 'default_database' if not set
TABLE = os.environ.get('TABLE', 'default_table')  # Default to 'default_table' if not set
OUTPUT_LOCATION = os.environ.get('OUTPUT_LOCATION', 's3://default-output-bucket/')  # Default location
ATHENA_WORKGROUP = os.environ.get('ATHENA_WORKGROUP', 'primary') 
BEDROCK_AGENT_ACTION_GROUP = os.environ.get('BEDROCK_AGENT_ACTION_GROUP', 'QueryAthenaSecurityLogs') 

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    
    # Extract the date and hour from the event or input parameters
    try:
        properties = event['requestBody']['content']['application/json']['properties']
        params = {item['name']: item['value'] for item in properties}
        year = params.get('year', '2024')
        month = params.get('month', '10')
        day = params.get('day', '17')
        hour = params.get('hour', '01')  # Use hour from requestBody, default to '01' if not provided
    except KeyError as e:
        logger.error(f"Missing required parameter: {e}")
        return {
            "response": {
                'actionGroup': "accesslogs",
                'apiPath': "/query-logs",
                'httpMethod': "POST",
                'httpStatusCode': 400,
                'responseBody': {
                    'application/json': {
                        'body': {'error': f"Missing required parameter: {str(e)}"}
                    }
                }
            }
        }
    
    # Build the SQL query to filter logs for the specified hour
    #query = f"""
    #SELECT * FROM {TABLE}
    #WHERE year='{year}' AND month='{month}' AND day='{day}' AND hour='{hour}'
    #"""
    # Initialize base query
    query = f"SELECT * FROM {TABLE} WHERE 1=1"

    # Add conditions for year, month, day, and hour if their values are not 'any'
    if year.lower() != 'any':
        query += f" AND year='{year}'"
    if month.lower() != 'any':
        query += f" AND month='{month}'"
    if day.lower() != 'any':
        query += f" AND day='{day}'"
    if hour.lower() != 'any':
        query += f" AND hour='{hour}'"
    
    logger.info(f"Running query: {json.dumps(query)}")
    # Start the Athena query execution
    response = athena.start_query_execution(
        QueryString=query,
        QueryExecutionContext={'Database': DATABASE},
        ResultConfiguration={'OutputLocation': OUTPUT_LOCATION},
        WorkGroup=ATHENA_WORKGROUP
    )
    logger.info(f"Result: {json.dumps(response)}")
    # Get the query execution ID
    query_execution_id = response['QueryExecutionId']
    
    # Wait for the query to finish
    status = 'RUNNING'
    while status in ['RUNNING', 'QUEUED']:
        response = athena.get_query_execution(QueryExecutionId=query_execution_id)
        status = response['QueryExecution']['Status']['State']
        if status in ['SUCCEEDED', 'FAILED', 'CANCELLED']:
            break
        time.sleep(1)
    
    # Prepare the response structure
    # VERY IMPORTANT - THIS ACTION GROUP PARAMETER MUST MATCH THE BEDROCK AGENT ACTION GROUP NAME
    # this is taken care of by the CloudFormation, which inserts the correct value in the Lambda environment variable
    action_group = BEDROCK_AGENT_ACTION_GROUP
    api_path = "/query-logs"
    http_method = "POST"
    
    # If the query failed, retrieve the failure reason
    if status == 'FAILED':
        failure_reason = response['QueryExecution']['Status']['StateChangeReason']
        sult = {
            "response": {
                'actionGroup': action_group,
                'apiPath': api_path,
                'httpMethod': http_method,
                'httpStatusCode': 500,
                'responseBody': {
                    'application/json': {
                        'body': {'error': f'Athena query failed with reason: {failure_reason}'}
                    }
                }
            }
        }
        logger.info(f"Response failed: {json.dumps(sult)}")
        return sult
    
    # If the query succeeded, retrieve the results
    if status == 'SUCCEEDED':
        result = athena.get_query_results(QueryExecutionId=query_execution_id)
        logs = []
        for row in result['ResultSet']['Rows'][1:]:  # Skip header
            logs.append(row['Data'])
        
        sult = {
            "response": {
                'actionGroup': action_group,
                'apiPath': api_path,
                'httpMethod': http_method,
                'httpStatusCode': 200,
                'responseBody': {
                    'application/json': {
                        'body': {'logs': logs}
                    }
                }
            }
        }
        logger.info(f"Response success: {json.dumps(sult)}")
        return sult
    
    # Handle other cases
    else:
        sult = {
            "response": {
                'actionGroup': action_group,
                'apiPath': api_path,
                'httpMethod': http_method,
                'httpStatusCode': 500,
                'responseBody': {
                    'application/json': {
                        'body': {'error': f'Athena query failed with status {status}'}
                    }
                }
            }
        }
        logger.info(f"Response server error: {json.dumps(sult)}")
        return sult
