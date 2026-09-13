resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Permite acesso Postgres apenas de dentro da VPC (ex: nodes do EKS)"
  vpc_id      = var.vpc_id

  ingress {
    description = "Postgres a partir da VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-rds-sg"
  }
}

resource "aws_db_instance" "this" {
  for_each = toset(var.db_instances)

  identifier             = "${var.project_name}-${each.value}"
  engine                 = "postgres"
  engine_version         = "16" # major version apenas: a AWS escolhe a minor mais recente disponível
  allow_major_version_upgrade = false
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  db_name                = replace(each.value, "-", "_")
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  skip_final_snapshot    = true
  publicly_accessible    = false

  tags = {
    Name = "${var.project_name}-${each.value}"
  }
}
