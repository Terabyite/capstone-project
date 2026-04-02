output "kops_state_bucket" {
  value = aws_s3_bucket.kops_state.bucket
}

output "terraform_state_bucket" {
  value = aws_s3_bucket.terraform_state.bucket
}

output "terraform_locks_table" {
  value = aws_dynamodb_table.terraform_locks.name
}

output "etcd_backups_bucket" {
  value = aws_s3_bucket.etcd_backups.bucket
}
