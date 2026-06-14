output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the two public subnets (ALB + ECS tasks)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the two private subnets (Aurora DB subnet group)."
  value       = aws_subnet.private[*].id
}

output "alb_sg_id" {
  description = "ID of the ALB security group."
  value       = aws_security_group.alb.id
}

output "ecs_service_sg_id" {
  description = "ID of the ECS service security group."
  value       = aws_security_group.ecs_service.id
}

output "db_sg_id" {
  description = "ID of the Aurora security group."
  value       = aws_security_group.db.id
}
