variable "region" {
  type    = string
  default = "us-east-1" # the course bucket is here; copying inside one region is free
}

variable "name" {
  type        = string
  description = "Prefix of every resource and the PROJECT_NAME tag."
  default     = "ooad-lab8"
}

variable "streaming_enabled" {
  type        = bool
  description = "Part 3: the Kinesis stream, Firehose and the alert consumer. They cost per hour, so switch them off when done."
  default     = false
}

variable "alert_email" {
  type        = string
  description = "Who gets the SNS alert (a personal address: passed as TF_VAR_alert_email, not committed)."
  default     = ""
}

variable "failure_rate_threshold" {
  type        = number
  description = "Alert when a merchant's share of failed payments in one window is above this."
  default     = 0.3
}

variable "alert_min_payments" {
  type        = number
  description = "Ignore merchants with fewer finished payments than this in a window (too few to judge)."
  default     = 50
}

variable "window_seconds" {
  type        = number
  description = "Tumbling window of the alert consumer."
  default     = 60
}
