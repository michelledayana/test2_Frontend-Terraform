output "frontend_url" {
  description = "Public URL of the Frontend Load Balancer"
  value       = "http://${aws_lb.frontend_alb.dns_name}"
}

output "frontend_alb_dns" {
  description = "DNS name of the Frontend ALB"
  value       = aws_lb.frontend_alb.dns_name
}

output "frontend_asg_name" {
  description = "Frontend Auto Scaling Group name"
  value       = aws_autoscaling_group.frontend_asg.name
}
