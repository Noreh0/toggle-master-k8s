resource "aws_ecr_repository" "this" {
  for_each = toset(var.microservices)

  name                 = "${var.project_name}-${each.value}"
  image_tag_mutability = "IMMUTABLE" # cada commit gera uma tag única, não sobrescreve

  image_scanning_configuration {
    scan_on_push = true # scan automático da AWS a cada push, complementa o Trivy do CI
  }

  tags = {
    Name = "${var.project_name}-${each.value}"
  }
}
