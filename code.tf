resource "aws_bedrockagent_agent" "example" {
  agent_name              = "my-bedrock-agent"
  agent_resource_role_arn = aws_iam_role.bedrock_agent.arn
  foundation_model        = "anthropic.claude-3-sonnet-20240229-v1:0"
  instruction             = "You are a helpful assistant that answers questions about our products."
}

resource "aws_iam_role" "bedrock_agent" {
  name = "bedrock-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "bedrock_agent" {
  role = aws_iam_role.bedrock_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "bedrock:InvokeModel"
      Resource = "arn:aws:bedrock:*::foundation-model/anthropic.claude-3-sonnet-20240229-v1:0"
    }]
  })
}

#make changes to trigger documentation
