#!/usr/bin/env python3
"""
upload.py — Upload PDFs to reMarkable Cloud via their web app API.

Usage:
    python upload.py <path_to_pdf> [--parent-id FOLDER_ID] [--cookie-file COOKIE_FILE] [-f, --fetch-cookies]

Authentication:
    The script needs your reMarkable session cookies. You can provide them in one
    of two ways:

    1. Environment variable:  export REMARKABLE_COOKIES='appSession.0=...; appSession.1=...'
    2. Cookie file:           python remarkable_upload.py file.pdf --cookie-file cookies.txt

    The cookie file should contain the raw Cookie header value (the whole string).
    At minimum you need the appSession.0 and appSession.1 cookies. You can grab
    them from your browser's DevTools → Application → Cookies for app.remarkable.com.

Steps performed:
    1. POST GraphQL mutation GenerateUploadUrl  → gets a signed GCS upload URL + gcsPath
    2. PUT  the PDF binary to the signed GCS URL
    3. POST GraphQL mutation CompleteUpload      → finalizes the upload, returns a document ID
"""

import argparse
import json
import os
import sys
import re
import requests
from pathlib import Path
from urllib.parse import urlparse
from dotenv import load_dotenv
from playwright.sync_api import Playwright, sync_playwright, expect

load_dotenv()

# ─── Configuration ───────────────────────────────────────────────────────────

GRAPHQL_ENDPOINT = "https://app.remarkable.com/api/graphql"

GRAPHQL_GENERATE_UPLOAD_URL = """
mutation GenerateUploadUrl($input: GenerateUploadUrlInput!) {
  generateUploadUrl(input: $input) {
    uploadUrl
    gcsPath
    uploadToken
    __typename
  }
}
""".strip()

GRAPHQL_COMPLETE_UPLOAD = """
mutation CompleteUpload($input: CompleteUploadInput!) {
  completeUpload(input: $input)
}
""".strip()

COMMON_HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0",
    "Accept": "*/*",
    "Accept-Language": "en-US,en;q=0.9",
    "Referer": "https://app.remarkable.com/",
    "Origin": "https://app.remarkable.com",
    "content-type": "application/json",
}


# ─── Helpers ─────────────────────────────────────────────────────────────────

def get_cookies(args) -> str:
    """Resolve the cookie string from args or environment."""
    if args.fetch_cookies:
        with sync_playwright() as playwright:
            cookies = fetch_cookies(playwright)
            if not cookies:
                print("Unable to fetch cookies...")
                sys.exit(1)
            return cookies

    if args.cookie_file:
        cookie_path = Path(args.cookie_file)
        if not cookie_path.exists():
            print(f"ERROR: Cookie file not found: {cookie_path}", file=sys.stderr)
            sys.exit(1)
        return cookie_path.read_text().strip()

    env_val = os.environ.get("REMARKABLE_COOKIES", "").strip()
    if env_val:
        return env_val

    print(
        "ERROR: No cookies provided.\n"
        "Set REMARKABLE_COOKIES env var or pass --cookie-file.\n"
        "See --help for details.",
        file=sys.stderr,
    )
    sys.exit(1)

def fetch_cookies(playwright: Playwright) -> str:
    RM_USERNAME = os.getenv('RM_USERNAME')
    RM_PASSWORD = os.getenv('RM_PASSWORD')
    
    browser = playwright.chromium.launch(headless=True)
    context = browser.new_context()
    page = context.new_page()
    page.goto("https://app.remarkable.com")
    page.get_by_role("textbox", name="Email address").click()
    page.get_by_role("textbox", name="Email address").fill(RM_USERNAME)
    page.get_by_role("button", name="Continue", exact=True).click()
    page.get_by_role("textbox", name="Password").click()
    page.get_by_role("textbox", name="Password").fill(RM_PASSWORD)
    page.get_by_role("button", name="Continue").click()
    page.get_by_test_id("CookieConsentRejectButton").click()

    # ---------------------

    cookies = context.cookies()
    session_cookies = [c for c in cookies if c["name"].startswith("appSession")]
    cookie_str = "; ".join(f'{c["name"]}={c["value"]}' for c in session_cookies)

    print(f"✓ Got cookies:")
    for c in session_cookies:
        print(f"{c['name']}: {c['value'][:15]}...")
    print()

    context.close()
    browser.close()
    
    with open('rm_cookies.txt', 'w') as f:
        f.write(cookie_str)

    return cookie_str

def graphql_request(session: requests.Session, operation_name: str, query: str, variables: dict) -> dict:
    """Send a GraphQL request and return the parsed response data."""
    payload = [
        {
            "operationName": operation_name,
            "variables": variables,
            "query": query,
        }
    ]

    resp = session.post(GRAPHQL_ENDPOINT, json=payload, headers=COMMON_HEADERS)
    resp.raise_for_status()

    body = resp.json()
    # Response is a JSON array with one element
    if isinstance(body, list):
        body = body[0]

    if "errors" in body:
        print(f"GraphQL errors: {json.dumps(body['errors'], indent=2)}", file=sys.stderr)
        sys.exit(1)

    return body["data"]


# ─── Step Functions ──────────────────────────────────────────────────────────

