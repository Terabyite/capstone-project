output "kops_user_arn" {
  value = aws_iam_user.kops.arn
}

output "kops_access_key_id" {
  value     = aws_iam_access_key.kops.id
  sensitive = true
}

output "kops_secret_access_key" {
  value     = aws_iam_access_key.kops.secret
  sensitive = true
}

output "ebs_csi_policy_arn" {
  value = aws_iam_policy.ebs_csi.arn
}
