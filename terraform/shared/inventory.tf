data "aws_db_instance" "aiarap" {
  db_instance_identifier = var.aiarap_db_instance_identifier
}

resource "aws_security_group" "pg_writer" {
  name        = "varunerp-pg-writer-sg"
  description = "pg-inventory-writer Lambda ENIs — egress only, no inbound needed"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Self-wires the RDS side of this if you provide its security group ID;
# otherwise add the equivalent ingress rule (5432 from this SG) yourself.
resource "aws_security_group_rule" "aiarap_allow_pg_writer" {
  count                    = var.aiarap_db_security_group_id != null ? 1 : 0
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = var.aiarap_db_security_group_id
  source_security_group_id = aws_security_group.pg_writer.id
}

module "pg_writer" {
  source = "../modules/pg-inventory-writer"

  db_host                = data.aws_db_instance.aiarap.address
  db_port                = data.aws_db_instance.aiarap.port
  db_name                = var.aiarap_db_name
  db_secret_arn          = var.aiarap_db_secret_arn
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = [aws_security_group.pg_writer.id]
}
