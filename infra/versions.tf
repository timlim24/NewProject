terraform {
  required_version = ">= 1.10"

  cloud {
    organization = "ooad-timlim"

    workspaces {
      name = "new-project-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_lambda_function" "backend" {
  function_name = "${var.project_name}-backend"
}

data "aws_vpc" "backend" {
  tags = {
    PROJECT_NAME = var.project_name
  }
}

data "aws_subnets" "backend_private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backend.id]
  }
}

data "aws_security_group" "backend_function" {
  filter {
    name   = "group-name"
    values = ["${var.project_name}-backend-FunctionSecurityGroup*"]
  }
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backend.id]
  }
}

data "aws_route_table" "main" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.backend.id]
  }
  filter {
    name   = "association.main"
    values = ["true"]
  }
}

locals {
  image_uri         = data.aws_lambda_function.backend.image_uri
  database_url      = data.aws_lambda_function.backend.environment[0].variables["DATABASE_URL"]
  vpc_id            = data.aws_vpc.backend.id
  subnet_ids        = data.aws_subnets.backend_private.ids
  security_group_id = data.aws_security_group.backend_function.id
  route_table_id    = data.aws_route_table.main.id
}
