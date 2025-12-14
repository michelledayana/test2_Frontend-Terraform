provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project = "Distributed-Exam"
      Owner   = "Heredia"
    }
  }
}

# ================================
# 1. DATA (VPC y Subredes)
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
# 2. SECURITY GROUP
# ================================
resource "aws_security_group" "web_sg" {
  name_prefix = "frontend-sg-"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Owner   = "Heredia"
    Project = "Distributed-Exam"
  }
}

# ================================
# 3. LOAD BALANCER
# ================================
resource "aws_lb" "frontend_alb" {
  name_prefix        = "frontend-alb-"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.web_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "frontend_tg" {
  name_prefix = "frontend-tg-"
  port        = 3001
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id

  health_check {
    path                = "/"
    port                = "3001"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener" "frontend_listener" {
  load_balancer_arn = aws_lb.frontend_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
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
    security_groups             = [aws_security_group.web_sg.id]
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
# 5. AUTO SCALING GROUP
# ================================
resource "aws_autoscaling_group" "frontend_asg" {
  name_prefix          = "frontend-asg-"
  min_size             = 2
  max_size             = 3
  desired_capacity     = 2
  vpc_zone_identifier  = data.aws_subnets.default.ids
  target_group_arns    = [aws_lb_target_group.frontend_tg.arn]

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
  name                   = "scale-by-cpu"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

resource "aws_autoscaling_policy" "network_policy" {
  name                   = "scale-by-network"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn"
    }
    target_value = 1000000
  }
}

resource "aws_autoscaling_policy" "memory_policy" {
  name                   = "scale-by-memory"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    customized_metric_specification {
      metric_name = "mem_used_percent"
      namespace   = "CWAgent"
      statistic   = "Average"
      unit        = "Percent"

      metric_dimension {
        name  = "AutoScalingGroupName"
        value = aws_autoscaling_group.frontend_asg.name
      }
    }
    target_value = 60
  }
}
