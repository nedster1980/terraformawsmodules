
#Display public-ip without pocking around in AWS console
/*
output "public_ip" {
  value = "${aws_instance.example.public_ip}"
}
*/




//Display DNS name of the ELB
output "elb_dns_name" {
  value = "${aws_elb.example.dns_name}"
}

//Display autoscale group name
output "asg_name" {
  value = "${aws_autoscaling_group.example.name}"
}


