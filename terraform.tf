#############################################
# Variables
#############################################

# certification
variable "aws_access_key" {}
variable "aws_secret_key" {}

# region
variable "aws_region" {}

# availability zones
variable "azs" {
  default {
    "a" = "ap-northeast-1a"
    "c" = "ap-northeast-1c"
    "d" = "ap-northeast-1d"
  }
}

# db setting
variable "main_aurora_root_user" {}
variable "main_aurora_root_password" {}
variable "main_aurora_instance_count" {
  default = "2"
}
variable "main_aurora_instance_class" {
  default = "db.t2.medium"
}

# ssh key
variable "external_ip" {}
variable "host_ssh_key" {}

#############################################
# Provider
#############################################

provider "aws" {
  access_key = "${var.aws_access_key}"
  secret_key = "${var.aws_secret_key}"
  region     = "${var.aws_region}"
}

#############################################
# VPC
#############################################

resource "aws_vpc" "db-vpc" {
  cidr_block = "10.0.0.0/16"

  tags {
    Name = "db-vpc"
  }

  # We explicitly prevent destruction using terraform. Remove this only if you really know what you're doing.
  lifecycle {
    prevent_destroy = false
  }
}

#############################################
# Route
#############################################

resource "aws_internet_gateway" "db-vpc-internet-gateway" {
  vpc_id = "${aws_vpc.db-vpc.id}"

  tags {
    Name = "db-vpc-internet-gateway"
  }

  depends_on = [
    "aws_vpc.db-vpc"
  ]

  # We explicitly prevent destruction using terraform. Remove this only if you really know what you're doing.
  lifecycle {
    prevent_destroy = false
  }
}

resource "aws_route" "db-vpc-route-external" {
  route_table_id = "${aws_vpc.db-vpc.default_route_table_id}"
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = "${aws_internet_gateway.db-vpc-internet-gateway.id}"

  # We explicitly prevent destruction using terraform. Remove this only if you really know what you're doing.
  lifecycle {
    prevent_destroy = false
  }
}


#############################################
# subnet
#############################################

resource "aws_subnet" "db-vpc-subnet-a1" {
  vpc_id     = "${aws_vpc.db-vpc.id}"
  availability_zone = "${lookup(var.azs, "a")}"
  cidr_block = "${cidrsubnet(aws_vpc.db-vpc.cidr_block, 8, 0)}"

  tags {
    Name = "db-vpc-subnet-a1"
  }
}

resource "aws_subnet" "db-vpc-subnet-c1" {
  vpc_id     = "${aws_vpc.db-vpc.id}"
  availability_zone = "${lookup(var.azs, "c")}"
  cidr_block = "${cidrsubnet(aws_vpc.db-vpc.cidr_block, 8, 1)}"

  tags {
    Name = "db-vpc-subnet-c1"
  }
}

resource "aws_subnet" "db-vpc-subnet-d1" {
  vpc_id     = "${aws_vpc.db-vpc.id}"
  availability_zone = "${lookup(var.azs, "d")}"
  cidr_block = "${cidrsubnet(aws_vpc.db-vpc.cidr_block, 8, 2)}"

  tags {
    Name = "db-vpc-subnet-d1"
  }
}

resource "aws_db_subnet_group" "db-vpc-subnet-group" {
  name = "db-vpc-subnet-group"
  subnet_ids = [
    "${aws_subnet.db-vpc-subnet-a1.id}",
    "${aws_subnet.db-vpc-subnet-c1.id}",
    "${aws_subnet.db-vpc-subnet-d1.id}"
  ]
}

resource "aws_route_table_association" "db-route-table-association-a" {
  route_table_id = "${aws_route.db-vpc-route-external.route_table_id}"
  subnet_id      = "${aws_subnet.db-vpc-subnet-a1.id}"
}

resource "aws_route_table_association" "db-route-table-association-c" {
  route_table_id = "${aws_route.db-vpc-route-external.route_table_id}"
  subnet_id      = "${aws_subnet.db-vpc-subnet-c1.id}"
}

resource "aws_route_table_association" "db-route-table-association-d" {
  route_table_id = "${aws_route.db-vpc-route-external.route_table_id}"
  subnet_id      = "${aws_subnet.db-vpc-subnet-d1.id}"
}

#############################################
# security group
#############################################

