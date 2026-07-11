resource "aws_ssm_parameter" "jenkins_private_key" {
  name  = "/jenkins/private_key"
  type  = "SecureString"
  value = tls_private_key.jenkins.private_key_pem
}



