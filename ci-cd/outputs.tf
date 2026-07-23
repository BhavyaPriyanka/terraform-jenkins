output "jenkins_master_public_ip"{
    value = module.jenkins_master.public_ip
}

output "jenkins_agent_private_ip" {
  value = module.jenkins_agent.private_ip
}

output "nexus_public_ip" {
  value = aws_instance.nexus.public_ip
}

output "sonarqube_public_ip" {
  value = aws_instance.sonarqube.public_ip
}

output "tools_security_group_id" {
  value = aws_security_group.devops_tools.id
}

output "jenkins_key_name" {
  value = data.aws_key_pair.tools.key_name
}

output "jenkins_master_instance_id" {
  value = module.jenkins_master.id
}

output "jenkins_agent_instance_id" {
  value = module.jenkins_agent.id
}

output "nexus_instance_id" {
  value = aws_instance.nexus.id
}

output "sonarqube_instance_id" {
  value = aws_instance.sonarqube.id
}

output "jenkins_home_volume_id" {
  value = aws_ebs_volume.jenkins_home.id
}

output "tools_security_group_name" {
  value = aws_security_group.devops_tools.name
}

output "jenkins_url" {
  value = "http://jenkins-master.${var.zone_name}:8080"
}

output "nexus_url" {
  value = "http://nexus.${var.zone_name}:8081"
}

output "sonarqube_url" {
  value = "http://sonar.${var.zone_name}:9000"
}