resource "aws_security_group" "db-main-aurora-security-group" {
  name = "db-main-aurora-security-group"
  description = "for main aurora"
  vpc_id = "${aws_vpc.db-vpc.id}"

  ingress {
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
    cidr_blocks = ["${aws_vpc.db-vpc.cidr_block}"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}

resource "aws_security_group" "db-bastion-host-security-group" {
  name = "db-bastion-host-security-group"
  description = "for db bastion host"
  vpc_id = "${aws_vpc.db-vpc.id}"

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.external_ip}"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

#############################################
# IAM
#############################################

resource "aws_iam_role" "db-main-aurora-monitoring" {
  name = "db-main-aurora-monitoring"
  path = "/"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "monitoring.rds.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
POLICY

}

resource "aws_iam_role_policy_attachment" "db-main-aurora-monitoring" {
  role       = "${aws_iam_role.db-main-aurora-monitoring.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"

}

#############################################
# RDS
#############################################

/////////////////////////////////
// main aurora
/////////////////////////////////

resource "aws_db_parameter_group" "db-main-aurora-db-param-group" {
  name   = "db-main-aurora-db-param-group"
  family = "aurora5.6"

  tags {
    Name = "db-main-aurora"
  }

  parameter {
    name         = "innodb_sort_buffer_size"
    value        = "4194304"
    apply_method = "pending-reboot"
  }

}

resource "aws_rds_cluster_parameter_group" "db-main-aurora-cluster-param-group" {
  name        = "db-main-aurora-cluster-param-group"
  family      = "aurora5.6"
  description = "Cluster parameter group for db-main-aurora"

  tags {
    Name    = "db-main-aurora"
  }

  parameter {
    name         = "character_set_client"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "character_set_connection"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "character_set_database"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "character_set_filesystem"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "character_set_results"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "character_set_server"
    value        = "utf8mb4"
    apply_method = "immediate"
  }

  parameter {
    name         = "collation_connection"
    value        = "utf8mb4_general_ci"
    apply_method = "immediate"
  }

  parameter {
    name         = "collation_server"
    value        = "utf8mb4_general_ci"
    apply_method = "immediate"
  }

  parameter {
    name         = "time_zone"
    value        = "utc"
    apply_method = "immediate"
  }

  parameter {
    name         = "binlog_format"
    value        = "mixed"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "innodb_flush_log_at_trx_commit"
    value        = "2"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "innodb_strict_mode"
    value        = "1"
    apply_method = "immediate"
  }

  parameter {
    name         = "skip-character-set-client-handshake"
    value        = "1"
    apply_method = "pending-reboot"
  }

}

resource "aws_rds_cluster" "db-main-aurora" {
  cluster_identifier              = "db-main-aurora"
  master_username                 = "${var.main_aurora_root_user}"
  master_password                 = "${var.main_aurora_root_password}"
  availability_zones              = ["${lookup(var.azs, "a")}", "${lookup(var.azs, "c")}", "${lookup(var.azs, "d")}"]
  backup_retention_period         = 7
  preferred_backup_window         = "17:00-17:30"
  preferred_maintenance_window    = "sun:19:24-sun:19:54"
  port                            = 3306
  vpc_security_group_ids          = ["${aws_security_group.db-main-aurora-security-group.id}"]
  db_subnet_group_name            = "${aws_db_subnet_group.db-vpc-subnet-group.name}"
  db_cluster_parameter_group_name = "${aws_rds_cluster_parameter_group.db-main-aurora-cluster-param-group.name}"
  final_snapshot_identifier       = "db-main-aurora-final-snapshot"
  skip_final_snapshot             = false
  enabled_cloudwatch_logs_exports = ["error"]

  tags {
    Name    = "db-main-aurora"
  }

}

resource "aws_rds_cluster_instance" "db-main-aurora-instance" {
  count = "${var.main_aurora_instance_count}"

  identifier                      = "db-main-aurora-instance-${count.index}"
  cluster_identifier              = "${aws_rds_cluster.db-main-aurora.id}"
  instance_class                  = "${var.main_aurora_instance_class}"
  db_subnet_group_name            = "${aws_db_subnet_group.db-vpc-subnet-group.name}"
  db_parameter_group_name         = "${aws_db_parameter_group.db-main-aurora-db-param-group.name}"
  monitoring_role_arn             = "${aws_iam_role.db-main-aurora-monitoring.arn}"
  monitoring_interval             = 60
  auto_minor_version_upgrade      = false
  preferred_maintenance_window    = "sun:19:24-sun:19:54"

  tags {
    Name = "db-main-aurora",
    mackerel = "true"
  }
}

#############################################
# EC2
#############################################

resource "aws_instance" "db-bastion-host" {
  ami = "ami-ceafcba8"
  instance_type = "t2.medium"

  availability_zone = "${lookup(var.azs, "a")}"
  vpc_security_group_ids = [
    "${aws_security_group.db-bastion-host-security-group.id}"
  ]
  key_name = "${var.host_ssh_key}"
  subnet_id = "${aws_subnet.db-vpc-subnet-a1.id}"
  associate_public_ip_address = true

  tags {
    Name = "db-bastion-host"
  }
}
