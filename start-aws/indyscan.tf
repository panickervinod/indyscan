resource "aws_instance" "indyscan" {
  ami = var.ubuntu_ami
  instance_type = var.ec2_size
  availability_zone = var.availability_zone
  key_name = var.keypair_name
  vpc_security_group_ids = flatten([
    aws_security_group.Indyscan_General.id,
    aws_security_group.Indyscan_Services.id,
    aws_security_group.Indyscan_IndyPool_Client.id,
    aws_security_group.Indyscan_IndyPool_Node.id,
    var.custom_security_group_ids
  ])

  root_block_device {
    volume_size = "20"
  }

  tags = {
    Name = var.ec2_tag
  }
}

// When using references to aws_instance in the definition of security groups, following is way how it's possible to
// add those security groups on the primary network interface of our ec2 resource. The problem is that
// if you use "vpc_security_group_ids" in aws_instance definition, you can't use these, they don't go well together
// see: https://www.terraform.io/docs/providers/aws/r/network_interface_sg_attachment.html
// If you don't specify vpc_security_group_ids at all, it will still have "default" VPC group, which I don't know what
// is here, but it might as well expose everything making our security groups defined here completely meaningless.
// TODO: How can we define security groups referring attributes of ec2 instance using them and making sure the ec2
// TODO: instance is not gonna have any other security groups such as "default"?
//resource "aws_network_interface_sg_attachment" "attach_sg_Indyscan_Services" {
//  security_group_id    = aws_security_group.Indyscan_Services.id
//  network_interface_id = aws_instance.indyscan.primary_network_interface_id
//}
//
//resource "aws_network_interface_sg_attachment" "attach_sg_Indyscan_General" {
//  security_group_id    = aws_security_group.Indyscan_General.id
//  network_interface_id = aws_instance.indyscan.primary_network_interface_id
//}
//
//resource "aws_network_interface_sg_attachment" "attach_sg_IndyPool_Client" {
//  security_group_id    = aws_security_group.Indyscan_IndyPool_Client.id
//  network_interface_id = aws_instance.indyscan.primary_network_interface_id
//}
//
//resource "aws_network_interface_sg_attachment" "attach_sg_IndyPool_Node" {
//  security_group_id    = aws_security_group.Indyscan_IndyPool_Node.id
//  network_interface_id = aws_instance.indyscan.primary_network_interface_id
//}

resource "null_resource" "assure_software" {

  connection {
    type = "ssh"
    user = "ubuntu"
    host = aws_instance.indyscan.public_ip
    private_key = file(var.private_key_path)
  }

  provisioner "file" {
    source = "${path.module}/scripts-docker"
    destination = "$HOME"
  }

  provisioner "remote-exec" {
    inline = [
      "set -ex",
      "chmod +x $HOME/scripts-docker/*.sh",
      "$HOME/scripts-docker/assure-docker.sh ||:",
    ]
  }

  provisioner "remote-exec" {
    inline = [
      // it's was happening quite often I had to rerun because of unclear issue in assure-docker.sh
      // (usuall it still wouldn't find docker-ce even after repo was added), so this is dirtyfix. Just rerun once more
      // TODO: must be nice if we stabilize assuer-docker.sh so we could delete this remote-exec
      "$HOME/scripts-docker/assure-docker.sh",
      "rm -r \"$HOME/scripts-docker\"",
    ]
  }
}

