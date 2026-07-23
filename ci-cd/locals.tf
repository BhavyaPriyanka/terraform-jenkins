locals {

  resource_name = "${var.project_name}-${var.environment}"

  public_subnet_id = split(
    ",",
    data.aws_ssm_parameter.public_subnet_ids.value
  )[0]

  common_tags = merge(
    var.common_tags,
    {
      Project     = var.project_name
      Environment = var.environment
      Component   = "tools"
    }
  )

}