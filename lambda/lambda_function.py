import boto3

import json

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('visitor_count')

def lambda_handler(event, context):
    response = table.update_item(
        Key={'id': 'visitor_count'},
        UpdateExpression='SET #c = if_not_exists(#c, :start) + :inc',
        ExpressionAttributeNames={'#c': 'count'},
        ExpressionAttributeValues={':start': 0, ':inc': 1},
        ReturnValues='UPDATED_NEW'
    )
    visitor_count = response['Attributes']['count']
    
    

    return {
        'statusCode': 200,
        'body': json.dumps({'count': int(visitor_count)})
    }