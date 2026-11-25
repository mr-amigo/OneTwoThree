# /// script
# requires-python = ">=3.12"
# dependencies = ["boto3"]
# ///
"""Print a one-hour AWS console sign-in URL limited to Lab 8 (Athena, Glue, the lab bucket).

Uses the IAM user's keys from .env (GetFederationToken) and the console federation endpoint, so the
Athena query editor can be opened for the screenshot without the account's password. The session
policy narrows the user's rights: it can only use Athena, read the Glue catalog and the lab bucket.
"""

import json
import urllib.parse
import urllib.request

import boto3

account = boto3.client("sts").get_caller_identity()["Account"]
bucket = f"ooad-lab8-{account}"
policy = {
    "Version": "2012-10-17",
    "Statement": [
        {"Effect": "Allow", "Action": ["athena:*"], "Resource": "*"},
        {"Effect": "Allow", "Action": ["glue:Get*", "glue:Search*", "glue:BatchGet*"], "Resource": "*"},
        {"Effect": "Allow", "Action": ["s3:ListAllMyBuckets", "s3:GetBucketLocation"], "Resource": "*"},
        {"Effect": "Allow", "Action": "s3:*", "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"]},
    ],
}
creds = boto3.client("sts").get_federation_token(Name="lab8-athena", Policy=json.dumps(policy), DurationSeconds=3600)[
    "Credentials"
]
session = json.dumps(
    {"sessionId": creds["AccessKeyId"], "sessionKey": creds["SecretAccessKey"], "sessionToken": creds["SessionToken"]}
)
with urllib.request.urlopen(
    "https://signin.aws.amazon.com/federation?Action=getSigninToken&Session=" + urllib.parse.quote(session)
) as r:
    token = json.load(r)["SigninToken"]
destination = "https://us-east-1.console.aws.amazon.com/athena/home?region=us-east-1#/query-editor"
print(
    "https://signin.aws.amazon.com/federation?Action=login&Issuer=lab8&Destination="
    + urllib.parse.quote(destination, safe="")
    + "&SigninToken="
    + token
)
