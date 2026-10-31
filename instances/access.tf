# Host access over Session Manager: who may open a session to the instance, the one
# session document they may open, what the instance agent may do, and where the
# host's SSH login lines are kept off the host.
#
#   WSL / Mac IAM users ─┐
#   backend deploy role ─┼─ ssm:StartSession ─► MarketDataNotification-SSH22 ─► agent ─► sshd :22
#   infra start role ────┘   (this instance only)  (port fixed at 22)
#
#   sshd ─► /var/log/auth.log ─► amazon-cloudwatch-agent ─► /market-data-notification/sshd (90 days)
#
# Why each choice was made is in the comment above each block. How the operator reaches
# the host, re-pins after a rebuild and breaks glass: instances/README.md. The rule against
# public SSH and its CI check: AGENTS.md.

locals {
  ssh_session_document_name = "MarketDataNotification-SSH22"
  sshd_log_group_name       = "/market-data-notification/sshd"

  # GitHub's legacy subject form. A repo rename, a transfer, or opting into GitHub's
  # immutable subject claims switches `sub` to repo:OWNER@ID/REPO@ID:..., and every
  # assume-role then fails closed. Re-check the repo's OIDC customization before any of
  # those (third-party audit of configure-aws-credentials, residual risk 2).
  backend_deploy_github_subject = "repo:hanchiang/market-data-notification:ref:refs/heads/master"
  infra_start_github_subject    = "repo:hanchiang/market-data-notification-infra:ref:refs/heads/master"
}

#### Session document

# Port fixed at 22 and no parameters: the AWS-owned port documents take the port from
# the caller, so an AWS key alone would reach Redis or Postgres on loopback. Forwards
# to those services ride inside SSH instead (`ssh -L`).
#
# The content must never gain "type": "LocalPortForwarding": the Session Manager
# plugin then opens a local listener instead of using stdio, and every ProxyCommand
# hangs. tests/test_ssm_document.py pins the property set.
resource "aws_ssm_document" "ssh22" {
  name            = local.ssh_session_document_name
  document_type   = "Session"
  document_format = "JSON"
  content         = file("${path.module}/ssm/MarketDataNotification-SSH22.json")
}

#### Callers

# One provider per issuer URL per account, shared by every role that trusts GitHub.
# Created here for the host-access roles. The stop workflow still signs in with a static
# key; when it moves to a role, that role reuses this provider.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # Required by provider 4.20.1. AWS verifies this issuer against its trusted CA
  # library, not these values; both of GitHub's published thumbprints are listed.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name = "github_actions"
  }

  # Destroying it breaks every role that trusts GitHub at once.
  lifecycle {
    prevent_destroy = true
  }
}

# Every caller gets this and nothing else for the host.
resource "aws_iam_policy" "host_ssh" {
  name        = "market_data_notification_host_ssh"
  description = "SSH sessions to the market data notification host through the fixed port 22 document"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # The instance and the fixed-port document only. SessionDocumentAccessCheck makes
        # AWS check document access even when the caller names no document, which is
        # how a default shell session is attempted.
        Sid      = "StartSshSessionToThisHostOnly"
        Effect   = "Allow"
        Action   = "ssm:StartSession"
        Resource = [aws_instance.web.arn, aws_ssm_document.ssh22.arn]
        Condition = {
          BoolIfExists = {
            "ssm:SessionDocumentAccessCheck" = "true"
          }
        }
      },
      {
        # IAM users: a session id starts with the caller's user name
        # (market-data-host-ssh-wsl-<suffix>, read 2026-10-28), so this names only the
        # caller's own sessions. OpenDataChannel stays: plugins since 1.2.764.0 sign that call
        # with the caller's credentials, and AWS's end-user sample policies grant it.
        Sid      = "OwnSessionsIamUser"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession", "ssmmessages:OpenDataChannel"]
        Resource = "arn:aws:ssm:*:*:session/$${aws:username}-*"
      },
      {
        # Assumed roles: the session id starts with the role session name, so AWS's
        # tag-condition form for assumed-role callers applies.
        Sid      = "OwnSessionsAssumedRole"
        Effect   = "Allow"
        Action   = ["ssm:TerminateSession", "ssm:ResumeSession", "ssmmessages:OpenDataChannel"]
        Resource = "arn:aws:ssm:*:*:session/*"
        Condition = {
          StringLike = {
            "ssm:resourceTag/aws:ssmmessages:session-id" = "$${aws:userid}*"
          }
        }
      },
    ]
  })
}

# One user per machine, so CloudTrail names the machine and either can be revoked
# alone. Access keys are created by the operator with the CLI, never here, so the
# secret never lands in Terraform Cloud state.
resource "aws_iam_user" "host_ssh" {
  for_each = toset(["market-data-host-ssh-wsl", "market-data-host-ssh-mac"])
  name     = each.key

  tags = {
    Name = each.key
  }
}

