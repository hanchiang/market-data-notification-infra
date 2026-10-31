resource "aws_security_group" "web" {
  ingress {
    # A range that covers 22, IPv6 only.
    from_port        = 0
    to_port          = 1024
    protocol         = "tcp"
    ipv6_cidr_blocks = ["::/0"]
  }
}
