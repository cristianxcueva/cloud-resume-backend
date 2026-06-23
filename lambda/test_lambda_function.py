import boto3
import json
from moto import mock_aws

@mock_aws
def test_first_visitor_returns_one():
    # Create the fake table inside the mock
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    dynamodb.create_table(
        TableName='visitor_count',
        KeySchema=[{'AttributeName': 'id', 'KeyType': 'HASH'}],
        AttributeDefinitions=[{'AttributeName': 'id', 'AttributeType': 'S'}],
        BillingMode='PAY_PER_REQUEST'
    )

    # Import happens here, AFTER the mock is active
    import lambda_function

    response = lambda_function.lambda_handler({}, {})
    body = json.loads(response['body'])

    assert body['count'] == 1

@mock_aws
def test_second_visitor_increments_to_two():
    # Create the fake table inside the mock
    dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
    dynamodb.create_table(
        TableName='visitor_count',
        KeySchema=[{'AttributeName': 'id', 'KeyType': 'HASH'}],
        AttributeDefinitions=[{'AttributeName': 'id', 'AttributeType': 'S'}],
        BillingMode='PAY_PER_REQUEST'
    )

    # Import happens here, AFTER the mock is active
    import lambda_function

    # First visitor
    lambda_function.lambda_handler({}, {})
    # Second visitor
    response = lambda_function.lambda_handler({}, {})
    body = json.loads(response['body'])

    assert body['count'] == 2