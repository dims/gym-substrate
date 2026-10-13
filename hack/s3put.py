# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Upload one file to an S3-compatible endpoint.

    uv run --no-project --with boto3 python hack/s3put.py FILE BUCKET KEY ENDPOINT_URL

Credentials come from AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY.
"""

import sys

import boto3
import botocore.config


def main() -> None:
    path, bucket, key, endpoint = sys.argv[1:5]
    client = boto3.client(
        "s3",
        endpoint_url=endpoint,
        region_name="us-east-1",
        config=botocore.config.Config(retries={"max_attempts": 10}, s3={"addressing_style": "path"}),
    )
    client.upload_file(path, bucket, key)
    head = client.head_object(Bucket=bucket, Key=key)
    print(f"uploaded {key} ({head['ContentLength']} bytes)")


if __name__ == "__main__":
    main()
