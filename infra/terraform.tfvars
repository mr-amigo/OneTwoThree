# Non-secret values only. Secrets (google_client_secret, openai_api_key) and personal email addresses
# (report_sender_email, report_recipient_email, budget_alert_email) are SSM SecureString parameters
# under /meetings/terraform/, written by `make infra-secrets`.

project_name = "meetings"
region       = "us-east-1"
architecture = "arm64"

google_client_id = "309082329870-kojno6aucqq1vckghq1cgotvdha3rgv3.apps.googleusercontent.com"

parser_provider = "openai"
parser_model    = "gpt-5.4-mini"
