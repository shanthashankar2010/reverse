terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# Latest official Ubuntu AMI from Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "custom-vpc"
  }
}

# Public Subnet
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet"
  }
}

# Private Subnet
resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = false

  tags = {
    Name = "private-subnet"
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "custom-igw"
  }
}

# Public Route Table
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "public-rt"
  }
}

resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# Private Route Table - No NAT Gateway, no internet route
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "private-rt-no-internet"
  }
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}

# Public Server Security Group
resource "aws_security_group" "bastion_sg" {
  name        = "bastion-sg"
  description = "Allow SSH and HTTP to public reverse proxy"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "bastion-sg"
  }
}

# Temporary Apache AMI Builder Security Group
resource "aws_security_group" "apache_builder_sg" {
  name        = "apache-builder-sg"
  description = "Allow outbound internet for Apache AMI build"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "apache-builder-sg"
  }
}

# Private Apache Server Security Group
resource "aws_security_group" "private_sg" {
  name        = "private-sg"
  description = "Allow SSH and HTTP only from public reverse proxy"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  ingress {
    description     = "HTTP from reverse proxy"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion_sg.id]
  }

  egress {
    description = "Outbound inside VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  tags = {
    Name = "private-sg"
  }
}

# Temporary Public EC2 to install Apache and create AMI
resource "aws_instance" "apache_builder" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.large"
  key_name                    = "bastion"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.apache_builder_sg.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -eux

              apt-get update -y
              DEBIAN_FRONTEND=noninteractive apt-get install -y apache2

              systemctl enable apache2
              systemctl start apache2

              echo "Hello from Private Apache EC2 through Public Nginx Reverse Proxy" > /var/www/html/index.html
              EOF

  tags = {
    Name = "Temporary-Apache-AMI-Builder"
  }

  depends_on = [aws_route.public_route]
}

# Wait for Apache installation before creating AMI
resource "time_sleep" "wait_for_apache_install" {
  create_duration = "300s"

  depends_on = [aws_instance.apache_builder]
}

# Create Apache AMI from temporary builder
resource "aws_ami_from_instance" "apache" {
  name               = "ubuntu-apache-private-${formatdate("YYYYMMDDhhmmss", timestamp())}"
  source_instance_id = aws_instance.apache_builder.id

  tags = {
    Name = "ubuntu-apache-private-ami"
  }

  depends_on = [time_sleep.wait_for_apache_install]

  lifecycle {
    ignore_changes = [name]
  }
}

# Stop temporary builder after AMI creation
resource "aws_ec2_instance_state" "stop_apache_builder" {
  instance_id = aws_instance.apache_builder.id
  state       = "stopped"

  depends_on = [aws_ami_from_instance.apache]
}

# Private Apache Server from custom AMI
resource "aws_instance" "private" {
  ami                         = aws_ami_from_instance.apache.id
  instance_type               = "t2.large"
  key_name                    = "bastion"
  subnet_id                   = aws_subnet.private.id
  vpc_security_group_ids      = [aws_security_group.private_sg.id]
  associate_public_ip_address = false

  user_data = <<-EOF
              #!/bin/bash
              set -eux

              systemctl enable apache2
              systemctl start apache2
              EOF

  tags = {
    Name = "Private-Apache"
  }

  depends_on = [aws_route_table_association.private_assoc]
}

# Public Nginx Reverse Proxy Server
resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t2.large"
  key_name                    = "bastion"
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.bastion_sg.id]
  associate_public_ip_address = true

  user_data = <<-EOF
              #!/bin/bash
              set -eux

              apt-get update -y
              DEBIAN_FRONTEND=noninteractive apt-get install -y nginx

              cat > /etc/nginx/sites-available/reverse-proxy <<'NGINX'
              server {
                  listen 80 default_server;
                  listen [::]:80 default_server;

                  server_name _;

                  location / {
                      proxy_pass http://${aws_instance.private.private_ip}:80;
                      proxy_http_version 1.1;

                      proxy_set_header Host $host;
                      proxy_set_header X-Real-IP $remote_addr;
                      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto $scheme;
                  }
              }
              NGINX

              rm -f /etc/nginx/sites-enabled/default
              ln -sf /etc/nginx/sites-available/reverse-proxy /etc/nginx/sites-enabled/reverse-proxy

              nginx -t
              systemctl enable nginx
              systemctl restart nginx
              EOF

  tags = {
    Name = "Bastion-Nginx-Reverse-Proxy"
  }

  depends_on = [aws_route.public_route]
}

output "public_server_ip" {
  description = "Open this IP in browser."
  value       = aws_instance.bastion.public_ip
}

output "private_server_ip" {
  description = "Private Apache server IP."
  value       = aws_instance.private.private_ip
}

output "apache_ami_id" {
  description = "Apache AMI created by Terraform."
  value       = aws_ami_from_instance.apache.id
}
