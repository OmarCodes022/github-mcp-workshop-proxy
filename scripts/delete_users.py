#!/usr/bin/env python3
"""
Delete all IAM users in the workshop-participants group and remove the group.
Run this after the workshop for cleanup.

Usage:
    AWS_PROFILE=epitech python scripts/delete_users.py
"""

import sys

import boto3
from botocore.exceptions import ClientError

GROUP = "workshop-participants"
BEDROCK_POLICY_ARN = "arn:aws:iam::aws:policy/AmazonBedrockFullAccess"
AGENTCORE_POLICY_NAME = "workshop-agentcore-access"


def delete_user(iam, username):
    # Remove from group
    try:
        iam.remove_user_from_group(GroupName=GROUP, UserName=username)
    except ClientError:
        pass

    # Delete login profile
    try:
        iam.delete_login_profile(UserName=username)
    except ClientError:
        pass

    # Delete access keys
    keys = iam.list_access_keys(UserName=username)["AccessKeyMetadata"]
    for key in keys:
        iam.delete_access_key(UserName=username, AccessKeyId=key["AccessKeyId"])

    iam.delete_user(UserName=username)
    print(f"  [-] {username}")


def main():
    iam = boto3.client("iam")

    try:
        members = iam.get_group(GroupName=GROUP)["Users"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            print(f"Group {GROUP} does not exist. Nothing to delete.")
            sys.exit(0)
        raise

    if not members:
        print(f"No users in {GROUP}.")
    else:
        print(f"Deleting {len(members)} user(s)...")
        for user in members:
            delete_user(iam, user["UserName"])

    # Detach managed policy
    try:
        iam.detach_group_policy(GroupName=GROUP, PolicyArn=BEDROCK_POLICY_ARN)
    except ClientError:
        pass

    # Delete inline policy
    try:
        iam.delete_group_policy(GroupName=GROUP, PolicyName=AGENTCORE_POLICY_NAME)
    except ClientError:
        pass

    # Delete group
    try:
        iam.delete_group(GroupName=GROUP)
        print(f"Deleted group: {GROUP}")
    except ClientError as e:
        print(f"Could not delete group: {e}")

    print("Cleanup complete.")


if __name__ == "__main__":
    main()
