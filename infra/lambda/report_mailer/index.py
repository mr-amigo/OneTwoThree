import os
import urllib.parse
from email.message import EmailMessage

import boto3

s3 = boto3.client("s3")
sesv2 = boto3.client("sesv2")


def handler(event, context):
    records = event.get("Records", [])
    print(f"trigger=s3 records={len(records)}")
    sender = os.environ["REPORT_SENDER_EMAIL"]
    recipient = os.environ["REPORT_RECIPIENT_EMAIL"]
    sent = []

    for record in records:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        if not (key.startswith("reports/") and key.endswith(".csv")):
            print(f"trigger=s3 status=skipped key={key}")
            continue

        week = key.removeprefix("reports/").removesuffix(".csv")
        obj = s3.get_object(Bucket=bucket, Key=key)
        csv_bytes = obj["Body"].read()

        msg = EmailMessage()
        msg["Subject"] = f"Weekly Meetings Report - {week}"
        msg["From"] = sender
        msg["To"] = recipient
        msg.set_content(
            f"Attached is the weekly meetings report for {week} (s3://{bucket}/{key}).\n"
        )
        msg.add_attachment(
            csv_bytes,
            maintype="text",
            subtype="csv",
            filename=f"{week}.csv",
        )

        resp = sesv2.send_email(
            FromEmailAddress=sender,
            Destination={"ToAddresses": [recipient]},
            Content={"Raw": {"Data": msg.as_bytes()}},
        )
        msg_id = resp.get("MessageId", "")
        print(
            f"trigger=s3 status=sent week={week} bucket={bucket} key={key} "
            f"recipient={recipient} message_id={msg_id}"
        )
        sent.append({"week": week, "key": key, "message_id": msg_id})

    return {"status": "ok", "trigger": "s3", "sent": sent}
