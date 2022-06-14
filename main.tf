terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.18.0"
    }
  }
}

provider "aws" {
    profile = "tivix"
    region = "us-west-1"
}

#Default vpc id
variable "aws_vpc_id" {
  description = "The ID of exsiting vpc"
  default = "vpc-04c4cd01606ca25a7"
}

#Default to recruitment@candidate028 subnet id
variable "aws_subnet_id" {
  description = "The ID of exsiting instance"
  default = "subnet-026733123c2fd6ebb"
}

#Exisitng VPC data
data "aws_vpc" "vpc" {
    id = var.aws_vpc_id
}

#Exisitng subnet hositing recngx01 ec2
data "aws_subnet" "existingSubnet" {
    vpc_id = var.aws_vpc_id
    id = var.aws_subnet_id
}

#Create subnet for new EC2 in different AZ
resource "aws_subnet" "mySubnet" {
    vpc_id = var.aws_vpc_id
    availability_zone = "us-west-1a"
    cidr_block = "172.16.1.0/24"
    map_public_ip_on_launch = data.aws_subnet.existingSubnet.map_public_ip_on_launch
    tags = {
        "Name": "recruitment@candidate028_2",
        "env": data.aws_subnet.existingSubnet.tags.env,
        "project": data.aws_subnet.existingSubnet.tags.project,
        "provisioner": data.aws_subnet.existingSubnet.tags.provisioner
    }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.mySubnet.id
  route_table_id = "rtb-0f49bfff166db00db"
}

#AMI lookup
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

#New Security Group for EC2, allows only HTTP traffic from ALB 
resource "aws_security_group" "mySG" {
  name        = "allow_http_from_alb"
  description = "Allow http inbound traffic"
  vpc_id      = data.aws_vpc.vpc.id

  ingress {
    description      = "HTTP from ALB"
    from_port        = 80
    to_port          = 80
    protocol         = "TCP"
    security_groups = ["sg-0e1443c03afa4d34e"]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
      "Name": "mySG",
      "env": "candidate028",
      "project": "recruitment",
      "provisioner": "terraform"
  }
}

#Launch template created based on recngx01 EC2
resource "aws_launch_template" "myLT" {
    ebs_optimized = true
    image_id = data.aws_ami.ubuntu.id
    instance_type = "t3.micro"
    user_data = file("b64-user-data")
    vpc_security_group_ids = [aws_security_group.mySG.id]
    iam_instance_profile {
      arn = "arn:aws:iam::468078831388:instance-profile/recruitment@candidate028"
    }
    monitoring {
      enabled = false
    }
}

# ASG to spin up 2 EC2
resource "aws_autoscaling_group" "myAsg" {
  vpc_zone_identifier = [ data.aws_subnet.existingSubnet.id, aws_subnet.mySubnet.id ]
  desired_capacity   = 2
  max_size           = 2
  min_size           = 1
  target_group_arns = [aws_lb_target_group.myTG.arn]

  tag {
    key = "Name"
    value = "recngx"
    propagate_at_launch = true
  }
  tag {
    key = "env"
    value = "candidate028"
    propagate_at_launch = true
  }
  tag {
    key = "project"
    value = "recruitment"
    propagate_at_launch = true
  }
  tag {
    key = "provisioner"
    value = "terraform"
    propagate_at_launch = true
  }

  launch_template {
    id      = aws_launch_template.myLT.id
    version = "$Latest"
  }
}

#ALB. 
#Resuse exisitng SG (0.0.0.0/0 on 22 and 80)
resource "aws_lb" "myALB" {
  name               = "myALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = ["sg-0e1443c03afa4d34e"]
  subnets            = [ data.aws_subnet.existingSubnet.id, aws_subnet.mySubnet.id ]

  tags = {
      "Name": "myALB",
      "env": "candidate028",
      "project": "recruitment",
      "provisioner": "terraform"
  }
}

#Target Group for Auto Scaling Group HTTP traffic
resource "aws_lb_target_group" "myTG" {
  name        = "myTG"
  target_type = "instance"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.vpc.id
}

#Listener to forwrad HTTP traffic from ALB to Target Group
resource "aws_lb_listener" "myListener" {
  load_balancer_arn = aws_lb.myALB.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.myTG.arn
  }
}
