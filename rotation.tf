resource "aws_cloudwatch_log_group" "render_secrets" {
  name              = local.cw_log_group_name
  retention_in_days = 365
  tags              = local.resource_tags
}

resource "aws_cloudwatch_event_rule" "ssm_param_change" {
  name        = "${local.resource_name}-ssm-param-change"
  description = "Fires render-secrets when any /terrateam/* SSM parameter changes"
  tags        = local.resource_tags

  event_pattern = jsonencode({
    source      = ["aws.ssm"]
    detail-type = ["Parameter Store Change"]
    detail = {
      name = [for k, v in var.user_data_inputs : v]
    }
  })
}

resource "aws_iam_role" "eventbridge_run_command" {
  name = "${local.resource_name}-eventbridge-run-command"
  tags = local.resource_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_run_command" {
  name = "${local.resource_name}-eventbridge-run-command"
  role = aws_iam_role.eventbridge_run_command.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "ssm:SendCommand"
      Resource = [
        "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
        aws_instance.this.arn,
      ]
    }]
  })
}

resource "aws_cloudwatch_event_target" "run_render_secrets" {
  rule     = aws_cloudwatch_event_rule.ssm_param_change.name
  arn      = "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
  role_arn = aws_iam_role.eventbridge_run_command.arn

  run_command_targets {
    key    = "InstanceIds"
    values = [aws_instance.this.id]
  }

  # Input becomes the AWS-RunShellScript document's Parameters. SSM validates
  # strictly; including SendCommand-level fields like CloudWatchOutputConfig
  # here causes the API call to be rejected as an unknown parameter. Rotation
  # output reaches CW via the same file-based pipeline as boot output
  # (systemd → /var/log/terrateam-render-secrets.log → CW Agent).
  input = jsonencode({
    commands = ["systemctl start terrateam-render-secrets.service"]
  })
}
