locals {
  name_prefix = "${var.project_name}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, 2)

  derived_frontend_origins = compact([
    var.app_domain_name != "" ? "https://${var.app_domain_name}" : "",
    var.app_domain_name != "" ? "http://${var.app_domain_name}" : ""
  ])

  frontend_origins = length(var.frontend_allowed_origins) > 0 ? var.frontend_allowed_origins : local.derived_frontend_origins

  cors_allowed_origins = join(
    ",",
    distinct(
      compact(
        local.frontend_origins
      )
    )
  )

  ecr_registry = split("/", aws_ecr_repository.backend.repository_url)[0]

  compose_content = templatefile("${path.module}/templates/docker-compose.aws.yml.tftpl", {
    backend_image           = "${aws_ecr_repository.backend.repository_url}:latest"
    frontend_image          = "${aws_ecr_repository.frontend.repository_url}:latest"
    aws_region              = var.aws_region
    log_group_name          = aws_cloudwatch_log_group.application.name
    backend_container_port  = var.backend_container_port
    frontend_container_port = var.frontend_container_port
    backend_health_path     = var.backend_health_path
  })
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_ssm_parameter" "amazon_linux_2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "instance_runtime" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.database.arn, aws_secretsmanager_secret.application.arn]
  }

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.application.arn}:*"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

resource "aws_subnet" "public" {
  count = length(var.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # Private subnets explicitly have no route to the Internet Gateway or NAT Gateway

  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app-sg"
  description = "Application instance accessible publicly"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = var.frontend_container_port
    to_port     = var.frontend_container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = var.backend_container_port
    to_port     = var.backend_container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow SSH if needed
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-app-sg"
  }
}

resource "aws_security_group" "db" {
  name        = "${local.name_prefix}-db-sg"
  description = "Database access from the application instances."
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-db-sg"
  }
}

resource "aws_cloudwatch_log_group" "application" {
  name              = "/${local.name_prefix}/application"
  retention_in_days = var.log_group_retention_days
}

resource "random_password" "db_password" {
  length  = 24
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnets"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnets"
  }
}

resource "aws_db_instance" "mysql" {
  identifier                 = "${local.name_prefix}-mysql"
  engine                     = "mysql"
  engine_version             = var.rds_engine_version
  instance_class             = var.db_instance_class
  allocated_storage          = var.db_allocated_storage
  db_name                    = var.db_name
  username                   = var.db_username
  password                   = random_password.db_password.result
  db_subnet_group_name       = aws_db_subnet_group.main.name
  vpc_security_group_ids     = [aws_security_group.db.id]
  multi_az                   = false # Disabled for AWS Free Tier
  publicly_accessible        = false
  storage_encrypted          = true
  backup_retention_period    = 0
  skip_final_snapshot        = true
  deletion_protection        = false
  apply_immediately          = true
  auto_minor_version_upgrade = true
  parameter_group_name       = "default.mysql8.0"
}

resource "aws_secretsmanager_secret" "database" {
  name                    = "/${local.name_prefix}/database"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "database" {
  secret_id = aws_secretsmanager_secret.database.id
  secret_string = jsonencode({
    SPRING_DATASOURCE_URL      = "jdbc:mysql://${aws_db_instance.mysql.address}:3306/${var.db_name}?useSSL=true&requireSSL=true&serverTimezone=UTC"
    SPRING_DATASOURCE_USERNAME = var.db_username
    SPRING_DATASOURCE_PASSWORD = random_password.db_password.result
  })
}

resource "aws_secretsmanager_secret" "application" {
  name                    = "/${local.name_prefix}/application"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "application" {
  secret_id = aws_secretsmanager_secret.application.id
  secret_string = jsonencode({
    JWT_SECRET                   = random_password.jwt_secret.result
    JWT_ACCESS_TOKEN_EXPIRATION  = tostring(var.jwt_access_token_expiration)
    JWT_REFRESH_TOKEN_EXPIRATION = tostring(var.jwt_refresh_token_expiration)
    SPRING_MAIL_HOST             = var.mail_host
    SPRING_MAIL_PORT             = tostring(var.mail_port)
    SPRING_MAIL_USERNAME         = var.mail_username
    SPRING_MAIL_PASSWORD         = var.mail_password
    AI_OPENAI_API_KEY            = var.ai_openai_api_key
  })
}

resource "aws_ecr_repository" "backend" {
  name                 = "${local.name_prefix}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${local.name_prefix}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged backend images after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged frontend images after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "aws_iam_role" "app" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr" {
  role       = aws_iam_role.app.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy" "runtime" {
  name   = "${local.name_prefix}-runtime"
  role   = aws_iam_role.app.id
  policy = data.aws_iam_policy_document.instance_runtime.json
}

resource "aws_iam_instance_profile" "app" {
  name = "${local.name_prefix}-instance-profile"
  role = aws_iam_role.app.name
}

# Single EC2 instance replaces ALB + ASG
resource "aws_instance" "app" {
  ami                  = data.aws_ssm_parameter.amazon_linux_2023_ami.value
  instance_type        = var.instance_type
  subnet_id            = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile = aws_iam_instance_profile.app.name
  key_name             = var.ssh_key_name != "" ? var.ssh_key_name : null

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    aws_region              = var.aws_region
    ecr_registry            = local.ecr_registry
    database_secret_name    = aws_secretsmanager_secret.database.name
    application_secret_name = aws_secretsmanager_secret.application.name
    cors_allowed_origins    = local.cors_allowed_origins
    compose_content         = local.compose_content
    log_group_name          = aws_cloudwatch_log_group.application.name
  }))

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name = "${local.name_prefix}-app"
  }
}

resource "aws_s3_bucket" "frontend" {
  bucket = "${local.name_prefix}-frontend"
  force_destroy = true
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  index_document {
    suffix = "index.html"
  }
  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "frontend_public" {
  bucket = aws_s3_bucket.frontend.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.frontend.arn}/*"
      },
    ]
  })
}

output "instance_public_dns" {
  value       = aws_instance.app.public_dns
  description = "Public DNS name for the single application instance."
}

output "instance_public_ip" {
  value       = aws_instance.app.public_ip
  description = "Public IP for the single application instance."
}

output "frontend_url" {
  value       = "http://${aws_instance.app.public_ip}"
  description = "Primary URL for the Angular frontend."
}

output "backend_health_url" {
  value       = "http://${aws_instance.app.public_ip}${var.backend_health_path}"
  description = "Backend readiness URL exposed."
}

output "rds_endpoint" {
  value       = aws_db_instance.mysql.address
  description = "RDS endpoint used by the backend."
}

output "backend_ecr_repository_url" {
  value       = aws_ecr_repository.backend.repository_url
  description = "Backend ECR repository URL."
}

output "frontend_ecr_repository_url" {
  value       = aws_ecr_repository.frontend.repository_url
  description = "Frontend ECR repository URL."
}

output "database_secret_name" {
  value       = aws_secretsmanager_secret.database.name
  description = "Secrets Manager entry containing database connection values."
}

output "application_secret_name" {
  value       = aws_secretsmanager_secret.application.name
  description = "Secrets Manager entry containing JWT, SMTP, and AI values."
}

output "s3_website_endpoint" {
  value       = aws_s3_bucket_website_configuration.frontend.website_endpoint
  description = "The S3 website endpoint for the Angular frontend."
}
