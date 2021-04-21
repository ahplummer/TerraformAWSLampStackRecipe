output "elb_dns_name" {
  value = aws_elb.web_elb.dns_name
}
output "primaryA_rds_endpoint" {
  value = aws_db_instance.primaryA.endpoint
}