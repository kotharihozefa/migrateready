# MigrateReady - GCP Setup Tutorial

## Overview

This tutorial walks you through setting up a GCP service account for CloudM Migrate using MigrateReady.

**Time to complete**: 5-8 minutes

Click **Start** to begin.

## Run the Setup Script

Make the script executable and run it:

```bash
chmod +x migrateready-setup.sh && ./migrateready-setup.sh
```

The script will prompt you for:

- **Domain name** (e.g., example.com)
- **Admin email** (e.g., admin@example.com)
- **GCP Organization ID** (optional — press Enter to skip)
- **Billing Account ID** (optional — press Enter to skip)
- **Output directory** (press Enter for default)

## Complete Manual Steps

After the script finishes, three manual steps remain:

1. **Domain-Wide Delegation**: Click the one-click DWD link shown in the terminal, then click **Authorize**
2. **Chat API Configuration**: Open the Chat API link and configure the settings as shown by the script
3. **Drive SDK**: Verify it is enabled in Admin Console > Apps > Google Workspace > Drive and Docs

## Done!

Your GCP service account is ready for CloudM Migrate.

**Key files saved to your home directory:**
- `<domain>-serviceaccount.json` — Upload this to CloudM
- `dwd-setup-<domain>.txt` — Reference file with DWD link and scopes

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>
