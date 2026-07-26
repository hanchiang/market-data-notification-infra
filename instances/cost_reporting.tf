# Keyless GitHub Actions access to Cost Explorer, used by the monthly AWS cost
# report workflow. This repository is public, so the consuming repository is
# named only in the Terraform Cloud workspace variable, never here.
#
# Placement: these are account-scoped resources, not market-data resources, and
# this is not the only Terraform state in the account -- the url-shortener
# project has its own. They live here because this state is the one that is
# actively maintained, which makes the placement a pragmatic choice rather than
# a correct one. An account can hold only one OIDC provider per issuer URL, so
# if url-shortener ever declares a provider for the same GitHub issuer, the two
# states will collide with EntityAlreadyExists. Moving both to a shared
# bootstrap state is the fix; until then, this is the owner.
#
# Why a new identity rather than an existing CI credential: nothing in the
# account grants Cost Explorer access today, and OIDC issues short-lived
# credentials scoped to exactly the two read actions below, so there is no key
# to store or rotate and nothing existing gets widened.

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates this endpoint against its own trusted CA library rather than
  # the thumbprint, so these values are required by the API but not used for
  # verification, and a rotated GitHub certificate does not break the provider.
  # Both historical GitHub thumbprints are listed for completeness.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = {
    Name = "github_actions"
  }

  # One provider per issuer URL per account, shared by every role that ever
  # trusts GitHub, so destroying it breaks them all at once. Deleting it on
  # purpose means removing this block first.
  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_policy_document" "cost_report_reader_assume_role" {
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

    # Restricts the role to the workspace repo's default branch. Without a sub
    # condition, any GitHub repository on the internet could assume this role.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.cost_report_github_subjects
    }
  }
}

data "aws_iam_policy_document" "cost_report_reader" {
  # Cost Explorer does not support resource-level permissions, so "*" is the
  # only valid resource for these actions. The role stays read-only: a cost
  # reporting identity has no reason to hold a single write permission.
  statement {
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:ListCostAllocationTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "cost_report_reader" {
  name               = "github_actions_cost_report_reader"
  description        = "Read-only Cost Explorer access for the monthly cost report workflow"
  assume_role_policy = data.aws_iam_policy_document.cost_report_reader_assume_role.json

  tags = {
    Name = "github_actions_cost_report_reader"
  }
}

resource "aws_iam_role_policy" "cost_report_reader" {
  name   = "cost_report_read_only"
  role   = aws_iam_role.cost_report_reader.id
  policy = data.aws_iam_policy_document.cost_report_reader.json
}

output "cost_report_reader_role_arn" {
  description = "Set as the AWS_COST_REPORT_ROLE_ARN secret in the repo running the cost report workflow"
  value       = aws_iam_role.cost_report_reader.arn
}
