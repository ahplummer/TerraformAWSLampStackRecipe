resource "aws_key_pair" "instancekp" {
  key_name = "kp-${var.PROJECT}"
  public_key = file("sshkey.pub")
  tags = {
    Project  = var.PROJECT
    Name = "kp-${var.PROJECT}"
  }
}

resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags = {
    Project  = var.PROJECT
    Name = "vpc-${var.PROJECT}"
  }
}

resource "aws_subnet" "subnetA" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "${var.REGION}a"
  tags = {
    Project  = var.PROJECT
    Name = "sn-${var.PROJECT}a"
  }
}
resource "aws_subnet" "subnetB" {
  vpc_id            = aws_vpc.my_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.REGION}b"
  tags = {
    Project  = var.PROJECT
    Name = "sn-${var.PROJECT}b"
  }
}


resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Project  = var.PROJECT
    Name = "igw-${var.PROJECT}"
  }
}

resource "aws_route_table" "my_vpc_public" {
  vpc_id = aws_vpc.my_vpc.id
  route {
      cidr_block = "0.0.0.0/0"
      gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Project  = var.PROJECT
    Name = "rt-${var.PROJECT}"
  }
}

resource "aws_route_table_association" "my_vpc_A_public" {
    subnet_id = aws_subnet.subnetA.id
    route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_route_table_association" "my_vpc_B_public" {
    subnet_id = aws_subnet.subnetB.id
    route_table_id = aws_route_table.my_vpc_public.id
}

resource "aws_security_group" "allow_http_ssh" {
  name = "allow_http"
  vpc_id = aws_vpc.my_vpc.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 0
    to_port = 0
    protocol = -1
    self = true
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Project  = var.PROJECT
    Name = "sg-${var.PROJECT}-http"
  }
}

resource "aws_launch_configuration" "lamp" {
  name_prefix = "lamp-"
  image_id = var.AMI_ID 
  instance_type = "t2.micro"
  key_name = aws_key_pair.instancekp.key_name
  security_groups = [ aws_security_group.allow_http_ssh.id ]
  associate_public_ip_address = true
  depends_on = [
    aws_db_instance.primaryA
  ]
  user_data     = <<-EOF
                  #!/bin/bash
                  sudo su
                  yum -y install httpd php mysql php-mysqli
                  echo "<?php
\$servername = \"${aws_db_instance.primaryA.endpoint}\";
\$username 	= \"${var.DB_USER}\";
\$password 	= \"${var.DB_PASSWORD}\";
\$dbname		= \"mydb\";
\$conn = new mysqli(\$servername, \$username, \$password, \$dbname);
if (\$conn->connect_error) {
    die(\"Connection failed: \" . \$conn->connect_error);
} 
\$sql = \"CREATE TABLE MyGuests (
id INT(6) UNSIGNED AUTO_INCREMENT PRIMARY KEY, 
firstname VARCHAR(30) NOT NULL,
lastname VARCHAR(30) NOT NULL,
email VARCHAR(50),
reg_date TIMESTAMP
)\";
if (\$conn->query(\$sql) === TRUE) {
    echo \"Table MyGuests created successfully\";
} else {
    echo \"Error creating table: \" . \$conn->error;
}
\$sql = \"INSERT INTO MyGuests (firstname, lastname, email)
VALUES ('John', 'Doe', 'john@example.com')\";
if (\$conn->query(\$sql) === TRUE) {
    \$last_id = \$conn->insert_id;
    echo \"New record created successfully. Last inserted ID is: \" . \$last_id;
} else {
    echo \"Error: \" . \$sql . \"<br>\" . \$conn->error;
}
\$sql = \"SELECT id, firstname, lastname FROM MyGuests\";
\$result = \$conn->query(\$sql);
if (\$result->num_rows > 0) {
    while(\$row = \$result->fetch_assoc()) {
        echo \"id: \" . \$row[\"id\"]. \" - Name: \" . \$row[\"firstname\"]. \" \" . \$row[\"lastname\"]. \"<br>\";
    }
} else {
    echo \"0 results\";
}
\$conn->close();
?>" >> /var/www/html/calldb.php
                  echo "<p> My Instance! </p>" >> /var/www/html/index.html
                  echo "<?php \$ip = \$_SERVER['SERVER_ADDR']; echo 'Server IP: ' . \$ip;  ?>" > /var/www/html/index.php
                  sudo systemctl enable httpd
                  sudo systemctl start httpd
                  EOF
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "elb_http" {
  name        = "elb_http"
  description = "Allow HTTP traffic to instances through Elastic Load Balancer"
  vpc_id = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  tags = {
    Project  = var.PROJECT
    Name = "elb-${var.PROJECT}"
  }
}

resource "aws_elb" "web_elb" {
  name = "web-elb"
  security_groups = [
    aws_security_group.elb_http.id
  ]
  subnets = [
    aws_subnet.subnetA.id,
    aws_subnet.subnetB.id
  ]

  cross_zone_load_balancing   = true

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    interval = 30
    target = "HTTP:80/"
  }

  listener {
    lb_port = 80
    lb_protocol = "http"
    instance_port = "80"
    instance_protocol = "http"
  }
  tags = {
    Project  = var.PROJECT
    Name = "sg-${var.PROJECT}-elb"
  }
}
resource "aws_autoscaling_group" "lamp" {
  name = "${aws_launch_configuration.lamp.name}-asg"

  min_size             = 1
  desired_capacity     = 2
  max_size             = 4
  
  health_check_type    = "ELB"
  load_balancers = [
    aws_elb.web_elb.id
  ]

  launch_configuration = aws_launch_configuration.lamp.name

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupTotalInstances"
  ]

  metrics_granularity = "1Minute"

  vpc_zone_identifier  = [
    aws_subnet.subnetA.id,
    aws_subnet.subnetB.id
  ]

  # Required to redeploy without an outage.
  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "lamp"
    propagate_at_launch = true
  }

}

