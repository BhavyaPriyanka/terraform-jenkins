module "jenkins_master" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "jenkins-tf"

  instance_type          = var.jenkins_instance_type
  ami                    = data.aws_ami.ami_info.id
  subnet_id              = local.public_subnet_id
  vpc_security_group_ids = [aws_security_group.devops_tools.id]
  key_name               = data.aws_key_pair.tools.key_name

  user_data = file("jenkins.sh")

  root_block_device = {
  size                  = 30
  type                  = "gp3"
  delete_on_termination = true
}

  tags = merge(
    local.common_tags,
    {
      Name = "${local.resource_name}-jenkins-master"
    }
  )
}


module "jenkins_agent" {
  source  = "terraform-aws-modules/ec2-instance/aws"

  name = "jenkins-agent"

  instance_type          = var.jenkins_agent_instance_type
  vpc_security_group_ids = [aws_security_group.devops_tools.id]
 
  subnet_id = local.public_subnet_id
  ami = data.aws_ami.ami_info.id
  key_name               = data.aws_key_pair.tools.key_name

  iam_instance_profile = aws_iam_instance_profile.jenkins_agent.name

  user_data = file("jenkins-agent.sh")

   root_block_device = {
  size                  = 30
  type                  = "gp3"
  delete_on_termination = true
}

  tags = merge(

    local.common_tags,

    {
      Name = "${local.resource_name}-jenkins-agent"
    }

  )
}

resource "aws_instance" "nexus" {
  ami           = data.aws_ami.ami_info.id
  instance_type = var.nexus_instance_type
  vpc_security_group_ids = [aws_security_group.devops_tools.id]
  subnet_id = local.public_subnet_id
  key_name               = data.aws_key_pair.tools.key_name

  associate_public_ip_address = true


  user_data = file("install-nexus.sh")

    root_block_device {
    volume_size = 30
    volume_type = "gp3"
      delete_on_termination = true
  }


  tags = merge(

    local.common_tags,

    {
      Name = "${local.resource_name}-nexus"
    }

  )
}

resource "aws_instance" "sonarqube" {
  ami           = data.aws_ami.ami_info.id
  instance_type = "m7i-flex.large"

  subnet_id              = local.public_subnet_id
  vpc_security_group_ids = [aws_security_group.devops_tools.id]
  key_name = data.aws_key_pair.tools.key_name

  associate_public_ip_address = true

  user_data = file("install-sonarqube.sh")

  root_block_device {
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = merge(

    local.common_tags,

    {
      Name = "${local.resource_name}-sonarqube"
    }

  )
}

module "records" {
  source  = "terraform-aws-modules/route53/aws//modules/records"
  version = "~> 2.0"

  zone_name = var.zone_name

  records = [
    {
      name    = "jenkins-master"
      type    = "A"
      ttl     = 1
      records = [
        module.jenkins_master.public_ip
      ]
      allow_overwrite = true
    },
    {
      name    = "jenkins-agent"
      type    = "A"
      ttl     = 1
      records = [
        module.jenkins_agent.private_ip
      ]
      allow_overwrite = true
    },
    {
      name    = "nexus"
      type    = "A"
      ttl     = 1
      records = [
        aws_instance.nexus.public_ip
      ]
      allow_overwrite = true
    },
    {
      name    = "sonar"
      type    = "A"
      ttl     = 1
      records = [
        aws_instance.sonarqube.public_ip
      ]
      allow_overwrite = true
    }
  ]
}



resource "aws_ebs_volume" "jenkins_home" {
  availability_zone =  data.aws_subnet.public.availability_zone

  size = 20
  type = "gp3"

    tags = merge(
    local.common_tags,
    {
      Name = "${local.resource_name}-jenkins-home"
    }
  )
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name = "/dev/sdf"

  volume_id   = aws_ebs_volume.jenkins_home.id
  instance_id = module.jenkins_master.id

  force_detach = true
}



resource "aws_iam_role" "jenkins_agent" {
  name = "${local.resource_name}-jenkins-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Principal = {
          Service = "ec2.amazonaws.com"
        }

        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "admin" {

  role       = aws_iam_role.jenkins_agent.name

  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"

}

resource "aws_iam_instance_profile" "jenkins_agent" {

  name = "${local.resource_name}-jenkins-agent-profile"

  role = aws_iam_role.jenkins_agent.name

}

resource "aws_security_group" "devops_tools" {

  name        = "${local.resource_name}-tools-sg"
  description = "Security Group for Jenkins, Nexus and SonarQube"
  vpc_id      = data.aws_ssm_parameter.vpc_id.value

  ingress {
    description = "SSH"

    from_port   = 22
    to_port     = 22
    protocol    = "tcp"

    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "Jenkins"

    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"

    cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "Nexus"

    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"

     cidr_blocks = var.allowed_cidrs
  }

  ingress {
    description = "SonarQube"

    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"

     cidr_blocks = var.allowed_cidrs
  }

   egress {

    from_port = 0

    to_port = 0

    protocol = "-1"

    cidr_blocks = var.egress_cidrs

  }

  tags = merge(
    local.common_tags,
    {
      Name = "${local.resource_name}-tools-sg"
    }
  )
}