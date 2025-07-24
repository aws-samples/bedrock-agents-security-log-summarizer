import os
import json
import boto3
import time
import logging
from botocore.exceptions import ClientError

# Initialize clients
athena = boto3.client('athena')
s3 = boto3.client('s3')

# Configure logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Environment variables
DATABASE = os.environ.get('GLUE_DATABASE', 'demo-securitylogsummarizer-demo-security-stack-lambda-glue-20250710101648')
TABLE = os.environ.get('TABLE', 'logs')
OUTPUT_LOCATION = os.environ.get('OUTPUT_LOCATION', 's3://athena-out-demo-security-stack-lambda-glue-20250710101648/')
ATHENA_WORKGROUP = os.environ.get('ATHENA_WORKGROUP', 'SecurityDemo-demo-security-stack-lambda-glue-20250710101648-AthenaWorkgroup')
ACTION_GROUP = os.environ.get('BEDROCK_AGENT_ACTION_GROUP', 'QueryAthenaSecurityLogs')

def create_response(status_code, body, error=None):
    """Create a standardized response for Bedrock Agent"""
    response = {
        "response": {
            'actionGroup': ACTION_GROUP,
            'apiPath': "/query-logs",
            'httpMethod': "POST",
            'httpStatusCode': status_code,
            'responseBody': {
                'application/json': {
                    'body': body
                }
            }
        }
    }
    
    if error:
        logger.error(f"Error response: {error}")
    
    logger.info(f"Response: {json.dumps(response)}")
    return response

def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")
    logger.info(f"Environment - DATABASE: {DATABASE}, TABLE: {TABLE}")
    
    try:
        # Extract parameters from Bedrock Agent event
        properties = event.get('requestBody', {}).get('content', {}).get('application/json', {}).get('properties', [])
        
        # Convert properties list to dict
        params = {}
        for prop in properties:
            if 'name' in prop and 'value' in prop:
                params[prop['name']] = prop['value']
        
        logger.info(f"Extracted parameters: {params}")
        
        # Get query parameters with defaults
        year = params.get('year', '2024')
        month = params.get('month', '10')
        day = params.get('day', '17')
        hour = params.get('hour', 'any')
        
        # Build query with quoted identifiers to handle hyphens in database/table names
        base_query = f'SELECT * FROM "{DATABASE}"."{TABLE}" WHERE 1=1'
        
        # Add conditions for year, month, day, and hour if their values are not 'any'
        if year.lower() != 'any':
            base_query += f" AND year='{year}'"
        if month.lower() != 'any':
            base_query += f" AND month='{month}'"
        if day.lower() != 'any':
            base_query += f" AND day='{day}'"
        if hour.lower() != 'any':
            base_query += f" AND hour='{hour}'"
        
        query = base_query
        logger.info(f"Executing query: {query}")
        
        # Start Athena query
        try:
            response = athena.start_query_execution(
                QueryString=query,
                QueryExecutionContext={'Database': DATABASE},
                ResultConfiguration={'OutputLocation': OUTPUT_LOCATION},
                WorkGroup=ATHENA_WORKGROUP
            )
            query_id = response['QueryExecutionId']
            logger.info(f"Query started with ID: {query_id}")
            
        except ClientError as e:
            error_msg = f"Failed to start Athena query: {str(e)}"
            return create_response(500, {'error': error_msg}, error_msg)
        
        # Wait for query completion
        max_wait = 30  # seconds
        wait_time = 0
        
        while wait_time < max_wait:
            try:
                execution = athena.get_query_execution(QueryExecutionId=query_id)
                status = execution['QueryExecution']['Status']['State']
                
                if status == 'SUCCEEDED':
                    break
                elif status == 'FAILED':
                    reason = execution['QueryExecution']['Status'].get('StateChangeReason', 'Unknown error')
                    error_msg = f"Athena query failed: {reason}"
                    return create_response(500, {'error': error_msg}, error_msg)
                elif status == 'CANCELLED':
                    error_msg = "Athena query was cancelled"
                    return create_response(500, {'error': error_msg}, error_msg)
                
                time.sleep(2)
                wait_time += 2
                
            except ClientError as e:
                error_msg = f"Error checking query status: {str(e)}"
                return create_response(500, {'error': error_msg}, error_msg)
        
        if wait_time >= max_wait:
            error_msg = "Query timed out after 30 seconds"
            return create_response(500, {'error': error_msg}, error_msg)
        
        # Get query results
        try:
            results = athena.get_query_results(QueryExecutionId=query_id)
            
            # Process results
            rows = results.get('ResultSet', {}).get('Rows', [])
            
            if len(rows) <= 1:  # Only header or no results
                return create_response(200, {
                    'message': f'No logs found for the specified criteria: year={year}, month={month}, day={day}, hour={hour}',
                    'logs': [],
                    'query': query
                })
            
            # Convert results to readable format
            headers = [col.get('VarCharValue', '') for col in rows[0].get('Data', [])]
            log_entries = []
            
            for row in rows[1:]:  # Skip header
                row_data = {}
                for i, cell in enumerate(row.get('Data', [])):
                    if i < len(headers):
                        row_data[headers[i]] = cell.get('VarCharValue', '')
                log_entries.append(row_data)
            
            return create_response(200, {
                'message': f'Found {len(log_entries)} log entries',
                'logs': log_entries,
                'query': query,
                'total_count': len(log_entries)
            })
            
        except ClientError as e:
            error_msg = f"Error retrieving query results: {str(e)}"
            return create_response(500, {'error': error_msg}, error_msg)
    
    except Exception as e:
        error_msg = f"Unexpected error in Lambda function: {str(e)}"
        logger.exception("Unexpected error occurred")
        return create_response(500, {'error': error_msg}, error_msg)
