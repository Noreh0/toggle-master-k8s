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

# ---------- Auto-reparo (workflow self-heal.yaml) ----------
# O mesmo usuário de CI roda `kubectl rollout restart` quando o alerta do Grafana dispara.
# Duas peças: (1) IAM: só consegue descrever o cluster para montar o kubeconfig;
# (2) EKS access entry: dentro do cluster, só edita recursos do namespace da aplicação
# (política gerenciada AmazonEKSEditPolicy com escopo no namespace; sem acesso a outros namespaces).
data "aws_iam_policy_document" "eks_describe" {
  statement {
    sid       = "DescribeClusterForKubeconfig"
    actions   = ["eks:DescribeCluster"]
    resources = [var.cluster_arn]
  }
}

resource "aws_iam_policy" "eks_describe" {
  name        = "${var.project_name}-ci-eks-describe"
  description = "Permite ao usuário de CI gerar o kubeconfig do cluster (auto-reparo)"
  policy      = data.aws_iam_policy_document.eks_describe.json
}

resource "aws_iam_user_policy_attachment" "ci_eks_describe" {
  user       = aws_iam_user.ci.name
  policy_arn = aws_iam_policy.eks_describe.arn
}

resource "aws_eks_access_entry" "ci" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_user.ci.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "ci_edit_app_namespace" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_user.ci.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = [var.app_namespace]
  }

  depends_on = [aws_eks_access_entry.ci]
}
