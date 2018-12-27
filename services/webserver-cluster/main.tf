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

//Uses concat to combine two or more lists into a single list
resource "aws_launch_configuration" "example" {
  image_id = "ami-0f60b09eab2ef8366"
  instance_type = "${var.instance_type}"
  security_groups = ["${aws_security_group.instance.id}"]
  user_data = "${element(concat(data.template_file.user_data.*.rendered,data.template_file.user_data_new.*.rendered),0)}"

  lifecycle {
    create_before_destroy = true
  }
}


//Now using count and interpolation to hack an if/else statement
//if enable_new_user is false the user-data.sh script will be used
data "template_file" "user_data" {
  count = "${1 - var.enable_new_user_data}"
  template = "${file("${path.module}/user-data.sh")}"

  vars {
    server_port = "${var.server_port}"
    db_address = "${data.terraform_remote_state.db.address}"
    db_port = "${data.terraform_remote_state.db.port}"
  }
}

//Else if enable_user_data is true the user-data-new.sh script will be used
data "template_file" "user_data_new" {
  count = "${var.enable_new_user_data}"
  template = "${file("${path.module/user-data-new.sh}")}"
  vars {
    server_port = "${var.server_port}"
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

//Create autoscaling schedule
//Demonstrate using output values from module
resource "aws_autoscaling_schedule" "scale_out_during_business_hours" {
  count = "${var.enable_autoscaling}"

  autoscaling_group_name = "${aws_autoscaling_group.example.name}"
  scheduled_action_name = "scale-out-during-business-hours"
  min_size = 2
  max_size = 10
  desired_capacity = 10
  recurrence = "0 9 * * *"
}

//Demonstrate using output values from module
resource "aws_autoscaling_schedule" "scale_in_at_night" {
  count = "${var.enable_autoscaling}"

  autoscaling_group_name = "${aws_autoscaling_group.example.name}"
  scheduled_action_name = "scale-in-at-night"
  min_size = 2
  max_size = 10
  desired_capacity = 2
  recurrence = "0 17 * * *"
}

//Demonstrate more complicated if statements using complicate count parameter
//Extracts the first character from var.instance_typem if it is a t it set count to 1 otherwise it sets it to 0.
//Alarm will only be created for instance types that actually support CPUCreditBalance metric
resource "aws_cloudwatch_metric_alarm" "low_cpu_credit_balance" {
  count = "${format("%.1s", var.instance_type)  == "t" ? 1 : 0}"

  dimensions {
    AutoScalingGroupName = "${aws_autoscaling_group.example.name}"
  }

  alarm_name = "${var.cluster_name}-low-cpu-credit-balance"
  comparison_operator = "LessThanThreshold"
  evaluation_periods = 1
  metric_name = "CPUCreditBalance"
  namespace = "AWS/EC2"
  period = 300
  threshold = 10
  unit = "Count"
  statistic = "Minimum"
}

