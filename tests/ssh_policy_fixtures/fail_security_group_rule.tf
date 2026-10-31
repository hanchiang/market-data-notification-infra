resource "aws_security_group_rule" "home" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["198.51.100.7/32"]
  security_group_id = "sg-0123456789abcdef0"
}
