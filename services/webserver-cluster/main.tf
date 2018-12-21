data "aws_availability_zones" "all" {}

data "terraform_remote_state" "db" {
  backend = "s3"

  config {
    //bucket = "terraform-neilrichards-up-and-run"
    bucket = "${var.db_remote_state_bucket}"
    //key = "stage/data-stores/mysql/terraform.tfstate"
    key = "${var.db_remote_state_key}"
    region = "eu-west-2"
  }
}

resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"
}

resource "aws_security_group_rule" "allow_tcp_inbound" {
  from_port = "${var.server_port}"
  protocol = "tcp"
  security_group_id = "${aws_security_group.instance.id}"
  to_port = "${var.server_port}"
  type = "ingress"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_launch_configuration" "example" {
  image_id = "ami-0f60b09eab2ef8366"
  instance_type = "${var.instance_type}"
  security_groups = ["${aws_security_group.instance.id}"]
  user_data = "${data.template_file.user_data.rendered}"

  lifecycle {
    create_before_destroy = true
  }
}

data "template_file" "user_data" {
  template = "${file("${path.module}/user-data.sh")}"

  vars {
    server_port = "${var.server_port}"
    db_address = "${data.terraform_remote_state.db.address}"
    db_port = "${data.terraform_remote_state.db.port}"
  }
}


resource "aws_autoscaling_group" "example" {
  launch_configuration = "${aws_launch_configuration.example.id}"
  availability_zones = ["${data.aws_availability_zones.all.names}"]


  load_balancers = ["${aws_elb.example.name}"]
  health_check_type = "ELB"

  max_size = "${var.max_size}"
  min_size = "${var.min_size}"
  tag {
    key = "Name"
    propagate_at_launch = true
    value = "terraform-asg-example"
  }
}


//Security group to permit access to port 80
//Allow healthcheck on egress

resource "aws_security_group" "elb" {
  name = "${var.cluster_name}-elb"
}

resource "aws_security_group_rule" "allow_http_inbound"{
  type = "ingress"
  security_group_id = "${aws_security_group.elb.id}"
  from_port = 80
  to_port = 80
  protocol = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_security_group_rule" "allow_all_outbound" {
  from_port = 0
  protocol = "-1"
  security_group_id = "${aws_security_group.elb.id}"
  to_port = 0
  type = "egress"
  cidr_blocks = ["0.0.0.0/0"]
}

//Create elb to receive HTTP requests on port 80
resource "aws_elb" "example" {
  name = "terraform-asg-example"
  availability_zones = ["${data.aws_availability_zones.all.names}"]
  security_groups = ["${aws_security_group.elb.id}"]

  "listener" {
    instance_port = "${var.server_port}"
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  //Health check block sends HTTP request every 30 seconds to the "/" URL of each of the EC2 instancesin the ASG
  health_check {
    healthy_threshold = 2
    interval = 30
    target = "HTTP:${var.server_port}/"
    timeout = 3
    unhealthy_threshold = 2
  }
}