/*
Destroys all existing data
Recreate everything from scrach
TODO: Make it possible to restart ledger without destorying it. Right now that's problematic because I can't mount ledger data to named volume. There's a comment about this in start/docker-compose.yml
*/
resource "null_resource" "recreate_environment" {

  connection {
    type = "ssh"
    user = "ubuntu"
    host = aws_instance.indyscan.public_ip
    private_key = file(var.private_key_path)
  }

  depends_on = [
    null_resource.assure_software,
    aws_route53_record.www
  ]

  triggers = {
    key = var.trigger_reset_environment
  }

  // wipe out existing files, destory existing environment
  provisioner "remote-exec" {
    inline = [
      "set -x",
      "cd $HOME/indyscan; docker-compose down --volumes ||:", // since we cannot preserve ledger data, we have to also wipe out elasticsearch data
      "yes | rm -r $HOME/indyscan ||:",
    ]
  }

  // re-copy files
  provisioner "file" {
    source = "${path.module}/../start"
    destination = "$HOME/indyscan"
  }

  provisioner "remote-exec" {
    inline = [
      "set -x",
      "chmod -R +x indyscan/*.sh indyscan/**/*.sh",
    ]
  }

  // build pool image, prepare configuration
  provisioner "remote-exec" {
    inline = [
      "set -x",
      "export POOL_ADDRESS='${coalesce(var.dns_hostname, aws_instance.indyscan.public_ip)}'",
      "export INDYPOOL_IMAGE_TAG=\"indypool-$POOL_ADDRESS:latest\"",
      "yes | ~/indyscan/indypool/build-pool.sh",
      "docker run --rm --name tmp-indypool \"$INDYPOOL_IMAGE_TAG\" cat /var/lib/indy/sandbox/pool_transactions_genesis > ~/indyscan/app-configs-daemon/genesis/INDYSCANPOOL.txn"
    ]
  }

  // start up new environment
  provisioner "remote-exec" {
    inline = [
      "set -x",
      "ls ~",
      "cd ~/indyscan; docker-compose pull --ignore-pull-failures",
      "export POOL_ADDRESS='${coalesce(var.dns_hostname, aws_instance.indyscan.public_ip)}'",
      "export INDYPOOL_IMAGE_TAG=\"indypool-$POOL_ADDRESS:latest\"",
      "echo \"INDYSCAN_INDYPOOL_IMAGE=indypool-$POOL_ADDRESS:latest\" > ~/indyscan/.env",
      "echo Restarting docker-compose with following env file:",
      "cat ~/indyscan/.env",
      "cd ~/indyscan; docker-compose up -d",
    ]
  }
}

//resource "null_resource" "reset-pool" {
//  inline = [
//    "echo 'Completely turning around Indyscan!'",
//    "cd ~/indyscan/indypool; docker-compose down",
//    "alias kill-all-docker-containers='docker rm -f $(docker ps -qa)'",
//    "docker volume --prune --force",
//  ]
//}
//

resource "null_resource" "provision_genesis_locally" {

  triggers = {
    key = var.trigger_reset_environment
  }

  depends_on = [
    null_resource.recreate_environment,
  ]

  provisioner "local-exec" {
    command = "mkdir -p ${path.module}/tmp; rm ${path.module}/tmp/genesis.txn || :"
  }

  provisioner "local-exec" {
    command = "scp -o \"StrictHostKeyChecking no\" -i ${var.private_key_path} ubuntu@${aws_instance.indyscan.public_ip}:~/indyscan/app-configs-daemon/genesis/INDYSCANPOOL.txn ${path.module}/tmp/${var.local_network_name}.txn"
  }

  provisioner "local-exec" {
    command = "export PROVISION_POOL_DIR=\"$HOME/.indy_client/pool/${var.local_network_name}\"; mkdir -p \"$PROVISION_POOL_DIR\" || :; cp ${path.module}/tmp/${var.local_network_name}.txn \"$PROVISION_POOL_DIR/${var.local_network_name}.txn\" || :;"
  }

  provisioner "local-exec" {
    command = "echo \"Genesis file for your AWS Indypool is located at: $HOME/.indy_client/pool/${var.local_network_name}/${var.local_network_name}.txn\""
  }
}

resource "null_resource" "print_info" {

  triggers = {
    key = uuid()
  }

  depends_on = [
    null_resource.recreate_environment,
    null_resource.provision_genesis_locally
  ]

  provisioner "local-exec" {
    command = "./print-info.sh ${var.local_network_name} http://${aws_instance.indyscan.public_ip}:3707 http://${aws_instance.indyscan.public_ip}:3708"
  }
}
