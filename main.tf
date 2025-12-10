#####################################################
# VPC
#####################################################
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags = { Name = "lab-vpc" }
}

#####################################################
# PUBLIC SUBNETS
#####################################################
resource "aws_subnet" "s1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "s2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  map_public_ip_on_launch = true
}

#####################################################
# INTERNET GATEWAY
#####################################################
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

#####################################################
# ROUTE TABLE + DEFAULT ROUTE
#####################################################
resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

#####################################################
# ROUTE TABLE ASSOCIATIONS
#####################################################
resource "aws_route_table_association" "rta1" {
  subnet_id      = aws_subnet.s1.id
  route_table_id = aws_route_table.rt.id
}

resource "aws_route_table_association" "rta2" {
  subnet_id      = aws_subnet.s2.id
  route_table_id = aws_route_table.rt.id
}

#####################################################
# SECURITY GROUP (HTTP + SSH)
#####################################################
resource "aws_security_group" "web_sg" {
  name   = "lab-web-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
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
}

#####################################################
# LAUNCH TEMPLATE (NGINX + USER DATA)
#####################################################

# AMI Amazon Linux 2
data "aws_ami" "amzn2" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_launch_template" "lt" {
  name_prefix   = "lab-lt-"
  image_id      = data.aws_ami.amzn2.id
  instance_type = "t3.micro"

  network_interfaces {
    security_groups = [aws_security_group.web_sg.id]
    associate_public_ip_address = true
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    amazon-linux-extras install -y nginx1
    systemctl enable nginx
    echo "<h1>NGINX ASG - $(hostname) - $(curl -s http://169.254.169.254/latest/meta-data/instance-id)</h1>" > /usr/share/nginx/html/index.html
    systemctl start nginx
  EOF
  )
}

#####################################################
# APPLICATION LOAD BALANCER (ALB)
#####################################################
resource "aws_lb" "alb" {
  name               = "lab-alb"
  load_balancer_type = "application"
  subnets            = [aws_subnet.s1.id, aws_subnet.s2.id]
  security_groups    = [aws_security_group.web_sg.id]
}

#####################################################
# TARGET GROUP
#####################################################
resource "aws_lb_target_group" "tg" {
  name     = "lab-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

#####################################################
# ALB LISTENER
#####################################################
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

#####################################################
# AUTO SCALING GROUP (ASG)
#####################################################
resource "aws_autoscaling_group" "asg" {
  name                = "lab-asg"
  max_size            = 5
  min_size            = 2
  desired_capacity    = 3
  vpc_zone_identifier = [aws_subnet.s1.id, aws_subnet.s2.id]

  launch_template {
    id      = aws_launch_template.lt.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.tg.arn]
  health_check_type = "ELB"

  tag {
    key                 = "Name"
    value               = "lab-asg-instance"
    propagate_at_launch = true
  }
}

#####################################################
# AUTO SCALING POLICY #1 — SCALE OUT BY CPU USAGE
#####################################################
resource "aws_autoscaling_policy" "scale_out" {
  name                   = "lab-scale-out"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "lab-asg-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 50
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.asg.name
  }
}

#####################################################
# AUTO SCALING POLICY #2 — SCALE OUT BY ALB REQUEST COUNT
#####################################################
resource "aws_autoscaling_policy" "scale_out_requests" {
  name                   = "asg-scale-out-requests"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
}

resource "aws_cloudwatch_metric_alarm" "high_requests" {
  alarm_name          = "asg-high-request-per-target"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 80
  period              = 60
  metric_name         = "RequestCountPerTarget"
  namespace           = "AWS/ApplicationELB"
  statistic           = "Sum"

  alarm_actions = [aws_autoscaling_policy.scale_out_requests.arn]

  dimensions = {
    TargetGroup  = aws_lb_target_group.tg.arn_suffix
    LoadBalancer = aws_lb.alb.arn_suffix
  }
}

#####################################################
# OUTPUTS
#####################################################
output "alb_dns" {
  value = aws_lb.alb.dns_name
}

output "asg_name" {
  value = aws_autoscaling_group.asg.name
}
