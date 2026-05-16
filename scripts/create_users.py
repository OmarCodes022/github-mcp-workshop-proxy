#!/usr/bin/env python3
"""
Create IAM users for workshop participants.

Usage:
    AWS_PROFILE=epitech python scripts/create_users.py participants.txt

Input: plain text file, one participant name per line.
Output: workshop_credentials.csv with username, password, console URL.
"""

import csv
import json
import re
import secrets
import string
import sys

import boto3
from botocore.exceptions import ClientError

import os

GROUP = "workshop-participants"
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
BEDROCK_POLICY_ARN = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
AGENTCORE_POLICY_NAME = "workshop-agentcore-access"
AGENTCORE_POLICY = json.dumps({
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Action": ["bedrock-agentcore:*", "secretsmanager:*"],
        "Resource": "*",
    }],
})
OUTPUT_CSV = "workshop_credentials.csv"
PASSWORD_CHARS = string.ascii_letters + string.digits + "!@#$%^&*"


def random_password(length=16):
    return "".join(secrets.choice(PASSWORD_CHARS) for _ in range(length))


def to_username(name, existing):
    slug = re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-")
    base = f"workshop-{slug}"
    username = base
    n = 2
    while username in existing:
        username = f"{base}-{n}"
        n += 1
    return username


def ensure_group(iam, account_id):
    try:
        iam.create_group(GroupName=GROUP)
        print(f"  Created group: {GROUP}")
    except ClientError as e:
        if e.response["Error"]["Code"] == "EntityAlreadyExists":
            print(f"  Group already exists: {GROUP}")
        else:
            raise

    # Attach managed Bedrock policy
    try:
        iam.attach_group_policy(GroupName=GROUP, PolicyArn=BEDROCK_POLICY_ARN)
    except ClientError as e:
        if e.response["Error"]["Code"] != "EntityAlreadyExists":
            raise

    # Put inline policy for AgentCore + Secrets Manager
    iam.put_group_policy(
        GroupName=GROUP,
        PolicyName=AGENTCORE_POLICY_NAME,
        PolicyDocument=AGENTCORE_POLICY,
    )
    print(f"  Policies attached to {GROUP}")


def create_user(iam, username, console_url):
    try:
        iam.create_user(UserName=username)
    except ClientError as e:
        if e.response["Error"]["Code"] == "EntityAlreadyExists":
            return None, "skipped (already exists)"
        raise

    iam.add_user_to_group(GroupName=GROUP, UserName=username)

    password = random_password()
    iam.create_login_profile(
        UserName=username,
        Password=password,
        PasswordResetRequired=False,
    )
    return password, "created"


def main():
    if len(sys.argv) != 2:
        print("Usage: python scripts/create_users.py <participants.txt>")
        sys.exit(1)

    participants_file = sys.argv[1]
    try:
        with open(participants_file) as f:
            names = [line.strip() for line in f if line.strip()]
    except FileNotFoundError:
        print(f"ERROR: file not found: {participants_file}")
        sys.exit(1)

    if not names:
        print("ERROR: participant list is empty")
        sys.exit(1)

    iam = boto3.client("iam")
    sts = boto3.client("sts")

    account_id = sts.get_caller_identity()["Account"]
    console_url = f"https://{account_id}.signin.aws.amazon.com/console?region={AWS_REGION}"

    print(f"Account : {account_id}")
    print(f"Console : {console_url}")
    print(f"Users   : {len(names)}")
    print()

    ensure_group(iam, account_id)
    print()

    existing = set()
    rows = []
    created = skipped = 0

    for name in names:
        username = to_username(name, existing)
        existing.add(username)
        password, status = create_user(iam, username, console_url)
        if status == "created":
            created += 1
            rows.append({"name": name, "username": username, "password": password, "account_id": account_id, "console_url": console_url})
            print(f"  [+] {username}")
        else:
            skipped += 1
            print(f"  [!] {username} - {status}")

    if rows:
        with open(OUTPUT_CSV, "w", newline="") as f:
            writer = csv.DictWriter(f, fieldnames=["name", "username", "password", "account_id", "console_url"])
            writer.writeheader()
            writer.writerows(rows)

    print()
    print(f"Done. Created: {created}, Skipped: {skipped}")
    if rows:
        print(f"Credentials written to: {OUTPUT_CSV}")


if __name__ == "__main__":
    main()
