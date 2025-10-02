#
# AWS Infrastructure Definition using Terraform
# Provisions all necessary resources for the three-tier application.
#
# This configuration includes:
# 1. An S3 backend for remote state storage (Recommended for production).
# 2. VPC, Subnets, NAT Gateways for robust networking.
# 3. An EKS Cluster for Kubernetes orchestration.
# 4. Two ECR Repositories for Docker image storage.
# 5. An RDS PostgreSQL instance for the Data Tier.
#

# -----------------------------------------------------------------------------
# 1. AWS Provider Configuration
# -----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # NOTE: In a real-world setup, uncomment and configure the S3 backend
  # for storing Terraform state remotely and enabling collaboration.
  /*
  backend "s3" {
    bucket         = "my-app-terraform-state-bucket-12345" # MUST be globally unique
    key            = "dev/three-tier-app/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
  }
  */
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# 2. Variables
# -----------------------------------------------------------------------------
variable "project_name" {
  description = "A unique name for the project to use in tags and resource names."
  type        = string
  default     = "three-tier-app"
}

variable "aws_region" {
  description = "The AWS region to deploy resources into."
  type        = string
  default     = "us-east-1"
}

variable "db_password" {
  description = "The master password for the RDS database (sensitive)."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# 3. VPC and Networking (Step 1.1)
# Using the community VPC module for best practices on subnets and routing
# -----------------------------------------------------------------------------
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "${var.project_name}-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["${var.aws_region}a", "${var.aws_region}b", "${var.aws_region}c"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

# -----------------------------------------------------------------------------
# 4. EKS Cluster (Step 1.2)
# Using the community EKS module for simplified cluster setup
# -----------------------------------------------------------------------------
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.16.0"

  cluster_name    = "${var.project_name}-cluster"
  cluster_version = "1.28"
  vpc_id          = module.vpc.vpc_id
  subnet_ids      = module.vpc.private_subnets

  # EKS Managed Node Group
  eks_managed_node_groups = {
    default = {
      min_size     = 1
      max_size     = 3
      desired_size = 2

      instance_types = ["t3.medium"]
      # Use private subnets for the EKS workers
      subnet_ids = module.vpc.private_subnets
    }
  }

  tags = {
    Name = "${var.project_name}-eks"
  }
}

# -----------------------------------------------------------------------------
# 5. Elastic Container Registry (ECR) (Step 1.3)
# Repositories for the two application tiers
# -----------------------------------------------------------------------------
resource "aws_ecr_repository" "frontend_repo" {
  name                 = "${var.project_name}-frontend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend_repo" {
  name                 = "${var.project_name}-backend"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# -----------------------------------------------------------------------------
# 6. RDS Database (Data Tier) (Step 1.4)
# Provision a PostgreSQL instance in the private subnets
# -----------------------------------------------------------------------------
resource "aws_db_instance" "app_db" {
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "15.4"
  instance_class       = "db.t3.micro"
  identifier           = "${var.project_name}-db"
  username             = "admin"
  password             = var.db_password
  db_name              = "appdb"
  publicly_accessible  = false
  skip_final_snapshot  = true

  # Deploy RDS into the private subnets of the new VPC
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
}

resource "aws_db_subnet_group" "db_subnet_group" {
  name       = "${var.project_name}-db-sg"
  subnet_ids = module.vpc.private_subnets
  tags = {
    Name = "${var.project_name}-db-subnet-group"
  }
}

# Security Group to allow traffic from EKS worker nodes to RDS
resource "aws_security_group" "db_sg" {
  name        = "${var.project_name}-db-sg"
  description = "Allow EKS worker nodes to connect to RDS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "Allow traffic from EKS worker security group"
    from_port       = 5432 # PostgreSQL port
    to_port         = 5432
    protocol        = "tcp"
    # Assuming EKS worker nodes share the cluster's primary security group
    security_groups = [module.eks.cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -----------------------------------------------------------------------------
# 7. Outputs
# Essential information needed for CI/CD and application configuration
# -----------------------------------------------------------------------------
output "kubeconfig" {
  description = "The Kubernetes configuration needed to connect to the cluster."
  value       = module.eks.kubeconfig
  sensitive   = true
}

output "rds_endpoint" {
  description = "The connection endpoint for the RDS database."
  value       = aws_db_instance.app_db.address
}

output "frontend_ecr_uri" {
  description = "URI for the Frontend ECR Repository."
  value       = aws_ecr_repository.frontend_repo.repository_url
}

output "backend_ecr_uri" {
  description = "URI for the Backend ECR Repository."
  value       = aws_ecr_repository.backend_repo.repository_url
}
