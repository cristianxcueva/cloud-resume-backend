terraform {
  # State lives in S3, not locally, so my machine and GitHub Actions read the
  # same state. CI/CD would break without this.
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

# All four set to false here. A typical private bucket sets these to true.
# Static website hosting needs public read access, so this flips the usual
# default.
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

# depends_on matters here. Without it, Terraform sometimes applies this policy
# before the public access block finishes, and that race throws a 403.
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

# Has to stay in us-east-1 no matter where the rest of the stack lives.
# CloudFront only reads ACM certs from that region, full stop on exceptions.
resource "aws_acm_certificate" "my_certificate" {
  domain_name       = "cristianxcueva.dev"
  validation_method = "DNS"
}
# Imported, not created. Route 53 auto-creates this zone the moment a domain
# gets registered, so creating a second one here would just duplicate it.
resource "aws_route53_zone" "main" {
  name = "cristianxcueva.dev"
}

# for_each handles this dynamically because ACM can return more than one
# validation challenge depending on the cert request. Hardcoding a single
# record would break on a cert with multiple SANs.
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

# Points at the validation resource instead of the cert directly. That way
# Terraform waits for ACM to actually confirm domain ownership before
# CloudFront tries to use the cert.
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

  # Origin points at the S3 website endpoint, not the regular bucket endpoint.
  # Website endpoints only speak HTTP and don't support OAC, so this has to
  # be a custom origin (http-only), not a native S3 origin.

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
    # Forces HTTPS even if someone types http://. The real security boundary
    # sits here, between user and CloudFront. CloudFront to S3 stays http-only.
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
    # sni-only is the right call for any modern browser. The alternative,
    # a dedicated IP, runs about $600/month and only matters for ancient
    # clients nobody actually uses anymore.
    ssl_support_method             = "sni-only"
    minimum_protocol_version       = "TLSv1.2_2021"
  }
}

# Uses an alias record, not a CNAME. CloudFront's IP changes, and CNAMEs
# can't sit on an apex domain anyway, so alias is the only option that works.
resource "aws_route53_record" "cloudfront_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "cristianxcueva.dev"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.my_distribution.domain_name
    # Fixed AWS value. Same across every CloudFront distribution in every account.
    zone_id                = "Z2FDTNDATAQYW2"
    evaluate_target_health = false
  }
}

# Schema-less on purpose. Only the partition key gets declared here. The
# "count" attribute is never defined in this table; Lambda creates it the
# first time update_item() runs.
resource "aws_dynamodb_table" "visitor_count_table" {
  name         = "visitor_count"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"
  attribute {
    name = "id"
    type = "S"
  }
}

# Execution role for Lambda. No instance profile needed, unlike EC2. Lambda
# takes a role directly through the role argument.
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

# Least privilege: GetItem and UpdateItem only. This function never deletes
# items or creates tables, so those permissions stay off the list.
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

# AWS-managed policy. I didn't write this one. It attaches CloudWatch logging
# permissions that already exist instead of reinventing JSON every Lambda
# function needs anyway.
resource "aws_iam_role_policy_attachment" "lambda_logging" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Zips the Python file on every terraform apply. output_base64sha256 is what
# lets Terraform detect a code change and trigger a redeploy.
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file  = "${path.module}/../lambda/lambda_function.py"
  output_path = "${path.module}/../lambda/lambda_function.zip"
}

# AWS lambda function for visitor count
resource "aws_lambda_function" "visitor_count_lambda" {
  function_name = "visitor_count_lambda"
  # Needs .arn here, not .name. The policy attachments above use .name, so
  # this is an easy one to mix up.
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
# Locked to my exact domain instead of a wildcard. Least privilege applies
# to CORS too, and this keeps other sites from embedding calls to my API.
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
  # invoke_arn here, not .arn. Different attribute, built specifically for
  # invocation rather than just identifying the function.
  integration_uri  = aws_lambda_function.visitor_count_lambda.invoke_arn
  # Lambda proxy integrations always use POST under the hood no matter what
  # method the public route actually exposes.
  integration_method = "POST"
  payload_format_version = "2.0"
} 

# AWS api gateway route for visitor count
resource "aws_apigatewayv2_route" "visitor_count_route" {
  api_id    = aws_apigatewayv2_api.visitor_count_api.id
  route_key = "GET /visitor-count"
target    = "integrations/${aws_apigatewayv2_integration.visitor_count_integration.id}"
} 

# $default skips the stage prefix in the URL, so no /prod/ or /staging/.
# Fine for now since this project has no second environment to separate.

resource "aws_apigatewayv2_stage" "visitor_count_stage" {
  api_id      = aws_apigatewayv2_api.visitor_count_api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 10
    throttling_rate_limit  = 5
  }
} 

# A resource-based permission, different from the execution role above. This
# one controls who can invoke Lambda from outside. The execution role
# controls what Lambda can do once it's running. Two separate trust
# relationships, not the same thing twice.

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

# Dedicated user for the backend repo's pipeline. I kept this separate from
# my own CLI credentials (iamadmin-general) on purpose. A human running
# commands deliberately is a different risk than an unsupervised pipeline,
# so the pipeline gets its own tighter-scoped identity.
resource "aws_iam_user" "github_actions_user" {
  name = "github-actions-user"
}

# Middle ground: broad managed policies, one per service, instead of full
# admin access on one end or a hand-written minimal policy for every single
# action on the other.

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

# Custom-scoped instead of IAMFullAccess. That managed policy can touch any
# IAM resource in the account, including ones that don't exist yet, which
# is too much power for what this pipeline actually needs. This policy
# limits both the actions and the Resource list to the two IAM entities
# this project actually manages: lambda_role and this user itself. The user
# needs permission to manage itself too (GetUser, etc.), which is the part
# that broke the first deploy attempt.
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

# A second, even narrower user for the frontend repo. It only ever syncs to
# S3 and invalidates CloudFront, nothing else in this project touches it.
resource "aws_iam_user" "github_actions_frontend_user" {
  name = "github-actions-frontend-user"
}

# Two separate statements here, not one combined block. S3 actions and
# CloudFront actions each need to pair with their own matching resource
# type. Mixing an S3 action against a CloudFront ARN, or the reverse,
# doesn't mean anything even if the syntax would technically allow it.
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

