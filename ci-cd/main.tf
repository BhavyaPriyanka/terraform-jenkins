module "jenkins_master" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "jenkins-tf"

  instance_type          = "t3.small"
  ami                    = data.aws_ami.ami_info.id
  subnet_id              = "subnet-07fa85a74ee034939"
  vpc_security_group_ids = ["sg-0ad31bf3450f94454"]
  key_name               = aws_key_pair.jenkins_key.key_name

  user_data = file("jenkins.sh")

  root_block_device = {
  size                  = 30
  type                  = "gp3"
  delete_on_termination = true
}

  tags = {
    Name = "jenkins-master"
  }
}

resource "aws_ebs_volume" "jenkins_home" {
  availability_zone = data.aws_subnet.jenkins_subnet.availability_zone

  size = 20
  type = "gp3"

  tags = {
    Name = "jenkins-home"
  }
}

resource "aws_volume_attachment" "jenkins_home" {
  device_name = "/dev/sdf"

  volume_id   = aws_ebs_volume.jenkins_home.id
  instance_id = module.jenkins_master.id

  force_detach = true
}


resource "aws_key_pair" "jenkins_key" {
  key_name   = "jenkins-key"
  public_key = tls_private_key.jenkins.public_key_openssh
}

resource "tls_private_key" "jenkins" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

module "jenkins_agent" {
  source  = "terraform-aws-modules/ec2-instance/aws"

  name = "jenkins-agent"

  instance_type          = "t3.small"
  vpc_security_group_ids = ["sg-0ad31bf3450f94454"]
  # convert StringList to list and get first element
  subnet_id = "subnet-07fa85a74ee034939"
  ami = data.aws_ami.ami_info.id
  key_name               = aws_key_pair.jenkins_key.key_name

  iam_instance_profile = aws_iam_instance_profile.jenkins_agent.name

  user_data = file("jenkins-agent.sh")

   root_block_device = {
  size                  = 30
  type                  = "gp3"
  delete_on_termination = true
}

  tags = {
    Name = "jenkins-agent"
  }
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
    }
  ]
}

resource "aws_instance" "nexus" {
  ami           = data.aws_ami.ami_info.id
  instance_type = "t3.small"
  vpc_security_group_ids = ["sg-0ad31bf3450f94454"]
  subnet_id = "subnet-07fa85a74ee034939"
  key_name               = aws_key_pair.jenkins_key.key_name

  associate_public_ip_address = true


  user_data = file("install-nexus.sh")

    root_block_device {
    volume_size = 30
    volume_type = "gp3"
      delete_on_termination = true
  }


  tags = {
    Name = "nexus-server"
  }
}

resource "aws_iam_role" "jenkins_agent" {
  name = "jenkins-agent-role"

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

  name = "jenkins-agent-profile"

  role = aws_iam_role.jenkins_agent.name

}