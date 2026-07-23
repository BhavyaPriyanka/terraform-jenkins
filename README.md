# LocalHelp DevOps Tools Infrastructure

Terraform code to create DevOps tools infrastructure for LocalHelp project.

## Tools

- Jenkins Master
- Jenkins Agent
- Nexus Repository
- SonarQube


## Infrastructure

Created using Terraform:

- EC2 Instances
- Security Group
- IAM Role
- EBS Volume
- Route53 Records


## Ports

| Tool | Port |
|------|------|
| Jenkins | 8080 |
| Nexus | 8081 |
| SonarQube | 9000 |


## Prerequisites

- Terraform
- AWS CLI


## Terraform Commands

```bash
terraform init

terraform validate

terraform plan

terraform apply
