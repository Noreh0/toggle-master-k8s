resource "aws_iam_user" "ci" {
  name = "${var.project_name}-ci"

  tags = {
    Purpose = "Usado pelo GitHub Actions para dar push de imagens no ECR"
  }
}

# Policy com o mínimo necessário para o Actions autenticar e dar push no ECR.
# Nada de permissão de leitura/escrita em outros serviços da AWS.
data "aws_iam_policy_document" "ecr_push" {
  # GetAuthorizationToken exige resource "*" — é uma limitação da própria AWS,
  # não dá pra restringir por repositório.
  statement {
    sid       = "ECRAuth"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Essas ações já ficam restritas só aos 5 repositórios do ToggleMaster.
  statement {
    sid = "ECRPushToToggleMasterRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_policy" "ecr_push" {
  name        = "${var.project_name}-ci-ecr-push"
  description = "Permite ao GitHub Actions dar push apenas nos repositórios ECR do ToggleMaster"
  policy      = data.aws_iam_policy_document.ecr_push.json
}

resource "aws_iam_user_policy_attachment" "ci_ecr_push" {
  user       = aws_iam_user.ci.name
  policy_arn = aws_iam_policy.ecr_push.arn
}

# Propositalmente NÃO criamos a access key aqui (aws_iam_access_key).
# Se fizéssemos, o Secret Access Key ficaria salvo em texto no terraform.tfstate.
# Gere a chave manualmente uma vez via CLI (ver README/RUNBOOK) e cole
# direto nos Secrets do GitHub — sem passar pelo Terraform.
