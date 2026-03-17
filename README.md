# MigrateReady - GCP Service Account Setup

Automates GCP service account creation and configuration for CloudM Migrate projects.

## What it does

- Creates a dedicated GCP project for the migration
- Enables all 13 required APIs (auto-resolves Terms of Service acceptance)
- Creates a service account with Owner role
- Enables domain-wide delegation (GCP side)
- Configures the OAuth consent screen (Internal)
- Downloads the JSON key as `<domain>-serviceaccount.json`
- Auto-resolves org policy errors blocking key creation (both managed and classic constraints)
- Generates a one-click DWD link for Admin Console (Client ID + 36 scopes pre-populated)

## Quick Start

Click the button below to open the script directly in Google Cloud Shell:

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://shell.cloud.google.com/cloudshell/editor?cloudshell_git_repo=https://github.com/kotharihozefa/migrateready.git&cloudshell_git_branch=main&cloudshell_workspace=.&cloudshell_tutorial=TUTORIAL.md)

Once Cloud Shell opens:

```bash
cd migrateready && chmod +x migrateready-setup.sh && ./migrateready-setup.sh
```

## Manual Steps After Script

1. **Domain-Wide Delegation** — Click the one-click DWD link shown by the script, then click Authorize
2. **Chat API Configuration** — Configure app settings using the link and values shown by the script
3. **Drive SDK** — Verify it is enabled in Google Admin Console

## Requirements

- Google account with **Super Admin** access
- GCP Terms of Service accepted
- Billing account (optional, needed for some APIs)

## Author

Hozefa Kothari
