terraform {
  # State stored remotely in S3 (not locally) so both my machine and GitHub Actions
  # read/write the same state - required for CI/CD to work without conflicts
  backend "s3" {
    bucket = "cristianxcueva-terraform-state"
    key    = "cloud-resume-challenge/terraform.tfstate"
    region = "us-east-1"
  }
 required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# S3 bucket
resource "aws_s3_bucket" "my_bucket" {

  bucket = "cristianxcueva.dev"
}       

# All 4 set to false (not true like a typical private bucket) - static website
# hosting requires public read access, the opposite of normal best practice
resource "aws_s3_bucket_public_access_block" "my_bucket_public_access_block" {

  bucket = aws_s3_bucket.my_bucket.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}       

# AWS s3 bucket website configuration
resource "aws_s3_bucket_website_configuration" "my_bucket_website" {
  bucket = aws_s3_bucket.my_bucket.id   
    index_document {
        suffix = "index.html"
    }   

    error_document {
        key = "error.html"
    }
}

# depends_on is required - without it Terraform sometimes tries to apply this
# policy before the public access block finishes, causing a 403 (race condition)
resource "aws_s3_bucket_policy" "my_bucket_policy" {
  bucket = aws_s3_bucket.my_bucket.id
    depends_on = [aws_s3_bucket_public_access_block.my_bucket_public_access_block]
    policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
        {
            Effect = "Allow"
            Principal = "*"
            Action = "s3:GetObject"
            Resource = "${aws_s3_bucket.my_bucket.arn}/*"
        }
        ]
    })
}

# Must stay in us-east-1 regardless of where other resources live - CloudFront
# only reads ACM certs from this specific region, no exceptions
resource "aws_acm_certificate" "my_certificate" {
  domain_name       = "cristianxcueva.dev"
  validation_method = "DNS"
}
# Imported, not created from scratch - Route 53 auto-creates this zone when a
# domain is registered, so creating a new one here would just cause a duplicate
resource "aws_route53_zone" "main" {
  name = "cristianxcueva.dev"
}

# for_each handles this dynamically since ACM could return multiple validation
# challenges depending on the cert request - never hardcode just one record
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.my_certificate.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  allow_overwrite = true
  zone_id = aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# References the validation resource (not the cert directly) so Terraform waits
# for ACM to actually confirm domain ownership before CloudFront tries to use it
resource "aws_acm_certificate_validation" "my_certificate_validation" {
  certificate_arn         = aws_acm_certificate.my_certificate.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

#cloudfront distribution
resource "aws_cloudfront_distribution" "my_distribution" {
  aliases             = ["cristianxcueva.dev"]
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  # Origin is the S3 *website* endpoint, not the regular bucket endpoint - website
  # endpoints only speak HTTP and don't support OAC, so this must be a custom
  # origin (http-only) rather than a native S3 origin

  origin {
    domain_name = aws_s3_bucket_website_configuration.my_bucket_website.website_endpoint
    origin_id   = "s3-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-origin"
    # Forces HTTPS even if someone types http:// - the actual security happens
    # here, not on the origin side, since CloudFront-to-S3 stays http-only
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn            = aws_acm_certificate_validation.my_certificate_validation.certificate_arn
    # sni-only is always correct for modern browsers - the alternative (vip,
    # a dedicated IP) costs ~$600/month and is only needed for ancient clients
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

# Alias record (not CNAME) because CloudFront's IP changes dynamically and
# CNAMEs can't be used on apex/root domains anyway - this is the only valid option
resource "aws_route53_record" "cloudfront_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "cristianxcueva.dev"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.my_distribution.domain_name
    # Fixed AWS value, same for every CloudFront distribution in every account
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# Schema-less by design - only the partition key is declared here. The actual
# "count" attribute doesn't exist in the table definition at all; Lambda creates
# it dynamically the first time update_item() runs
resource "aws_dynamodb_table" "visitor_count_table" {
  name         = "visitor_count"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Execution role for Lambda - no instance profile needed here (unlike EC2),
# Lambda attaches a role directly via the role argument
resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      }
    ]   
  })
}

# Least privilege: only GetItem and UpdateItem - no DeleteItem or CreateTable,
# since this function never needs to do either
resource "aws_iam_role_policy" "dynamodb_policy" {
  name = "dynamodb_policy"
  role = aws_iam_role.lambda_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Effect   = "Allow"
        Resource = aws_dynamodb_table.visitor_count_table.arn
      }
    ]
  })
}

# AWS-managed policy, not authored here - this just attaches CloudWatch logging
# permissions that already exist, rather than writing custom JSON for something
# nearly every Lambda function needs
resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Zips the Python file automatically on every terraform apply - output_base64sha256
# is what lets Terraform detect code changes and trigger a redeploy
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file  = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/../lambda/lambda_function.zip"
}

# AWS lambda function for visitor count
resource "aws_lambda_function" "visitor_count_lambda" {
  function_name = "visitor_count_lambda"
  # role needs .arn here, not .name (different requirement than the policy
  # attachments above, which use .name) - easy to mix up
  role          = aws_iam_role.lambda_role.arn
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.12"
  filename      = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
} 

# AWS api gateway http api for visitor count
resource "aws_apigatewayv2_api" "visitor_count_api" {
  name          = "visitor_count_api"
  protocol_type = "HTTP"
# Restricted to my exact domain, not a wildcard - least privilege applied to
# CORS, prevents other websites from embedding calls to this API
  cors_configuration {
    allow_origins = ["https://cristianxcueva.dev"]
    allow_methods = ["GET"]
    allow_headers = ["content-type"]
  }
}