resource "aws_subnet" "privateDBA" {
  cidr_block = "10.0.2.0/24"
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = "${var.REGION}a"
  map_public_ip_on_launch = false
  tags = {
    Name = "Private-Subnet-${var.PROJECT}a"
    Project = var.PROJECT
  }
}
resource "aws_subnet" "privateDBB" {
  cidr_block = "10.0.3.0/24"
  vpc_id = aws_vpc.my_vpc.id
  availability_zone = "${var.REGION}b"
  map_public_ip_on_launch = false
  tags = {
    Name = "Private-Subnet-${var.PROJECT}b"
    Project = var.PROJECT
  }
}

resource "aws_db_subnet_group" "default" {
  name = "rds_subg"
  subnet_ids = [ aws_subnet.privateDBA.id, aws_subnet.privateDBB.id ]
  tags = {
    Project  = var.PROJECT
    Name = "dbsubg-${var.PROJECT}"
  }
}
resource "aws_db_parameter_group" "default" {
  name   = "lab-mysql"
  family = "mysql8.0"

  parameter {
    name  = "character_set_client"
    value = "utf8"
  }
  parameter {
    name  = "character_set_connection"
    value = "utf8"
  }
  parameter {
    name  = "character_set_database"
    value = "utf8"
  }
  parameter {
    name  = "character_set_filesystem"
    value = "utf8"
  }
  parameter {
    name  = "character_set_results"
    value = "utf8"
  }
  parameter {
    name  = "character_set_server"
    value = "utf8"
  }
}
resource "aws_db_instance" "primaryA" {
  allocated_storage    = 10
  engine               = "mysql"
  engine_version       = "8.0.20"
  instance_class       = "db.m5.large"
  name                 = "mydb"
  identifier           = "mydb-main"
  username             = var.DB_USER
  password             = var.DB_PASSWORD
  parameter_group_name = aws_db_parameter_group.default.name
  apply_immediately = true
  skip_final_snapshot  = true
  publicly_accessible  = false
  multi_az = true
  db_subnet_group_name = aws_db_subnet_group.default.name
  vpc_security_group_ids = [ aws_security_group.allow_http_ssh.id ]
  backup_retention_period = 1
  tags = {
    Project  = var.PROJECT
    Name = "rds-${var.PROJECT}-a"
  }
}
resource "aws_db_instance" "primaryB" {
  name                 = "mydb-replica"
  identifier           = "mydb-replica"
  replicate_source_db = aws_db_instance.primaryA.id
  instance_class       = "db.m5.large"
  apply_immediately = true
  skip_final_snapshot  = true
  publicly_accessible  = false
  parameter_group_name = aws_db_parameter_group.default.name
  multi_az = true
  vpc_security_group_ids = [ aws_security_group.allow_http_ssh.id ]
  tags = {
    Project  = var.PROJECT
    Name = "rds-${var.PROJECT}-b"
  }
}