def step1_generate_upload_url(session: requests.Session, content_length: int) -> tuple[str, str, str]:
    """
    Step 1: Request a signed upload URL from reMarkable.
    Returns (upload_url, gcs_path, uploadToken).
    """
    print("Step 1: Requesting upload URL...")

    variables = {
        "input": {
            "contentType": "application/pdf",
            "contentLength": content_length,
        }
    }

    data = graphql_request(session, "GenerateUploadUrl", GRAPHQL_GENERATE_UPLOAD_URL, variables)
    result = data["generateUploadUrl"]

    upload_url = result["uploadUrl"]
    gcs_path = result["gcsPath"]
    upload_token = result["uploadToken"]

    print(f"  ✓ Got upload URL (expires in ~5 min)")
    print(f"  ✓ GCS path: {gcs_path}")
    print(f"  ✓ Upload token: {upload_token[:15]}...")

    return upload_url, gcs_path, upload_token


def step2_upload_file(session: requests.Session, upload_url: str, file_data: bytes) -> None:
    """
    Step 2: PUT the raw PDF bytes to the signed GCS URL.
    """
    print("Step 2: Uploading PDF to GCS...")

    headers = {
        "Content-Type": "application/pdf",
        "Content-Length": str(len(file_data)),
        "Origin": "https://app.remarkable.com",
    }

    resp = requests.put(upload_url, data=file_data, headers=headers)
    resp.raise_for_status()

    print(f"  ✓ Upload complete (HTTP {resp.status_code})")


def step3_complete_upload(
        session: requests.Session, gcs_path: str, upload_token: str, file_name: str, parent_id: str = ""
) -> str:
    """
    Step 3: Tell reMarkable the upload is done.
    Returns the new document ID.
    """
    print("Step 3: Completing upload...")

    variables = {
        "input": {
            "gcsPath": gcs_path,
            "fileName": file_name,
            "contentType": "application/pdf",
            "parentId": parent_id,
            "uploadToken": upload_token 
        }
    }

    data = graphql_request(session, "CompleteUpload", GRAPHQL_COMPLETE_UPLOAD, variables)
    doc_id = data["completeUpload"]

    print(f"  ✓ Upload finalized! Document ID: {doc_id}")
    return doc_id


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Upload a PDF to reMarkable Cloud via the web app API.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("pdf", help="Path to the PDF file to upload")
    parser.add_argument(
        "--parent-id",
        default="",
        help="Folder ID to upload into (empty string = root). Default: root.",
    )
    parser.add_argument(
        "--cookie-file",
        default=None,
        help="Path to a text file containing the Cookie header value.",
    )
    parser.add_argument(
        "--step",
        type=int,
        choices=[1, 2, 3],
        default=None,
        help="Run only a specific step (for debugging). Omit to run all steps.",
    )
    parser.add_argument(
        "--upload-url",
        default=None,
        help="(Step 2 only) Provide a previously generated upload URL.",
    )
    parser.add_argument(
        "--gcs-path",
        default=None,
        help="(Step 3 only) Provide the GCS path from step 1.",
    )
    parser.add_argument(
        "--upload-token",
        default=None,
        help="(Step 3 only) Provide the upload token from step 1.",
    )
    parser.add_argument(
        "-f",
        "--fetch-cookies",
        action="store_true",
        help="Automatically fetch cookies via playwright. (MUST HAVE .env FILE SET)."
    )
    args = parser.parse_args()

    # Validate the PDF path
    pdf_path = Path(args.pdf)
    if not pdf_path.exists():
        print(f"ERROR: File not found: {pdf_path}", file=sys.stderr)
        sys.exit(1)
    if not pdf_path.suffix.lower() == ".pdf":
        print(f"WARNING: File does not have .pdf extension: {pdf_path}", file=sys.stderr)

    file_data = pdf_path.read_bytes()
    file_name = pdf_path.name
    print(f"File: {file_name} ({len(file_data):,} bytes)")
    print()

    # Set up session with cookies
    cookie_str = get_cookies(args)
    session = requests.Session()
    session.headers["Cookie"] = cookie_str

    # Run steps
    if args.step == 1:
        upload_url, gcs_path, upload_token  = step1_generate_upload_url(session, len(file_data))
        print(f"\n--- Save these for subsequent steps ---")
        print(f"Upload URL: {upload_url}")
        print(f"GCS Path:   {gcs_path}")
        print(f"Upload token: {upload_token}")

    elif args.step == 2:
        if not args.upload_url:
            print("ERROR: --upload-url is required for --step 2", file=sys.stderr)
            sys.exit(1)
        step2_upload_file(session, args.upload_url, file_data)

    elif args.step == 3:
        if not args.gcs_path:
            print("ERROR: --gcs-path is required for --step 3", file=sys.stderr)
            sys.exit(1)
        if not args.upload_token:
            print("ERROR: --upload-token is required for --step 3", file=sys.stderr)
        step3_complete_upload(session, args.gcs_path, upload_token, file_name, args.parent_id)

    else:
        # Run all steps
        upload_url, gcs_path, upload_token = step1_generate_upload_url(session, len(file_data))
        print()
        step2_upload_file(session, upload_url, file_data)
        print()
        step3_complete_upload(session, gcs_path, upload_token, file_name, args.parent_id)

    print("\nDone!")


if __name__ == "__main__":
    main()