# AWS api gateway integration for visitor count
resource "aws_apigatewayv2_integration" "visitor_count_integration" {
  api_id           = aws_apigatewayv2_api.visitor_count_api.id
  integration_type = "AWS_PROXY"
  # invoke_arn, not .arn - a different attribute specifically formatted for
  # invocation, not the function's general identifying ARN
  integration_uri  = aws_lambda_function.visitor_count_lambda.invoke_arn
  # Lambda proxy integrations always use POST internally, regardless of what
  # method the public-facing route actually uses
  integration_method = "POST"
  payload_format_version = "2.0"
} 

# AWS api gateway route for visitor count
resource "aws_apigatewayv2_route" "visitor_count_route" {
  api_id    = aws_apigatewayv2_api.visitor_count_api.id
  route_key = "GET /visitor-count"
target    = "integrations/${aws_apigatewayv2_integration.visitor_count_integration.id}"
} 

# AWS api gateway stage for visitor count
# $default avoids needing a stage prefix in the URL (no /prod/ or /staging/) -
# fine here since this project has no need for multiple environments

resource "aws_apigatewayv2_stage" "visitor_count_stage" {
  api_id      = aws_apigatewayv2_api.visitor_count_api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
} 

# Resource-based permission, NOT the same as the execution role above - this
# controls who can INVOKE Lambda from outside; the execution role controls what
# Lambda can do once it's already running. Two separate directions of trust

resource "aws_lambda_permission" "api_gateway_invoke" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.visitor_count_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.visitor_count_api.execution_arn}/*/*"
}


# Billing alarm - Cloudwatch metric
resource "aws_cloudwatch_metric_alarm" "billing_alarm" {
  alarm_name          = "billing_alarm"
  alarm_description   = "Alerts when AWS billing exceeds $10"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  
  dimensions = {
    Currency = "USD"
  }
}

# Dedicated user for the BACKEND repo's automated pipeline - deliberately separate
# from my own personal CLI credentials (iamadmin-general), since an unsupervised
# automated system warrants a tighter-scoped credential than a human using it directly
resource "aws_iam_user" "github_actions_user" {
  name = "github-actions-user"
}

# middle ground: broad managed policies per-service rather than full
# admin access, but also not a fully custom minimal policy for every single action

resource "aws_iam_user_policy_attachment" "github_s3" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

resource "aws_iam_user_policy_attachment" "github_dynamodb" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_user_policy_attachment" "github_lambda" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AWSLambda_FullAccess"
}

resource "aws_iam_user_policy_attachment" "github_apigateway" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonAPIGatewayAdministrator"
}

resource "aws_iam_user_policy_attachment" "github_cloudfront" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/CloudFrontFullAccess"
}

resource "aws_iam_user_policy_attachment" "github_route53" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonRoute53FullAccess"
}

resource "aws_iam_user_policy_attachment" "github_acm" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/AWSCertificateManagerFullAccess"
}
resource "aws_iam_user_policy_attachment" "github_cloudwatch" {
  user       = aws_iam_user.github_actions_user.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

# Custom-scoped instead of IAMFullAccess - that managed policy is disproportionately
# powerful (can act on ANY IAM resource account-wide, including future ones).
# This restricts both the actions AND, critically, the Resource list to exactly
# the two IAM entities this project actually manages (lambda_role + this user itself -
# the user needs self-management permissions like GetUser, which is what originally
# broke the first deploy attempt)
resource "aws_iam_user_policy" "github_iam_scoped" {
  name = "github-iam-scoped"
  user = aws_iam_user.github_actions_user.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = [
          # IAM actions
          "iam:CreateRole",
          "iam:GetRole",
          "iam:DeleteRole",
          "iam:TagRole",
          "iam:GetUser",
          "iam:CreateUser",
          "iam:DeleteUser",
          "iam:TagUser",
          "iam:ListAttachedUserPolicies",
          "iam:AttachUserPolicy",
          "iam:DetachUserPolicy",
          "iam:PutUserPolicy",
          "iam:GetUserPolicy",
          "iam:DeleteUserPolicy",
          #dynamodb policy actions
          "iam:PutRolePolicy",
          "iam:GetRolePolicy",
          "iam:DeleteRolePolicy",
          #cloudwatch policy actions
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies" ,
        ]
        Resource = [
          aws_iam_role.lambda_role.arn,
          aws_iam_user.github_actions_user.arn,
          aws_iam_user.github_actions_frontend_user.arn
        ]
      }
    ]
  })
}

# Separate, even MORE narrowly-scoped user for the FRONTEND repo - only ever
# needs S3 sync + CloudFront invalidation, nothing else this project does
resource "aws_iam_user" "github_actions_frontend_user" {
  name = "github-actions-frontend-user"
}

# Two separate statements (not one combined) - each action set needs to pair
# with its own matching resource type; mixing S3 actions against a CloudFront
# ARN (or vice versa) in one statement is semantically meaningless
resource "aws_iam_user_policy" "github_frontend_scoped" {
  user       = aws_iam_user.github_actions_frontend_user.name
  name = "github-frontend-scoped"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
  {
    Effect   = "Allow"
    Action   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject"]
    Resource = [
      "arn:aws:s3:::cristianxcueva.dev",
      "arn:aws:s3:::cristianxcueva.dev/*"
    ]
  },
  {
    Effect   = "Allow"
    Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    Resource = aws_cloudfront_distribution.my_distribution.arn
  }
]
  })
}

