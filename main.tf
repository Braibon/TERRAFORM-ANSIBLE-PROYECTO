provider "aws" {
  region = "us-east-1" 
}

# ================= 1. REDES (VPC) =================
resource "aws_vpc" "vpc_alberto" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "VPC-Alberto" }
}

resource "aws_subnet" "sr_publica" {
  vpc_id                  = aws_vpc.vpc_alberto.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
  tags = { Name = "SR-Publica" }
}

resource "aws_subnet" "sr_privada" {
  vpc_id            = aws_vpc.vpc_alberto.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-east-1d"
  tags = { Name = "SR-Privada" }
}

resource "aws_internet_gateway" "igw_alberto" {
  vpc_id = aws_vpc.vpc_alberto.id
  tags = { Name = "IGW-Alberto" }
}

# ================= 2. RUTAS =================
resource "aws_route_table" "rt_publica" {
  vpc_id = aws_vpc.vpc_alberto.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw_alberto.id
  }
  tags = { Name = "RT-Publica" }
}
resource "aws_route_table_association" "assoc_publica" {
  subnet_id      = aws_subnet.sr_publica.id
  route_table_id = aws_route_table.rt_publica.id
}

resource "aws_route_table" "rt_privada" {
  vpc_id = aws_vpc.vpc_alberto.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_instance.proxy_nat.primary_network_interface_id
  }
  tags = { Name = "RT-Privada" }
}
resource "aws_route_table_association" "assoc_privada" {
  subnet_id      = aws_subnet.sr_privada.id
  route_table_id = aws_route_table.rt_privada.id
}

# ================= 3. GRUPOS DE SEGURIDAD =================
resource "aws_security_group" "sg_proxy" {
  name        = "Alberto_Nginx_proxy"
  description = "Permite HTTP/HTTPS y SSH externo, y trafico de la subred privada para NAT"
  vpc_id      = aws_vpc.vpc_alberto.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.1.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sg_monitorizacion" {
  name        = "Alberto_monitorizacion"
  vpc_id      = aws_vpc.vpc_alberto.id

  # Permitir entrada SSH desde el Proxy/NAT
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_proxy.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "sg_web" {
  name        = "Alberto_ServidorWEB"
  vpc_id      = aws_vpc.vpc_alberto.id

  # Permite tráfico desde el Nginx Proxy
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    security_groups = [aws_security_group.sg_proxy.id]
  }

  # Permite SSH desde el servidor de monitorizacion
  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.sg_monitorizacion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
# ================= 4. INSTANCIAS (Ubuntu 24.04 - t3.small) =================
data "aws_ami" "ubuntu24" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  owners = ["099720109477"]
}

resource "aws_instance" "proxy_nat" {
  ami           = data.aws_ami.ubuntu24.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.sr_publica.id
  vpc_security_group_ids = [aws_security_group.sg_proxy.id]
  key_name      = "vockey" 
  source_dest_check = false 

  tags = { Name = "ProxyNat-Alberto" }
}

resource "aws_instance" "web" {
  count         = 2
  ami           = data.aws_ami.ubuntu24.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.sr_privada.id
  vpc_security_group_ids = [aws_security_group.sg_web.id]
  key_name      = "vockey"

  tags = { Name = "ServidorWeb${count.index + 1}-Alberto" }
}

resource "aws_instance" "monitorizacion" {
  ami           = data.aws_ami.ubuntu24.id
  instance_type = "t3.small"
  subnet_id     = aws_subnet.sr_privada.id
  vpc_security_group_ids = [aws_security_group.sg_monitorizacion.id]
  key_name      = "vockey"

  tags = { Name = "Servidor_monitorizacion" }
}

# ================= 5. OUTPUTS =================
output "IP_ProxyNat_Publica" { value = aws_instance.proxy_nat.public_ip }
output "IPs_Webs_Privadas" { value = aws_instance.web[*].private_ip }
output "IP_Monitor_Privada" { value = aws_instance.monitorizacion.private_ip }
