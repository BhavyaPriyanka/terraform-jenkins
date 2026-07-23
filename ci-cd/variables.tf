variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project Name"
  type        = string
}

variable "environment" {
  description = "Environment"
  type        = string
}

variable "zone_name" {
  description = "Route53 Hosted Zone"
  type        = string
}

variable "jenkins_instance_type" {
  description = "Jenkins Master Instance Type"
  type        = string
  default     = "t3.small"
}

variable "jenkins_agent_instance_type" {
  description = "Jenkins Agent Instance Type"
  type        = string
  default     = "t3.small"
}

variable "nexus_instance_type" {
  description = "Nexus Instance Type"
  type        = string
  default     = "t3.small"
}

variable "sonarqube_instance_type" {
  description = "SonarQube Instance Type"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root Volume Size"
  type        = number
  default     = 40
}

variable "allowed_cidrs" {

  description = "Allowed Networks"

  type = list(string)

  default = [
    "0.0.0.0/0"
  ]
}

variable "egress_cidrs" {
  type = list(string)

  default = [
    "0.0.0.0/0"
  ]
}

variable "common_tags" {

  description = "Common Tags"

  type = map(string)

  default = {

    Terraform = "true"
    ManagedBy = "Terraform"

  }

}

variable "key_pair_name" {
  description = "Existing EC2 Key Pair Name"
  type        = string
}