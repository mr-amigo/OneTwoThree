# Was infra/cognito.yaml (Lab 4): a Cognito user pool (Essentials tier) with self sign-up and email
# verification, a public app client for the SPA, a managed login (version 2) domain, and Google as an
# identity provider. One sign-in page offers both email + password and Continue with Google.

resource "aws_cognito_user_pool" "main" {
  name = "${var.project_name}-users"

  # Managed login (version 2) needs the Essentials tier; the first 10,000 monthly users are free.
  user_pool_tier = "ESSENTIALS"

  # Users sign in with their email; Cognito sends a code to verify it on sign-up.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_numbers                  = true
    require_uppercase                = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Cognito's own sender (about 50 emails a day), enough until SES is set up.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Changing the schema of an existing pool forces a new pool, and a new pool has no users.
  # `name` is a standard optional attribute, so only email is declared.
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = "0"
      max_length = "2048"
    }
  }

  # Every account that signed up since Lab 4 lives here. Terraform refuses any plan that destroys it.
  lifecycle {
    prevent_destroy = true
  }
}

# Prefix domain for the OAuth endpoints and the managed login page. The prefix must be unique across
# AWS, hence the account ID. Google's OAuth client points at this domain:
# https://<project_name>-<account id>.auth.<region>.amazoncognito.com
resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${var.project_name}-${local.account_id}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# Without branding, a version 2 domain has no sign-in page to show. Cognito's own look is enough.
resource "aws_cognito_managed_login_branding" "main" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.web.id
  use_cognito_provided_values = true

  depends_on = [aws_cognito_user_pool_domain.main]
}

resource "aws_cognito_identity_provider" "google" {
  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  # Cognito fills in Google's endpoints itself; they are listed so the plan has nothing to change.
  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = local.secret["google_client_secret"]
    authorize_scopes              = "openid email profile"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }
}

# Public client (no secret: a browser cannot keep one; PKCE protects the code exchange instead).
# The browser only talks to managed login and the token endpoint; the backend verifies the tokens.
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project_name}-web"
  user_pool_id = aws_cognito_user_pool.main.id

  # No generate_secret: the client has none, and setting the argument on an existing client forces
  # a new one (new client ID, every signed-in user signed out).

  # Managed login signs users in itself; the app only refreshes tokens.
  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  id_token_validity      = 60
  access_token_validity  = 60
  refresh_token_validity = 30

  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }

  # A client must not name a provider before it exists: the reference orders the two.
  supported_identity_providers = ["COGNITO", aws_cognito_identity_provider.google.provider_name]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]

  # Where managed login may send users back: every origin the API allows.
  callback_urls = [for origin in local.cors_origins : "${origin}/auth/callback"]
  logout_urls   = [for origin in local.cors_origins : "${origin}/"]
}
