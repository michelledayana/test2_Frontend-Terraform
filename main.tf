provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Owner   = "Heredia"
      Project = "Distributed-Exam"
      Service = "Frontend"
    }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# ------------------------------
# Security Group
# ------------------------------
resource "aws_security_group" "frontend_sg" {
  name        = "frontend-sg"
  description = "Managed by Terraform"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ------------------------------
# Launch Template
# ------------------------------
resource "aws_launch_template" "frontend_lt" {
  name_prefix   = "frontend-lt-"
  image_id      = "ami-0c02fb55956c7d316"
  instance_type = "t2.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.frontend_sg.id]
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install docker -y
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ec2-user

    # CloudWatch Agent
    yum install -y amazon-cloudwatch-agent
    cat <<CONFIG > /opt/aws/amazon-cloudwatch-agent/bin/config.json
    {
      "metrics": {
        "append_dimensions": {
          "AutoScalingGroupName": "\${aws:AutoScalingGroupName}"
        },
        "metrics_collected": {
          "mem": {
            "measurement": ["mem_used_percent"],
            "metrics_collection_interval": 60
          }
        }
      }
    }
    CONFIG

    /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
      -a fetch-config -m ec2 -c file:/opt/aws/amazon-cloudwatch-agent/bin/config.json -s
    docker pull dayanaheredia/frontend-hello-world:latest
    docker run -d -p 3001:3001 dayana/frontend-hello-world:latest
  EOF)
}

# ------------------------------
# Application Load Balancer
# ------------------------------
resource "aws_lb" "frontend_alb" {
  name               = "frontend-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.frontend_sg.id]
  enable_http2       = true
}

# ------------------------------
# Target Group
# ------------------------------
resource "aws_lb_target_group" "frontend_tg" {
  name     = "frontend-tg"
  port     = 3001
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }

  target_type = "instance"
}

# ------------------------------
# Listener
# ------------------------------
resource "aws_lb_listener" "frontend_listener" {
  load_balancer_arn = aws_lb.frontend_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_tg.arn
  }
}

# ------------------------------
# Auto Scaling Group
# ------------------------------
resource "aws_autoscaling_group" "frontend_asg" {
  name                      = "frontend-asg"
  max_size                  = 3
  min_size                  = 2
  desired_capacity          = 2
  vpc_zone_identifier       = data.aws_subnets.default.ids
  health_check_type         = "EC2"
  health_check_grace_period = 300
  launch_template {
    id      = aws_launch_template.frontend_lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.frontend_tg.arn]

  tag {
    key                 = "Name"
    value               = "frontend-instance"
    propagate_at_launch = true
  }
}

# ------------------------------
# Auto Scaling Policies
# ------------------------------
resource "aws_autoscaling_policy" "frontend_cpu" {
  name                    = "frontend-scale-cpu"
  autoscaling_group_name  = aws_autoscaling_group.frontend_asg.name
  policy_type             = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50
  }
}

resource "aws_autoscaling_policy" "frontend_memory" {
  name                    = "frontend-scale-memory"
  autoscaling_group_name  = aws_autoscaling_group.frontend_asg.name
  policy_type             = "TargetTrackingScaling"

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

resource "aws_autoscaling_policy" "frontend_network" {
  name                    = "frontend-scale-network"
  autoscaling_group_name  = aws_autoscaling_group.frontend_asg.name
  policy_type             = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageNetworkIn"
    }
    target_value = 1000000
  }
}

# ------------------------------
# Outputs
# ------------------------------
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
