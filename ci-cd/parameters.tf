resource "aws_ssm_parameter" "tools_sg_id" {
  name  = "/${var.project_name}/${var.environment}/tools_sg_id"
  type  = "String"
  value = aws_security_group.devops_tools.id
}


resource "aws_ssm_parameter" "jenkins_agent_sg_id" {
  name        = "/${local.resource_name}/jenkins_agent_sg_id"
  description = "Security group ID for Jenkins agent"
  type        = "String"
  value       = aws_security_group.devops_tools.id

  tags = local.common_tags
}