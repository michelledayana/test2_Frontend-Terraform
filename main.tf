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
# 1. DATA (VPC y Subnets)
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
resource "aws_security_group" "frontend_sg" {
  name   = "frontend-sg"
  vpc_id = data.aws_vpc.default.id

  # ALB → Frontend
  ingress {
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
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
}

# ================================
# 3. LOAD BALANCER
# ================================
resource "aws_lb" "frontend_alb" {
  name               = "frontend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.frontend_sg.id]
  subnets            = data.aws_subnets.default.ids
}

resource "aws_lb_target_group" "frontend_tg" {
  name     = "frontend-tg"
  port     = 3001
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path    = "/"
    matcher = "200"
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
  image_id      = "ami-0c02fb55956c7d316" # Amazon Linux 2
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.frontend_sg.id]
  }

  user_data = base64encode(<<EOF
#!/bin/bash
yum update -y

# Docker
amazon-linux-extras install docker -y
systemctl enable docker
systemctl start docker
usermod -aG docker ec2-user

# CloudWatch Agent (MEMORIA)
yum install -y amazon-cloudwatch-agent

cat <<CWCONFIG > /opt/aws/amazon-cloudwatch-agent/bin/config.json
{
  "metrics": {
    "append_dimensions": {
      "AutoScalingGroupName": "$${aws:AutoScalingGroupName}"
    },
    "metrics_collected": {
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      }
    }
  }
}
CWCONFIG

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
-a fetch-config -m ec2 \
-c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s

sleep 30

docker pull dayanaheredia/frontend-hello-world:latest
docker run -d --restart always -p 3001:3001 dayanaheredia/frontend-hello-world:latest
EOF
  )
}

# ================================
# 5. AUTO SCALING GROUP
# ================================
resource "aws_autoscaling_group" "frontend_asg" {
  name                = "frontend-asg"
  min_size            = 2
  max_size            = 3
  desired_capacity    = 2
  vpc_zone_identifier = data.aws_subnets.default.ids
  target_group_arns   = [aws_lb_target_group.frontend_tg.arn]

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
# CPU > 50%
resource "aws_autoscaling_policy" "frontend_cpu" {
  name                   = "frontend-scale-cpu"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

# Network > 1MB
resource "aws_autoscaling_policy" "frontend_network" {
  name                   = "frontend-scale-network"
  autoscaling_group_name = aws_autoscaling_group.frontend_asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn"
    }
    target_value = 1000000
  }
}

# Memory > 60%
resource "aws_autoscaling_policy" "frontend_memory" {
  name                   = "frontend-scale-memory"
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
