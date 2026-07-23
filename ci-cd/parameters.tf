

resource "aws_ssm_parameter" "tools_sg_id" {
  name  = "/${var.project_name}/${var.environment}/tools_sg_id"
  type  = "String"
  value =  aws_security_group.devops_tools.id
}



