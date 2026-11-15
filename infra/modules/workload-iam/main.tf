# Permissões AWS dos pods via EKS Pod Identity (sem access key e sem provider OIDC).
# Cada ServiceAccount é associada a um role com o mínimo necessário.
#
# Requisitos:
#   - add-on eks-pod-identity-agent no cluster (modules/eks)
#   - ServiceAccounts com os nomes abaixo, criadas nos manifests do GitOps
#   - SDKs com suporte a Pod Identity: aws-sdk-go >= 1.47.11 (evaluation)
#     e boto3 >= 1.34.41 (analytics)

locals {
  evaluation_sa = "evaluation-service"
  analytics_sa  = "analytics-service"
}

data "aws_iam_policy_document" "pods_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# ---------- evaluation-service: só publica eventos no SQS ----------
resource "aws_iam_role" "evaluation" {
  name               = "${var.project_name}-evaluation-pod"
  assume_role_policy = data.aws_iam_policy_document.pods_trust.json
}

data "aws_iam_policy_document" "evaluation" {
  statement {
    sid       = "PublishEvaluationEvents"
    actions   = ["sqs:SendMessage"]
    resources = [var.queue_arn]
  }
}

resource "aws_iam_role_policy" "evaluation" {
  name   = "sqs-send"
  role   = aws_iam_role.evaluation.id
  policy = data.aws_iam_policy_document.evaluation.json
}

resource "aws_eks_pod_identity_association" "evaluation" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.evaluation_sa
  role_arn        = aws_iam_role.evaluation.arn
}

# ---------- analytics-service: consome o SQS e grava no DynamoDB ----------
resource "aws_iam_role" "analytics" {
  name               = "${var.project_name}-analytics-pod"
  assume_role_policy = data.aws_iam_policy_document.pods_trust.json
}

data "aws_iam_policy_document" "analytics" {
  statement {
    sid = "ConsumeEvaluationEvents"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [var.queue_arn]
  }

  statement {
    sid       = "WriteAnalyticsEvents"
    actions   = ["dynamodb:PutItem"]
    resources = [var.table_arn]
  }
}

resource "aws_iam_role_policy" "analytics" {
  name   = "sqs-consume-dynamodb-write"
  role   = aws_iam_role.analytics.id
  policy = data.aws_iam_policy_document.analytics.json
}

resource "aws_eks_pod_identity_association" "analytics" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.analytics_sa
  role_arn        = aws_iam_role.analytics.arn
}
