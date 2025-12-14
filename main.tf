provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "Distributed-Exam"
      Owner   = "Heredia"
      Service = "Frontend"
    }
  }
}

# ================================
# 1. DATA
# ================================
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ================================
# 2. EXISTING SECURITY GROUP
# ================================
data "aws_security_group" "web_sg" {
  filter {
    name   = "group-name"
    values = ["frontend-sg"]
  }
  vpc_id = data.aws_vpc.default.id
}

# ================================
# 3. EXISTING LOAD BALANCER
# ================================
data "aws_lb" "frontend_alb" {
  name = "frontend-alb"
}

data "aws_lb_target_group" "frontend_tg" {
  name = "frontend-tg"
}

# ================================
# 4. LAUNCH TEMPLATE
# ================================
resource "aws_launch_template" "frontend_lt" {
  name_prefix   = "frontend-lt-"
  image_id      = "ami-0c02fb55956c7d316"
  instance_type = "t2.micro"
  key_name      = "frontend-key"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [data.aws_security_group.web_sg.id]
  }

  user_data = base64encode(<<EOF
#!/bin/bash
yum update -y

amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

docker pull dayanaheredia/frontend-hello-world:latest
docker run -d --restart always -p 3001:80 dayanaheredia/frontend-hello-world:latest
EOF
  )
}

# ================================
# 5. EXISTING AUTO SCALING GROUP
# ================================
data "aws_autoscaling_group" "frontend_asg" {
  name = "frontend-asg"
}

# Update the ASG with the new Launch Template
resource "aws_autoscaling_group" "frontend_asg_update" {
  name                = data.aws_autoscaling_group.frontend_asg.name
  min_size            = data.aws_autoscaling_group.frontend_asg.min_size
  max_size            = data.aws_autoscaling_group.frontend_asg.max_size
  desired_capacity    = data.aws_autoscaling_group.frontend_asg.desired_capacity
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [data.aws_lb_target_group.frontend_tg.arn]

  launch_template {
    id      = aws_launch_template.frontend_lt.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "frontend-instance"
    propagate_at_launch = true
  }
}

# ================================
# 6. SCALING POLICIES
# ================================
resource "aws_autoscaling_policy" "cpu_policy" {
  name                   = "frontend-scale-cpu"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg_update.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

resource "aws_autoscaling_policy" "network_policy" {
  name                   = "frontend-scale-network"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg_update.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn"
    }
    target_value = 1000000
  }
}

resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "frontend-scale-memory"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg_update.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "mem_used_percent"
      namespace   = "CWAgent"
      statistic   = "Average"
      unit        = "Percent"

      metric_dimension {
        name  = "AutoScalingGroupName"
        value = aws_autoscaling_group.frontend_asg_update.name
      }
    }
    target_value = 60
  }
}
