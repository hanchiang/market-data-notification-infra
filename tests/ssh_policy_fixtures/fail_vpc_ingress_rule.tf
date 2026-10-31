resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = "sg-0123456789abcdef0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}