resource "aws_iam_user_policy_attachment" "host_ssh" {
  for_each   = aws_iam_user.host_ssh
  user       = each.value.name
  policy_arn = aws_iam_policy.host_ssh.arn
}

# Exact-match subject on the default branch: a dispatch from any other branch, a
# pull_request run, or a job with an `environment:` gets a different `sub` and is refused.
data "aws_iam_policy_document" "github_assume_role" {
  for_each = {
    backend_deploy = local.backend_deploy_github_subject
    infra_start    = local.infra_start_github_subject
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role" "backend_deploy" {
  name               = "market-data-backend-deploy"
  description        = "Backend deploy and cron-install workflows: SSH to the host over Session Manager"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role["backend_deploy"].json

  tags = {
    Name = "market-data-backend-deploy"
  }
}

resource "aws_iam_role_policy_attachment" "backend_deploy_host_ssh" {
  role       = aws_iam_role.backend_deploy.name
  policy_arn = aws_iam_policy.host_ssh.arn
}

# The start path moves to OIDC whole (design gate item 2), so one job never holds two
# AWS credentials.
resource "aws_iam_role" "infra_start" {
  name               = "market-data-infra-start"
  description        = "Infra start workflow and its host access health job"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role["infra_start"].json

  tags = {
    Name = "market-data-infra-start"
  }
}

resource "aws_iam_role_policy_attachment" "infra_start_host_ssh" {
  role       = aws_iam_role.infra_start.name
  policy_arn = aws_iam_policy.host_ssh.arn
}

# What start.sh, update-ec2-route53.sh, wait_for_route53_change.sh,
# wait_for_ssm_online.sh and check_host_access_health.sh call, and nothing else.
resource "aws_iam_role_policy" "infra_start" {
  name = "market_data_notification_infra_start"
  role = aws_iam_role.infra_start.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "StartThisInstance"
        Effect   = "Allow"
        Action   = "ec2:StartInstances"
        Resource = aws_instance.web.arn
      },
      {
        Sid      = "UpdateTheServiceRecord"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = "arn:aws:route53:::hostedzone/${var.route53_hosted_zone_id}"
      },
      {
        Sid      = "WaitForTheRecordChange"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        # These actions take no resource-level scoping.
        Sid    = "ReadOnlyLookups"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeSecurityGroups",
          "ssm:DescribeInstanceInformation",
          "cloudwatch:GetMetricStatistics",
        ]
        Resource = "*"
      },
    ]
  })
}

#### Instance side

# aws_iam_role.letsencrypt_backup is the host's only role: an instance takes one, and S3
# backup was its first job, hence the name. Every host grant attaches to it.

# AWS's minimal agent set for Session Manager without session logging. Not
# AmazonSSMManagedInstanceCore, which can read every Parameter Store value in the
# account. The ssmmessages actions take no resource scoping. The agent will log
# access-denied lines for features it is not granted (associations, inventory).
resource "aws_iam_role_policy" "session_manager_agent" {
  name = "session_manager_agent"
  role = aws_iam_role.letsencrypt_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
    ]
  })
}

# Terraform owns retention, so the agent config sets none and the agent never needs
# DescribeLogGroups or PutRetentionPolicy.
resource "aws_cloudwatch_log_group" "sshd" {
  name              = local.sshd_log_group_name
  retention_in_days = 90

  tags = {
    Name = "market_data_notification_sshd"
  }
}

# Write-only: the one exception Goal 5 allows. Both actions authorize only on the
# log-stream resource type, so a bare group ARN would deny every push. No read, no
# delete, no group create: an intruder with root can add lines but not erase sent ones.
resource "aws_iam_role_policy" "ssh_login_log_push" {
  name = "ssh_login_log_push"
  role = aws_iam_role.letsencrypt_backup.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.sshd.arn}:log-stream:*"
      },
    ]
  })
}

#### Outputs the operator copies into GitHub settings and SSH configs

output "instance_id" {
  description = "PRODUCTION_INSTANCE_ID variable in the backend repo, and HostName in each machine's SSH entry"
  value       = aws_instance.web.id
}

output "backend_deploy_role_arn" {
  description = "AWS_HOST_SSH_ROLE_ARN secret in the backend repo"
  value       = aws_iam_role.backend_deploy.arn
}

output "infra_start_role_arn" {
  description = "AWS_START_ROLE_ARN secret in the infra repo"
  value       = aws_iam_role.infra_start.arn
}

output "ssh_session_document_name" {
  value = aws_ssm_document.ssh22.name
}

output "sshd_log_group_name" {
  value = aws_cloudwatch_log_group.sshd.name
}
