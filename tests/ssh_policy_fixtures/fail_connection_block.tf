resource "aws_instance" "web" {
  ami = "ami-0123456789abcdef0"

  provisioner "remote-exec" {
    inline = ["true"]

    connection {
      user = "ubuntu"
      host = self.public_ip
    }
  }
}
