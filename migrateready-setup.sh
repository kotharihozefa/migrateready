#!/bin/bash
#
# MigrateReady - GCP Service Account & API Setup Script
# =========================================================
# Automates the complete GCP setup for CloudM Migrate projects:
#   1. Creates a dedicated GCP project
#   2. Creates a service account with Owner role
#   3. Enables all required APIs (including Google Chat API)
#   4. Configures OAuth consent screen (Internal)
#   5. Enables domain-wide delegation on the service account
#   6. Downloads JSON key and renames to <domain>-serviceaccount.json
#   7. Outputs ready-to-paste DWD scopes and Chat API config instructions
#
# Prerequisites:
#   - gcloud CLI installed (https://cloud.google.com/sdk/docs/install)
#   - Authenticated as a Super Admin: gcloud auth login
#   - Billing account linked (required for some APIs)
#
# Usage:
#   chmod +x migrateready-setup.sh
#   ./migrateready-setup.sh
#
# Author: Hozefa Kothari
# =========================================================

set -uo pipefail
# NOTE: We intentionally do NOT use 'set -e' because this script handles
# errors explicitly with if/else blocks. Using 'set -e' would cause silent
# exits on expected failures (e.g., gcloud commands that we want to catch).

# ─────────────────────────────────────────────
# PERSISTENT LOGGING
# ─────────────────────────────────────────────
# All script output is saved to a timestamped log file so that logs survive
# Cloud Shell disconnections or accidental terminal refreshes.
# Log file is saved in the same directory where the script is located.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${SCRIPT_DIR}/migrateready-${LOG_TIMESTAMP}.log"

# Use 'exec' with process substitution to tee all stdout and stderr to both
# the terminal AND the log file simultaneously.
exec > >(tee -a "$LOG_FILE") 2>&1

echo "═══════════════════════════════════════════════════════════"
echo "  Log file: ${LOG_FILE}"
echo "  All output is being saved automatically."
echo "  If your terminal disconnects, check this file for logs."
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─────────────────────────────────────────────
# DETECT ENVIRONMENT (Cloud Shell vs Local macOS)
# ─────────────────────────────────────────────
IS_CLOUD_SHELL=false
if [[ -n "${CLOUD_SHELL:-}" || -n "${DEVSHELL_PROJECT_ID:-}" ]]; then
    IS_CLOUD_SHELL=true
fi

# ─────────────────────────────────────────────
# PREREQUISITE CHECKS
# ─────────────────────────────────────────────
check_prerequisites() {
    local missing=0

    if ! command -v gcloud &> /dev/null; then
        echo "ERROR: gcloud CLI is not installed."
        echo "Install it from: https://cloud.google.com/sdk/docs/install"
        missing=1
    fi

    if ! command -v curl &> /dev/null; then
        echo "ERROR: curl is not installed."
        missing=1
    fi

    if [[ $missing -eq 1 ]]; then
        exit 1
    fi

    # Check if authenticated
    if ! gcloud auth print-access-token &> /dev/null; then
        echo "ERROR: Not authenticated with gcloud."
        echo "Run: gcloud auth login"
        exit 1
    fi

    if [[ "$IS_CLOUD_SHELL" == true ]]; then
        echo "Environment: Google Cloud Shell detected."
    else
        echo "Environment: Local machine detected."
    fi

    # Check if GCP Terms of Service have been accepted
    # A fresh GCP environment requires ToS acceptance before any API calls work
    echo "Checking GCP access..."
    GCP_CHECK_OUTPUT=$(gcloud projects list --limit=1 2>&1) || true

    if echo "$GCP_CHECK_OUTPUT" | grep -qi "terms of service\|ToS\|PERMISSION_DENIED\|must first accept\|agree to"; then
        echo ""
        echo -e "\033[1;33m╔══════════════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;33m║  ACTION REQUIRED: Accept GCP Terms of Service               ║\033[0m"
        echo -e "\033[1;33m╚══════════════════════════════════════════════════════════════╝\033[0m"
        echo ""
        echo "You need to accept the Google Cloud Terms of Service before"
        echo "this script can create projects and resources."
        echo ""

        GCP_CONSOLE_URL="https://console.cloud.google.com"

        if [[ "$IS_CLOUD_SHELL" == true ]]; then
            echo "Open this link in a new tab to accept the Terms of Service:"
            echo "  ${GCP_CONSOLE_URL}"
        elif command -v open &> /dev/null; then
            echo "Opening GCP Console in your browser..."
            open "$GCP_CONSOLE_URL"
        else
            echo "Open this URL in your browser:"
            echo "  ${GCP_CONSOLE_URL}"
        fi

        echo ""
        read -rp "Press Enter after accepting the Terms of Service to continue..."

        # Verify access after user accepts ToS
        GCP_RECHECK=$(gcloud projects list --limit=1 2>&1) || true
        if echo "$GCP_RECHECK" | grep -qi "terms of service\|ToS\|must first accept\|agree to"; then
            echo "ERROR: GCP access still blocked. Please ensure you have accepted"
            echo "the Terms of Service at ${GCP_CONSOLE_URL} and try again."
            exit 1
        fi
        echo "GCP Terms of Service accepted. Continuing..."
    else
        echo "GCP access verified."
    fi

    echo "Prerequisites check passed."
}

check_prerequisites

# ─────────────────────────────────────────────
# COLOR CODES
# ─────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─────────────────────────────────────────────
# CONFIGURATION DEFAULTS
# ─────────────────────────────────────────────
PROJECT_NAME="Cloudasta-Migration"
SERVICE_ACCOUNT_NAME="cloudasta-migration"
DISPLAY_NAME="Cloudasta-Migration"
CHAT_APP_NAME="Cloudasta-Migration"
KEY_FORMAT="json"

# ─────────────────────────────────────────────
# REQUIRED APIs FOR CLOUDM MIGRATE
# ─────────────────────────────────────────────
REQUIRED_APIS=(
    "serviceusage.googleapis.com"           # Service Usage API (meta-API — must be first)
    "iap.googleapis.com"                    # IAP API (required for OAuth consent screen)
    "orgpolicy.googleapis.com"              # Org Policy API (required for auto-resolving key creation policy)
    "admin.googleapis.com"                  # Admin SDK API
    "gmail.googleapis.com"                  # Gmail API
    "calendar-json.googleapis.com"          # Google Calendar API
    "drive.googleapis.com"                  # Google Drive API
    "people.googleapis.com"                 # Google People API
    "tasks.googleapis.com"                  # Tasks API
    "forms.googleapis.com"                  # Google Forms API
    "groupsmigration.googleapis.com"        # Groups Migration API
    "chat.googleapis.com"                   # Google Chat API
    "groupssettings.googleapis.com"         # Groups Settings API
)

# ─────────────────────────────────────────────
# STANDARD CLOUDM MIGRATE SCOPES (26 scopes — includes People API profile scopes for Contacts)
# ─────────────────────────────────────────────
STANDARD_SCOPES=(
    "https://www.googleapis.com/auth/admin.directory.resource.calendar"
    "https://www.googleapis.com/auth/gmail.settings.sharing"
    "https://mail.google.com/"
    "https://sites.google.com/feeds/"
    "https://www.googleapis.com/auth/admin.directory.group"
    "https://www.googleapis.com/auth/admin.directory.user"
    "https://www.googleapis.com/auth/apps.groups.migration"
    "https://www.googleapis.com/auth/calendar"
    "https://www.googleapis.com/auth/drive"
    "https://www.googleapis.com/auth/drive.appdata"
    "https://www.googleapis.com/auth/email.migration"
    "https://www.googleapis.com/auth/tasks"
    "https://www.googleapis.com/auth/forms"
    "https://www.googleapis.com/auth/gmail.settings.basic"
    "https://www.googleapis.com/auth/contacts"
    "https://www.googleapis.com/auth/contacts.other.readonly"
    "https://www.googleapis.com/auth/contacts.readonly"
    "https://www.googleapis.com/auth/directory.readonly"
    "https://www.googleapis.com/auth/userinfo.profile"
    "https://www.googleapis.com/auth/userinfo.email"
    "https://www.googleapis.com/auth/user.addresses.read"
    "https://www.googleapis.com/auth/user.birthday.read"
    "https://www.googleapis.com/auth/user.emails.read"
    "https://www.googleapis.com/auth/user.gender.read"
    "https://www.googleapis.com/auth/user.organization.read"
    "https://www.googleapis.com/auth/user.phonenumbers.read"
)

# ─────────────────────────────────────────────
# GOOGLE CHAT API SCOPES
# ─────────────────────────────────────────────
CHAT_SCOPES=(
    "https://www.googleapis.com/auth/chat.admin.spaces.readonly"
    "https://www.googleapis.com/auth/chat.admin.spaces"
    "https://www.googleapis.com/auth/chat.admin.memberships"
    "https://www.googleapis.com/auth/chat.bot"
    "https://www.googleapis.com/auth/chat.spaces"
    "https://www.googleapis.com/auth/chat.memberships"
    "https://www.googleapis.com/auth/chat.memberships.app"
    "https://www.googleapis.com/auth/chat.messages"
    "https://www.googleapis.com/auth/chat.import"
    "https://www.googleapis.com/auth/chat.customemojis"
)

# ─────────────────────────────────────────────
# HELPER FUNCTIONS
# ─────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_step() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[i]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[!]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

confirm_proceed() {
    echo ""
    read -rp "$(echo -e "${YELLOW}Continue? (y/n): ${NC}")" choice
    case "$choice" in
        y|Y ) return 0 ;;
        * ) echo -e "${RED}Aborted by user.${NC}"; exit 1 ;;
    esac
}

# ─────────────────────────────────────────────
# COLLECT USER INPUT
# ─────────────────────────────────────────────
print_header "MigrateReady - GCP Setup Script"

echo -e "${BOLD}This script will set up your CloudM Migrate GCP environment.${NC}"
echo ""

# Domain name (for key file naming)
read -rp "$(echo -e "${CYAN}Enter the domain name (e.g., example.com): ${NC}")" DEST_DOMAIN
if [[ -z "$DEST_DOMAIN" ]]; then
    print_error "Domain name cannot be empty."
    exit 1
fi

# Admin email address
read -rp "$(echo -e "${CYAN}Enter the admin email address (e.g., admin@${DEST_DOMAIN}): ${NC}")" ADMIN_EMAIL
if [[ -z "$ADMIN_EMAIL" ]]; then
    print_error "Admin email cannot be empty."
    exit 1
fi

# Organization ID (optional - for project placement)
read -rp "$(echo -e "${CYAN}Enter your GCP Organization ID (press Enter to skip): ${NC}")" ORG_ID

# Billing account (optional)
read -rp "$(echo -e "${CYAN}Enter your GCP Billing Account ID (press Enter to skip): ${NC}")" BILLING_ACCOUNT

# Output directory for the key file
read -rp "$(echo -e "${CYAN}Directory to save the key file [$(pwd)]: ${NC}")" OUTPUT_DIR
OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)}"

# Validate output directory exists
if [[ ! -d "$OUTPUT_DIR" ]]; then
    print_warn "Output directory '${OUTPUT_DIR}' does not exist."
    read -rp "$(echo -e "${CYAN}Create it? (y/n): ${NC}")" create_dir
    if [[ "$create_dir" == "y" || "$create_dir" == "Y" ]]; then
        mkdir -p "$OUTPUT_DIR"
        print_step "Directory created: ${OUTPUT_DIR}"
    else
        print_error "Output directory does not exist. Cannot save key file."
        exit 1
    fi
fi

# Sanitize domain for filenames (strip invalid characters, keep dots and hyphens)
DOMAIN_CLEAN=$(echo "$DEST_DOMAIN" | sed 's/[^a-zA-Z0-9._-]//g')
KEY_FILENAME="${DOMAIN_CLEAN}-serviceaccount.json"

echo ""
echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  Project Name:        ${GREEN}${PROJECT_NAME}${NC}"
echo -e "  Service Account:     ${GREEN}${SERVICE_ACCOUNT_NAME}${NC}"
echo -e "  Domain:              ${GREEN}${DEST_DOMAIN}${NC}"
echo -e "  Admin Email:         ${GREEN}${ADMIN_EMAIL}${NC}"
echo -e "  Key Filename:        ${GREEN}${KEY_FILENAME}${NC}"
echo -e "  Output Directory:    ${GREEN}${OUTPUT_DIR}${NC}"
[[ -n "$ORG_ID" ]] && echo -e "  Organization ID:     ${GREEN}${ORG_ID}${NC}"
[[ -n "$BILLING_ACCOUNT" ]] && echo -e "  Billing Account:     ${GREEN}${BILLING_ACCOUNT}${NC}"

confirm_proceed

# ─────────────────────────────────────────────
# STEP 1: CREATE GCP PROJECT
# ─────────────────────────────────────────────
print_header "Step 1: Creating GCP Project"

# Generate a unique project ID (must be 6-30 chars, lowercase, hyphens allowed)
PROJECT_ID="cloudasta-migration-$(date +%s | tail -c 7)"
print_info "Project ID: ${PROJECT_ID}"

CREATE_CMD="gcloud projects create ${PROJECT_ID} --name=\"${PROJECT_NAME}\""
[[ -n "$ORG_ID" ]] && CREATE_CMD+=" --organization=${ORG_ID}"

CREATE_OUTPUT=$(eval "$CREATE_CMD" 2>&1) && CREATE_SUCCESS=true || CREATE_SUCCESS=false

if [[ "$CREATE_SUCCESS" == true ]]; then
    print_step "GCP project '${PROJECT_NAME}' created successfully (ID: ${PROJECT_ID})"
else
    # Detect specific failure reasons
    if echo "$CREATE_OUTPUT" | grep -qi "quota"; then
        print_error "Project creation quota exceeded."
        print_info "GCP limits the number of projects you can create (typically 25)."
        print_info "Delete unused projects at: https://console.cloud.google.com/cloud-resource-manager"
    elif echo "$CREATE_OUTPUT" | grep -qi "already exists"; then
        print_error "A project with a similar ID already exists."
    else
        print_error "Failed to create project."
        print_info "Error: ${CREATE_OUTPUT}"
    fi
    echo ""
    read -rp "$(echo -e "${CYAN}Enter an existing project ID to use instead (or press Enter to exit): ${NC}")" EXISTING_PROJECT
    if [[ -n "$EXISTING_PROJECT" ]]; then
        PROJECT_ID="$EXISTING_PROJECT"
        print_info "Using existing project: ${PROJECT_ID}"
    else
        exit 1
    fi
fi

# Set the project as active and verify it exists
if gcloud config set project "$PROJECT_ID" 2>&1; then
    # Verify the project is accessible
    if gcloud projects describe "$PROJECT_ID" &> /dev/null; then
        print_step "Active project set to: ${PROJECT_ID}"
    else
        print_error "Project '${PROJECT_ID}' exists but is not accessible. Check your permissions."
        exit 1
    fi
else
    print_error "Could not set active project to '${PROJECT_ID}'."
    exit 1
fi

# Link billing account if provided
if [[ -n "$BILLING_ACCOUNT" ]]; then
    print_info "Linking billing account..."
    if gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT" 2>&1; then
        print_step "Billing account linked successfully."
    else
        print_warn "Could not link billing account. You may need to do this manually."
    fi
fi

# ─────────────────────────────────────────────
# STEP 2: ENABLE REQUIRED APIs
# ─────────────────────────────────────────────
print_header "Step 2: Enabling Required APIs"

FAILED_APIS=()
BILLING_NEEDED=false
TOS_IDS_NEEDED=()   # Track unique ToS IDs that need acceptance
TOS_FAILED_APIS=()  # Track APIs that failed due to ToS
API_TOTAL=${#REQUIRED_APIS[@]}
API_COUNT=0

# Verify project is set correctly before enabling APIs
print_info "Verifying active project: ${PROJECT_ID}"
CURRENT_PROJECT=$(gcloud config get-value project 2>/dev/null)
if [[ "$CURRENT_PROJECT" != "$PROJECT_ID" ]]; then
    print_warn "Active project mismatch. Resetting to ${PROJECT_ID}..."
    gcloud config set project "$PROJECT_ID" --quiet 2>&1 || true
fi

for api in "${REQUIRED_APIS[@]}"; do
    API_COUNT=$((API_COUNT + 1))
    print_info "[${API_COUNT}/${API_TOTAL}] Enabling ${api}..."

    # Use --quiet to suppress interactive prompts and capture all output
    API_OUTPUT=""
    API_OK=false
    API_OUTPUT=$(gcloud services enable "$api" --project="$PROJECT_ID" --quiet 2>&1) && API_OK=true || API_OK=false

    if [[ "$API_OK" == true ]]; then
        print_step "Enabled: ${api}"
    else
        FAILED_APIS+=("$api")
        if echo "$API_OUTPUT" | grep -qi "UREQ_TOS_NOT_ACCEPTED\|terms of service"; then
            # Extract the ToS ID from the error output (e.g., appsadmin, universal, calendar)
            TOS_ID=$(echo "$API_OUTPUT" | grep -oP "tos_id=\K[a-zA-Z]+" | head -1)
            if [[ -n "$TOS_ID" ]]; then
                # Add to unique list if not already there
                if [[ ! " ${TOS_IDS_NEEDED[*]} " =~ " ${TOS_ID} " ]]; then
                    TOS_IDS_NEEDED+=("$TOS_ID")
                fi
            fi
            TOS_FAILED_APIS+=("$api")
            print_warn "Could not enable ${api} — Terms of Service '${TOS_ID}' not accepted."
        elif echo "$API_OUTPUT" | grep -qi "billing"; then
            BILLING_NEEDED=true
            print_warn "Could not enable ${api} — billing account required."
            print_info "  Output: ${API_OUTPUT}"
        elif echo "$API_OUTPUT" | grep -qi "PERMISSION_DENIED\|permission"; then
            print_warn "Could not enable ${api} — permission denied."
            print_info "  Output: ${API_OUTPUT}"
            print_info "  Ensure you have 'Service Usage Admin' or 'Editor' role on this project."
        elif echo "$API_OUTPUT" | grep -qi "not found\|invalid"; then
            print_warn "Could not enable ${api} — API name not found or invalid."
            print_info "  Output: ${API_OUTPUT}"
        else
            print_warn "Could not enable ${api}."
            print_info "  Output: ${API_OUTPUT}"
        fi
    fi
done

# ── AUTO-RESOLVE: Terms of Service (ToS) acceptance ──
if [[ ${#TOS_IDS_NEEDED[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  AUTO-RESOLVE: Google APIs Terms of Service                 ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}${#TOS_FAILED_APIS[@]} APIs failed because Google API Terms of Service${NC}"
    echo -e "${BOLD}have not been accepted for this account/project.${NC}"
    echo ""
    echo -e "${CYAN}The following Terms of Service need to be accepted:${NC}"
    for tos_id in "${TOS_IDS_NEEDED[@]}"; do
        TOS_URL="https://console.developers.google.com/terms/${tos_id}?project=${PROJECT_ID}"
        echo -e "  ${GREEN}${tos_id}${NC}: ${GREEN}${TOS_URL}${NC}"
    done
    echo ""
    echo -e "${BOLD}You need to open each link above and click 'Accept' on the page.${NC}"
    echo ""

    # Try to open the ToS pages automatically
    read -rp "$(echo -e "${CYAN}Open the Terms of Service pages in your browser? (y/n): ${NC}")" open_tos
    if [[ "$open_tos" == "y" || "$open_tos" == "Y" ]]; then
        for tos_id in "${TOS_IDS_NEEDED[@]}"; do
            TOS_URL="https://console.developers.google.com/terms/${tos_id}?project=${PROJECT_ID}"
            if [[ "$IS_CLOUD_SHELL" == true ]]; then
                # In Cloud Shell, just show the links (user clicks them)
                echo -e "  ${GREEN}→${NC} ${TOS_URL}"
            else
                # On local machine, try to open in browser
                if command -v xdg-open &> /dev/null; then
                    xdg-open "$TOS_URL" 2>/dev/null &
                elif command -v open &> /dev/null; then
                    open "$TOS_URL" 2>/dev/null &
                else
                    echo -e "  ${GREEN}→${NC} ${TOS_URL}"
                fi
            fi
        done
    else
        echo -e "${CYAN}Please open these links manually:${NC}"
        for tos_id in "${TOS_IDS_NEEDED[@]}"; do
            TOS_URL="https://console.developers.google.com/terms/${tos_id}?project=${PROJECT_ID}"
            echo -e "  ${GREEN}→${NC} ${TOS_URL}"
        done
    fi

    echo ""
    read -rp "$(echo -e "${CYAN}Press Enter after accepting ALL Terms of Service to retry failed APIs...${NC}")"
    echo ""

    # ── Retry only the ToS-failed APIs ──
    print_info "Retrying ${#TOS_FAILED_APIS[@]} APIs that failed due to Terms of Service..."
    RETRY_STILL_FAILED=()
    for api in "${TOS_FAILED_APIS[@]}"; do
        print_info "Retrying ${api}..."
        RETRY_OUTPUT=$(gcloud services enable "$api" --project="$PROJECT_ID" --quiet 2>&1) && RETRY_OK=true || RETRY_OK=false
        if [[ "$RETRY_OK" == true ]]; then
            print_step "Enabled: ${api}"
            # Remove from FAILED_APIS
            FAILED_APIS=("${FAILED_APIS[@]/$api}")
        else
            RETRY_STILL_FAILED+=("$api")
            print_warn "Still could not enable ${api}."
            print_info "  Output: ${RETRY_OUTPUT}"
        fi
    done

    # Clean up empty elements from FAILED_APIS
    CLEAN_FAILED=()
    for f in "${FAILED_APIS[@]}"; do
        [[ -n "$f" ]] && CLEAN_FAILED+=("$f")
    done
    FAILED_APIS=("${CLEAN_FAILED[@]}")

    if [[ ${#RETRY_STILL_FAILED[@]} -eq 0 ]]; then
        print_step "All ToS-blocked APIs enabled successfully after accepting Terms of Service!"
    else
        print_warn "${#RETRY_STILL_FAILED[@]} API(s) still failing: ${RETRY_STILL_FAILED[*]}"
        print_info "Ensure you accepted ALL Terms of Service pages and try enabling manually:"
        for fapi in "${RETRY_STILL_FAILED[@]}"; do
            print_info "  gcloud services enable ${fapi} --project=${PROJECT_ID}"
        done
    fi
fi

if [[ "$BILLING_NEEDED" == true ]]; then
    echo ""
    print_warn "Some APIs require a billing account linked to the project."
    BILLING_URL="https://console.cloud.google.com/billing/linkedaccount?project=${PROJECT_ID}"
    if [[ "$IS_CLOUD_SHELL" == true ]]; then
        print_info "Link billing at: ${BILLING_URL}"
    else
        print_info "Link billing at: ${BILLING_URL}"
    fi
    print_info "After linking billing, re-run this script or enable failed APIs manually:"
    for fapi in "${FAILED_APIS[@]}"; do
        print_info "  gcloud services enable ${fapi} --project=${PROJECT_ID}"
    done
fi

if [[ ${#FAILED_APIS[@]} -eq 0 ]]; then
    echo ""
    print_step "All ${API_TOTAL} APIs enabled successfully."
else
    echo ""
    print_warn "${#FAILED_APIS[@]} of ${API_TOTAL} API(s) failed to enable: ${FAILED_APIS[*]}"

    # If ALL APIs failed, there may be a fundamental issue
    if [[ ${#FAILED_APIS[@]} -eq $API_TOTAL ]]; then
        echo ""
        print_error "ALL APIs failed to enable. Common causes:"
        print_info "  1. Billing account not linked to project ${PROJECT_ID}"
        print_info "  2. Insufficient permissions (need Editor or Owner role)"
        print_info "  3. Organization policies blocking API enablement"
        print_info "  4. Terms of Service not accepted (see links above)"
        echo ""
        read -rp "$(echo -e "${CYAN}Continue anyway? (y/n): ${NC}")" continue_anyway
        if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
            print_error "Aborting. Fix the issues above and re-run the script."
            exit 1
        fi
    fi
fi

# ─────────────────────────────────────────────
# STEP 3: CREATE SERVICE ACCOUNT
# ─────────────────────────────────────────────
print_header "Step 3: Creating Service Account"

SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

if gcloud iam service-accounts create "$SERVICE_ACCOUNT_NAME" \
    --project="$PROJECT_ID" \
    --display-name="$DISPLAY_NAME" \
    --description="CloudM Migrate service account for ${DEST_DOMAIN}" 2>&1; then
    print_step "Service account created: ${SA_EMAIL}"
else
    print_warn "Service account may already exist. Continuing..."
    SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
fi

# Grant Owner role to the service account
print_info "Granting Owner role to service account..."
if gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="roles/owner" \
    --condition=None \
    --quiet 2>&1; then
    print_step "Owner role granted."
else
    print_warn "Could not grant Owner role. CloudM may still work if the SA has sufficient permissions."
    print_info "You can grant it manually: IAM & Admin > IAM > ${SA_EMAIL} > Add role: Owner"
fi

# ─────────────────────────────────────────────
# STEP 4: ENABLE DOMAIN-WIDE DELEGATION (GCP SIDE)
# ─────────────────────────────────────────────
print_header "Step 4: Enabling Domain-Wide Delegation on Service Account"

# Get the unique ID (OAuth2 client ID) of the service account
# The service account may take a few seconds to propagate after creation,
# so we retry with a short backoff if it's not found immediately.
SA_UNIQUE_ID=""
SA_DESCRIBE_RETRIES=5
for sa_attempt in $(seq 1 "$SA_DESCRIBE_RETRIES"); do
    SA_UNIQUE_ID=$(gcloud iam service-accounts describe "$SA_EMAIL" \
        --project="$PROJECT_ID" \
        --format="value(uniqueId)" 2>/dev/null) && break
    SA_UNIQUE_ID=""  # Reset on failure
    if [[ "$sa_attempt" -lt "$SA_DESCRIBE_RETRIES" ]]; then
        print_info "Service account not yet available (attempt ${sa_attempt}/${SA_DESCRIBE_RETRIES}). Waiting 10 seconds..."
        sleep 10
    fi
done

if [[ -z "$SA_UNIQUE_ID" ]]; then
    print_error "Could not retrieve Service Account Unique ID after ${SA_DESCRIBE_RETRIES} attempts."
    print_info "The service account may still be propagating. Wait a minute and re-run the script."
    print_info "Or retrieve the Unique ID manually:"
    print_info "  gcloud iam service-accounts describe ${SA_EMAIL} --project=${PROJECT_ID} --format='value(uniqueId)'"
    exit 1
fi

print_info "Service Account Unique ID (Client ID): ${SA_UNIQUE_ID}"

# Get a fresh access token and validate it
ACCESS_TOKEN=$(gcloud auth print-access-token)

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == *"ERROR"* ]]; then
    print_error "Could not retrieve access token. Please run: gcloud auth login"
    exit 1
fi

# Enable domain-wide delegation by setting the oauth2ClientId on the service account.
# NOTE: Google deprecated the PATCH method for this field, but the PUT (update) method
# still works. We use PUT to replace the full service account resource with oauth2ClientId set.
print_info "Enabling domain-wide delegation via IAM API (PUT method)..."

# Escape variables for JSON payload
JSON_SA_DISPLAY=$(printf '%s' "$DISPLAY_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
JSON_SA_DESC=$(printf '%s' "CloudM Migrate service account for ${DEST_DOMAIN}" | sed 's/\\/\\\\/g; s/"/\\"/g')

DWD_RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
    "https://iam.googleapis.com/v1/projects/-/serviceAccounts/${SA_EMAIL}" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"displayName\": \"${JSON_SA_DISPLAY}\",
        \"description\": \"${JSON_SA_DESC}\",
        \"oauth2ClientId\": \"${SA_UNIQUE_ID}\"
    }")

DWD_HTTP_CODE=$(echo "$DWD_RESPONSE" | tail -n1)
DWD_BODY=$(echo "$DWD_RESPONSE" | sed '$d')

DWD_AUTO_ENABLED=false

if [[ "$DWD_HTTP_CODE" -ge 200 && "$DWD_HTTP_CODE" -lt 300 ]]; then
    # Verify oauth2ClientId is present in the response
    if echo "$DWD_BODY" | grep -q "oauth2ClientId"; then
        DWD_AUTO_ENABLED=true
        print_step "Domain-wide delegation enabled on the GCP side."
    else
        print_warn "API call succeeded but oauth2ClientId not confirmed in response."
        print_info "API response: ${DWD_BODY}"
    fi
else
    print_warn "Could not enable DWD via API (HTTP ${DWD_HTTP_CODE})."
    print_info "API response: ${DWD_BODY}"
fi

if [[ "$DWD_AUTO_ENABLED" == false ]]; then
    echo ""
    print_info "You will need to enable DWD manually:"
    echo ""
    echo -e "  ${BOLD}Enable DWD in GCP Console:${NC}"
    echo -e "     ${GREEN}IAM & Admin > Service Accounts > ${SA_EMAIL}${NC}"
    echo -e "     Click the service account > Show Advanced Settings"
    echo -e "     Look for Domain-wide Delegation section"
    echo ""
    print_info "Client ID to use: ${SA_UNIQUE_ID}"
fi

# ─────────────────────────────────────────────
# STEP 5: CONFIGURE OAUTH CONSENT SCREEN
# ─────────────────────────────────────────────
print_header "Step 5: Configuring OAuth Consent Screen"

# Create OAuth consent screen (Internal type)
# Uses the IAP (Identity-Aware Proxy) brands API endpoint
# IMPORTANT: The brands API requires the PROJECT NUMBER (not project ID)
print_info "Creating OAuth consent screen (Internal)..."

# Refresh access token in case it expired during API enablement
ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null)
if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == *"ERROR"* ]]; then
    print_error "Access token expired. Please re-authenticate: gcloud auth login"
    exit 1
fi

# Get the project number (the brands API works best with project number)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)" 2>/dev/null)
if [[ -z "$PROJECT_NUMBER" ]]; then
    print_warn "Could not retrieve project number. Using project ID as fallback."
    PROJECT_NUMBER="$PROJECT_ID"
else
    print_info "Project number: ${PROJECT_NUMBER}"
fi

# Properly escape variables for JSON payload
JSON_DISPLAY_NAME=$(printf '%s' "$DISPLAY_NAME" | sed 's/\\/\\\\/g; s/"/\\"/g')
JSON_ADMIN_EMAIL=$(printf '%s' "$ADMIN_EMAIL" | sed 's/\\/\\\\/g; s/"/\\"/g')

# First check if the IAP API is enabled (required for the brands endpoint)
print_info "Verifying IAP API is enabled..."
IAP_CHECK=$(gcloud services list --project="$PROJECT_ID" --filter="config.name:iap.googleapis.com" --format="value(config.name)" 2>/dev/null)
if [[ -z "$IAP_CHECK" ]]; then
    print_warn "IAP API may not be enabled. Attempting to enable it now..."
    gcloud services enable iap.googleapis.com --project="$PROJECT_ID" --quiet 2>&1 || true
    # Wait briefly for API to become available
    sleep 5
fi

print_info "Sending OAuth consent screen request..."
BRAND_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    "https://iap.googleapis.com/v1/projects/${PROJECT_NUMBER}/brands" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"applicationTitle\": \"${JSON_DISPLAY_NAME}\",
        \"supportEmail\": \"${JSON_ADMIN_EMAIL}\"
    }")

BRAND_HTTP_CODE=$(echo "$BRAND_RESPONSE" | tail -n1)
BRAND_BODY=$(echo "$BRAND_RESPONSE" | sed '$d')

print_info "OAuth API response HTTP code: ${BRAND_HTTP_CODE}"

if [[ "$BRAND_HTTP_CODE" -ge 200 && "$BRAND_HTTP_CODE" -lt 300 ]]; then
    print_step "OAuth consent screen configured (Internal)."
elif echo "$BRAND_BODY" | grep -q "ALREADY_EXISTS"; then
    print_step "OAuth consent screen already exists. Continuing..."
else
    print_warn "Could not configure OAuth consent screen via API (HTTP ${BRAND_HTTP_CODE})."
    print_info "API response: ${BRAND_BODY}"
    echo ""
    print_info "You need to configure it manually in GCP Console:"
    OAUTH_URL="https://console.cloud.google.com/apis/credentials/consent?project=${PROJECT_ID}"
    print_info "  1. Open: ${OAUTH_URL}"
    print_info "  2. Select 'Internal' user type"
    print_info "  3. App name: ${DISPLAY_NAME}"
    print_info "  4. Support email: ${ADMIN_EMAIL}"
    print_info "  5. Click Save"
fi

# ─────────────────────────────────────────────
# STEP 6: CREATE AND DOWNLOAD JSON KEY
# ─────────────────────────────────────────────
print_header "Step 6: Creating and Downloading Service Account Key"

TEMP_KEY_PATH="/tmp/sa-key-${PROJECT_ID}.json"
FINAL_KEY_PATH="${OUTPUT_DIR}/${KEY_FILENAME}"

# Capture the error output to detect which constraint is blocking
KEY_CREATE_OUTPUT=$(gcloud iam service-accounts keys create "$TEMP_KEY_PATH" \
    --iam-account="$SA_EMAIL" \
    --project="$PROJECT_ID" \
    --key-file-type="json" 2>&1)
KEY_CREATE_EXIT=$?

if [[ $KEY_CREATE_EXIT -eq 0 ]]; then
    # Move, rename, and secure the key file
    mv "$TEMP_KEY_PATH" "$FINAL_KEY_PATH"
    chmod 600 "$FINAL_KEY_PATH"
    print_step "Key created and renamed to: ${FINAL_KEY_PATH}"
    print_step "Key file permissions set to 600 (owner read/write only)."

    # In Cloud Shell, offer to download the key file to the local machine
    if [[ "$IS_CLOUD_SHELL" == true ]]; then
        echo ""
        read -rp "$(echo -e "${CYAN}Download the key file to your local machine? (y/n): ${NC}")" dl_key
        if [[ "$dl_key" == "y" || "$dl_key" == "Y" ]]; then
            if command -v cloudshell &> /dev/null; then
                cloudshell download "$FINAL_KEY_PATH"
                print_step "Download initiated. Check your browser for the download prompt."
            elif command -v dl &> /dev/null; then
                dl "$FINAL_KEY_PATH"
                print_step "Download initiated."
            else
                print_warn "Could not trigger automatic download."
                print_info "Download the file manually from Cloud Shell: click the three-dot menu > Download file"
                print_info "File path: ${FINAL_KEY_PATH}"
            fi
        fi
    fi
else
    echo "$KEY_CREATE_OUTPUT"
    print_error "Failed to create service account key."
    print_warn "This is likely caused by an Organization Policy blocking key creation."

    # ── Detect which constraint(s) are blocking ──
    BLOCKING_POLICIES=()
    if echo "$KEY_CREATE_OUTPUT" | grep -q "iam.managed.disableServiceAccountKeyCreation"; then
        BLOCKING_POLICIES+=("iam.managed.disableServiceAccountKeyCreation")
    fi
    if echo "$KEY_CREATE_OUTPUT" | grep -q "iam.disableServiceAccountKeyCreation" && \
       ! echo "$KEY_CREATE_OUTPUT" | grep -q "iam.managed.disableServiceAccountKeyCreation"; then
        BLOCKING_POLICIES+=("iam.disableServiceAccountKeyCreation")
    fi
    # If we couldn't detect the specific constraint, try both
    if [[ ${#BLOCKING_POLICIES[@]} -eq 0 ]]; then
        BLOCKING_POLICIES=("iam.managed.disableServiceAccountKeyCreation" "iam.disableServiceAccountKeyCreation")
    fi

    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  AUTO-RESOLVE: Organization Policy Blocking Key Creation    ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Error:${NC} An Organization Policy that blocks service account key"
    echo -e "creation has been enforced on your organization."
    echo ""
    echo -e "${BOLD}Detected Blocking Policy:${NC}"
    for bp in "${BLOCKING_POLICIES[@]}"; do
        echo -e "  ${RED}${bp}${NC}"
    done
    echo ""

    read -rp "$(echo -e "${CYAN}Attempt to auto-resolve this issue? (y/n): ${NC}")" auto_resolve
    if [[ "$auto_resolve" == "y" || "$auto_resolve" == "Y" ]]; then

        # ── Step 1: Detect the Organization ID ──
        print_info "Detecting Organization ID from project..."
        RESOLVED_ORG_ID=""
        if [[ -n "${ORG_ID:-}" ]]; then
            RESOLVED_ORG_ID="$ORG_ID"
            print_step "Using Organization ID provided earlier: ${RESOLVED_ORG_ID}"
        else
            RESOLVED_ORG_ID=$(gcloud projects get-ancestors "$PROJECT_ID" \
                --format="csv[no-heading](id,type)" 2>/dev/null \
                | grep ",organization" | cut -d',' -f1)
            if [[ -n "$RESOLVED_ORG_ID" ]]; then
                print_step "Detected Organization ID: ${RESOLVED_ORG_ID}"
            else
                print_error "Could not detect Organization ID."
                print_info "Please enter it manually."
                read -rp "$(echo -e "${CYAN}Organization ID: ${NC}")" RESOLVED_ORG_ID
                if [[ -z "$RESOLVED_ORG_ID" ]]; then
                    print_error "Cannot proceed without Organization ID."
                    FINAL_KEY_PATH=""
                fi
            fi
        fi

        if [[ -n "$RESOLVED_ORG_ID" ]]; then

            # ── Step 2: Grant Organization Policy Administrator role ──
            print_info "Granting Organization Policy Administrator role to ${ADMIN_EMAIL}..."
            if gcloud organizations add-iam-policy-binding "$RESOLVED_ORG_ID" \
                --member="user:${ADMIN_EMAIL}" \
                --role="roles/orgpolicy.policyAdmin" \
                --quiet 2>&1; then
                print_step "Organization Policy Administrator role granted."
            else
                print_warn "Could not grant role. Your account may already have it, or you need Super Admin access."
                print_info "Continuing anyway — the policy change may still work..."
            fi

            # Brief pause for IAM propagation
            print_info "Waiting 10 seconds for IAM role propagation..."
            sleep 10

            # ── Step 3: Disable ALL key-creation policies (both managed and classic) ──
            # Google has two constraints that can block key creation:
            #   - iam.managed.disableServiceAccountKeyCreation (newer managed constraint)
            #   - iam.disableServiceAccountKeyCreation (classic constraint)
            # We reset BOTH to ensure key creation is unblocked regardless of which is enforced.
            POLICY_DISABLED=false
            POLICIES_TO_RESET=("iam.managed.disableServiceAccountKeyCreation" "iam.disableServiceAccountKeyCreation")

            for POLICY_ID in "${POLICIES_TO_RESET[@]}"; do
                print_info "Resetting policy: ${POLICY_ID}..."
                if gcloud org-policies reset "$POLICY_ID" \
                    --organization="$RESOLVED_ORG_ID" --quiet 2>&1; then
                    print_step "Policy reset: ${POLICY_ID}"
                    POLICY_DISABLED=true
                else
                    # Fallback: try the older resource-manager command (only works for classic constraint)
                    if [[ "$POLICY_ID" == "iam.disableServiceAccountKeyCreation" ]]; then
                        if gcloud resource-manager org-policies disable-enforce \
                            "$POLICY_ID" \
                            --organization="$RESOLVED_ORG_ID" --quiet 2>&1; then
                            print_step "Policy enforcement disabled: ${POLICY_ID}"
                            POLICY_DISABLED=true
                        else
                            print_warn "Could not reset: ${POLICY_ID} (may not be enforced)"
                        fi
                    else
                        print_warn "Could not reset: ${POLICY_ID} (may not be enforced)"
                    fi
                fi
            done

            if [[ "$POLICY_DISABLED" == false ]]; then
                print_error "Could not disable any organization policies automatically."
                echo ""
                echo -e "${CYAN}Manual Resolution Steps:${NC}"
                echo ""
                echo -e "  1. Select your ${BOLD}Organization${NC} (not the project) in the GCP Console"
                echo -e "  2. Go to ${GREEN}IAM & Admin > IAM${NC}"
                echo -e "  3. Select your Admin Account"
                echo -e "  4. Grant the ${GREEN}Organization Policy Administrator${NC} role"
                echo -e "  5. Go to ${GREEN}IAM & Admin > Organization Policies${NC}"
                echo -e "  6. Search for: ${GREEN}disableServiceAccountKeyCreation${NC}"
                echo -e "  7. Disable BOTH policies if present:"
                echo -e "     - ${GREEN}iam.managed.disableServiceAccountKeyCreation${NC} (Managed)"
                echo -e "     - ${GREEN}iam.disableServiceAccountKeyCreation${NC} (Classic)"
                echo -e "  8. For each: Click ${BOLD}Manage Policy${NC} > Set to ${GREEN}OFF${NC} > ${BOLD}Set Policy${NC}"
                echo ""
                read -rp "$(echo -e "${CYAN}Press Enter after completing the manual steps to retry...${NC}")"
                POLICY_DISABLED=true
            fi

            if [[ "$POLICY_DISABLED" == true ]]; then
                # ── Step 4: Retry key creation with progressive backoff ──
                # Policy propagation can take anywhere from seconds to several minutes
                RETRY_WAITS=(15 30 60 120)
                MAX_RETRIES=${#RETRY_WAITS[@]}
                KEY_CREATED=false

                for attempt in $(seq 1 "$MAX_RETRIES"); do
                    WAIT_SECS=${RETRY_WAITS[$((attempt - 1))]}
                    print_info "Attempt ${attempt}/${MAX_RETRIES}: Waiting ${WAIT_SECS} seconds for policy propagation..."
                    sleep "$WAIT_SECS"

                    print_info "Attempting key creation..."
                    if gcloud iam service-accounts keys create "$TEMP_KEY_PATH" \
                        --iam-account="$SA_EMAIL" \
                        --project="$PROJECT_ID" \
                        --key-file-type="json" 2>&1; then
                        KEY_CREATED=true
                        mv "$TEMP_KEY_PATH" "$FINAL_KEY_PATH"
                        chmod 600 "$FINAL_KEY_PATH"
                        print_step "Key created on attempt ${attempt}!"
                        print_step "Key saved and renamed to: ${FINAL_KEY_PATH}"
                        print_step "Key file permissions set to 600 (owner read/write only)."
                        break
                    else
                        if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
                            print_warn "Still blocked. Policy may not have propagated yet. Retrying..."
                        fi
                    fi
                done

                if [[ "$KEY_CREATED" == true ]]; then

                    # In Cloud Shell, offer to download the key file
                    if [[ "$IS_CLOUD_SHELL" == true ]]; then
                        echo ""
                        read -rp "$(echo -e "${CYAN}Download the key file to your local machine? (y/n): ${NC}")" dl_key
                        if [[ "$dl_key" == "y" || "$dl_key" == "Y" ]]; then
                            if command -v cloudshell &> /dev/null; then
                                cloudshell download "$FINAL_KEY_PATH"
                                print_step "Download initiated. Check your browser for the download prompt."
                            elif command -v dl &> /dev/null; then
                                dl "$FINAL_KEY_PATH"
                                print_step "Download initiated."
                            else
                                print_warn "Could not trigger automatic download."
                                print_info "Download manually: three-dot menu > Download file"
                                print_info "File path: ${FINAL_KEY_PATH}"
                            fi
                        fi
                    fi

                    # ── Step 5: Offer to re-enable the policies (security best practice) ──
                    echo ""
                    read -rp "$(echo -e "${YELLOW}Re-enable key-creation org policies for security? (y/n): ${NC}")" reenable_policy
                    if [[ "$reenable_policy" == "y" || "$reenable_policy" == "Y" ]]; then
                        print_info "Re-enabling organization policies..."
                        for POLICY_ID in "${POLICIES_TO_RESET[@]}"; do
                            if gcloud org-policies set-enforce "$POLICY_ID" \
                                --organization="$RESOLVED_ORG_ID" --quiet 2>&1; then
                                print_step "Policy re-enabled: ${POLICY_ID}"
                            elif [[ "$POLICY_ID" == "iam.disableServiceAccountKeyCreation" ]] && \
                                 gcloud resource-manager org-policies enable-enforce \
                                    "$POLICY_ID" \
                                    --organization="$RESOLVED_ORG_ID" --quiet 2>&1; then
                                print_step "Policy re-enabled: ${POLICY_ID}"
                            else
                                print_warn "Could not re-enable: ${POLICY_ID}"
                            fi
                        done
                        print_info "If any policies could not be re-enabled, do it manually:"
                        print_info "IAM & Admin > Organization Policies > search 'disableServiceAccountKeyCreation' > Enforce ON"
                    else
                        print_warn "Policies remain disabled. Remember to re-enable them after migration for security."
                    fi
                else
                    print_error "Key creation failed after ${MAX_RETRIES} attempts (waited ~3.5 minutes total)."
                    print_info "Propagation may need more time. Run this command manually in a few minutes:"
                    print_info "  gcloud iam service-accounts keys create ${KEY_FILENAME} --iam-account=${SA_EMAIL} --project=${PROJECT_ID}"
                    FINAL_KEY_PATH=""
                fi
            else
                FINAL_KEY_PATH=""
            fi
        fi
    else
        echo ""
        echo -e "${CYAN}Manual Resolution Steps:${NC}"
        echo ""
        echo -e "  1. Select your ${BOLD}Organization${NC} (not the project) in the GCP Console"
        echo -e "  2. Go to ${GREEN}IAM & Admin > IAM${NC}"
        echo -e "  3. Select your Admin Account"
        echo -e "  4. Grant the ${GREEN}Organization Policy Administrator${NC} role"
        echo -e "  5. Go to ${GREEN}IAM & Admin > Organization Policies${NC}"
        echo -e "  6. Search for: ${GREEN}disableServiceAccountKeyCreation${NC}"
        echo -e "  7. Disable BOTH policies if present:"
        echo -e "     - ${GREEN}iam.managed.disableServiceAccountKeyCreation${NC} (Managed)"
        echo -e "     - ${GREEN}iam.disableServiceAccountKeyCreation${NC} (Classic)"
        echo -e "  8. For each: Click ${BOLD}Manage Policy${NC} > Set to ${GREEN}OFF${NC} > ${BOLD}Set Policy${NC}"
        echo ""
        FINAL_KEY_PATH=""
    fi
fi

# ─────────────────────────────────────────────
# STEP 7: PREPARE DWD SCOPES (COMBINED)
# ─────────────────────────────────────────────
print_header "Step 7: Domain-Wide Delegation - Admin Console Configuration"

# Combine standard + chat scopes
ALL_SCOPES=("${STANDARD_SCOPES[@]}" "${CHAT_SCOPES[@]}")
SCOPES_CSV=$(IFS=','; echo "${ALL_SCOPES[*]}")

# Build the pre-populated DWD link (Client ID + all scopes in URL parameters)
DWD_DIRECT_URL="https://admin.google.com/ac/owl/domainwidedelegation?clientScopeToAdd=${SCOPES_CSV}&clientIdToAdd=${SA_UNIQUE_ID}&overwriteClientId=true"

echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ONE-CLICK DWD SETUP: Client ID & Scopes Pre-Populated     ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}Click the link below to open the Admin Console DWD page with the"
echo -e "Client ID and all ${#ALL_SCOPES[@]} OAuth scopes pre-filled.${NC}"
echo ""
echo -e "${CYAN}You only need to click ${BOLD}Authorize${CYAN} on the page that opens.${NC}"
echo ""
echo -e "  ${GREEN}${DWD_DIRECT_URL}${NC}"
echo ""

# Open the pre-populated DWD link in browser
read -rp "$(echo -e "${CYAN}Open the DWD link in your browser? (y/n): ${NC}")" open_dwd
if [[ "$open_dwd" == "y" || "$open_dwd" == "Y" ]]; then
    if [[ "$IS_CLOUD_SHELL" == true ]]; then
        print_info "Click the link above to open in a new tab."
    elif command -v open &> /dev/null; then
        open "$DWD_DIRECT_URL"
        print_step "Opened Admin Console DWD page with pre-filled values."
    else
        print_info "Open the link above in your browser."
    fi
fi

echo ""
echo -e "${YELLOW}Note: Changes may take up to 24 hours to propagate.${NC}"
echo ""

echo -e "${CYAN}Reference values (for manual setup if needed):${NC}"
echo ""
echo -e "  ${BOLD}Client ID:${NC}     ${GREEN}${SA_UNIQUE_ID}${NC}"
echo -e "  ${BOLD}Total Scopes:${NC}  ${GREEN}${#ALL_SCOPES[@]} (${#STANDARD_SCOPES[@]} standard + ${#CHAT_SCOPES[@]} Chat)${NC}"
echo ""

# Save to a helper file for easy reference
DWD_HELPER_PATH="${OUTPUT_DIR}/dwd-setup-${DOMAIN_CLEAN}.txt"
cat > "$DWD_HELPER_PATH" << DWDEOF
Domain-Wide Delegation Setup for ${DEST_DOMAIN}
================================================

ONE-CLICK DWD LINK (open in browser — Client ID & scopes pre-populated):
${DWD_DIRECT_URL}

Just click Authorize on the page that opens.

──────────────────────────────────────────────────
Reference values (for manual setup if needed):

Client ID: ${SA_UNIQUE_ID}

OAuth Scopes (${#ALL_SCOPES[@]} total — paste as one line in Admin Console):
${SCOPES_CSV}

Manual Steps:
1. Go to https://admin.google.com
2. Navigate to: Security > Access and data control > API controls
3. Click: Manage Domain Wide Delegation
4. Click: Add new
5. Paste the Client ID and OAuth Scopes above
6. Click: Authorize
DWDEOF

print_step "DWD helper file saved to: ${DWD_HELPER_PATH}"

# Copy the Client ID to clipboard (macOS only — not available in Cloud Shell)
if command -v pbcopy &> /dev/null; then
    echo "$SA_UNIQUE_ID" | pbcopy
    print_info "Client ID copied to clipboard!"
fi

# ─────────────────────────────────────────────
# STEP 8: CHAT API CONFIGURATION INSTRUCTIONS
# ─────────────────────────────────────────────
print_header "Step 8: Google Chat API Configuration - Manual Step Required"

CHAT_CONFIG_URL="https://console.developers.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=${PROJECT_ID}"

echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║  MANUAL STEP REQUIRED: Chat API App Configuration           ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}The Chat API app configuration must be done in the GCP Console.${NC}"
echo ""
echo -e "${CYAN}Direct link to Chat API configuration:${NC}"
echo -e "  ${GREEN}${CHAT_CONFIG_URL}${NC}"
echo ""
echo -e "${CYAN}Configure the following settings:${NC}"
echo ""
CHAT_AVATAR_URL="https://images.g2crowd.com/uploads/product/image/social_landscape/social_landscape_cee2152a5febe154fc27f9af97b8f3dc/cloudasta-by-shuttlecloud.png"
CHAT_DESCRIPTION="CloudM Migrate"

echo -e "  ${BOLD}App Name:${NC}              ${GREEN}${CHAT_APP_NAME}${NC}"
echo -e "  ${BOLD}Avatar URL:${NC}            ${GREEN}${CHAT_AVATAR_URL}${NC}"
echo -e "  ${BOLD}Description:${NC}           ${GREEN}${CHAT_DESCRIPTION}${NC}  (max 40 characters)"
echo ""
echo -e "  ${BOLD}IMPORTANT SETTINGS:${NC}"
echo -e "  ${RED}✗${NC} Build this Chat app as a Workspace add-on: ${RED}DISABLED (untick)${NC}"
echo -e "  ${GREEN}✓${NC} Log errors to Logging:                     ${GREEN}ENABLED${NC}"
echo ""
echo -e "${CYAN}Under 'Functionality':${NC}"
echo -e "  ${GREEN}✓${NC} Join spaces and group conversations:       ${GREEN}ENABLED${NC}"
echo ""
echo -e "${CYAN}Under 'Connection settings':${NC}"
echo -e "  ${BOLD}Connection type:${NC}       ${GREEN}HTTP endpoint URL${NC}"
echo -e "  ${BOLD}HTTP endpoint URL:${NC}     ${GREEN}https://${DEST_DOMAIN}${NC}"
echo -e "  ${BOLD}Authentication Audience:${NC} ${GREEN}Project Number${NC}  (select from dropdown)"
echo ""
echo -e "${CYAN}Under 'Visibility':${NC}"
echo -e "  Enter email addresses to add individuals and groups in your domain:"
echo -e "  ${GREEN}${ADMIN_EMAIL}${NC}"
echo ""
echo -e "  ${YELLOW}TIP: Create a Google Group (e.g., migration-users@${DEST_DOMAIN}) containing${NC}"
echo -e "  ${YELLOW}all users being migrated, then add that group here under Visibility to make${NC}"
echo -e "  ${YELLOW}the Chat app available to all migrating users at once.${NC}"
echo ""
echo -e "${CYAN}Under 'App Status':${NC}"
echo -e "  Ensure the status is set to ${BOLD}LIVE - available to users${NC}"
echo ""
echo -e "  Click ${BOLD}Save${NC}"
echo ""

# Open the Chat API config page in browser
echo ""
read -rp "$(echo -e "${CYAN}Open Chat API configuration page in your browser? (y/n): ${NC}")" open_browser
if [[ "$open_browser" == "y" || "$open_browser" == "Y" ]]; then
    if [[ "$IS_CLOUD_SHELL" == true ]]; then
        print_info "Click this link to open in a new tab:"
        echo -e "  ${GREEN}${CHAT_CONFIG_URL}${NC}"
    elif command -v open &> /dev/null; then
        open "$CHAT_CONFIG_URL"
        print_step "Opened in browser."
    else
        print_info "Open this URL manually: ${CHAT_CONFIG_URL}"
    fi
fi

# ─────────────────────────────────────────────
# STEP 9: ENABLE DRIVE SDK (ADMIN CONSOLE)
# ─────────────────────────────────────────────
print_header "Step 9: Enable Drive SDK (Admin Console Reminder)"

echo -e "${CYAN}Ensure the Drive SDK is enabled for your users:${NC}"
echo ""
echo -e "  1. Go to: ${GREEN}https://admin.google.com${NC}"
echo -e "  2. Navigate to: ${GREEN}Apps > Google Workspace > Drive and Docs${NC}"
echo -e "  3. Click: ${GREEN}Features and Applications${NC}"
echo -e "  4. Enable: ${GREEN}Allow users to access Google Drive with the Drive SDK API${NC}"
echo ""

# ─────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────
print_header "Setup Complete - Summary"

echo -e "${BOLD}Automated Steps Completed:${NC}"
echo -e "  ${GREEN}[✓]${NC} GCP Project created:          ${PROJECT_ID}"
echo -e "  ${GREEN}[✓]${NC} Service Account created:       ${SA_EMAIL}"
echo -e "  ${GREEN}[✓]${NC} APIs enabled:                  ${#REQUIRED_APIS[@]} APIs"
if [[ "$DWD_AUTO_ENABLED" == true ]]; then
echo -e "  ${GREEN}[✓]${NC} Domain-wide delegation:        Enabled (GCP side)"
else
echo -e "  ${YELLOW}[!]${NC} Domain-wide delegation:        MANUAL — see Step 4 above"
fi
echo -e "  ${GREEN}[✓]${NC} OAuth consent screen:          Configured"
if [[ -n "$FINAL_KEY_PATH" ]]; then
echo -e "  ${GREEN}[✓]${NC} Key file saved:                ${FINAL_KEY_PATH}"
fi
echo ""
echo -e "${BOLD}Manual Steps Remaining:${NC}"
if [[ "$DWD_AUTO_ENABLED" == false ]]; then
echo -e "  ${YELLOW}[!]${NC} Enable DWD on service account in GCP Console (see Step 4 above)"
fi
echo -e "  ${YELLOW}[!]${NC} Add DWD scopes in Google Admin Console (see Step 7 above)"
echo -e "  ${YELLOW}[!]${NC} Configure Chat API app in GCP Console (see Step 8 above)"
echo -e "  ${YELLOW}[!]${NC} Verify Drive SDK is enabled (see Step 9 above)"
echo ""
echo -e "${BOLD}Key Files:${NC}"
if [[ -n "$FINAL_KEY_PATH" ]]; then
echo -e "  Service Account Key:  ${GREEN}${FINAL_KEY_PATH}${NC}"
fi
echo -e "  DWD Helper File:      ${GREEN}${DWD_HELPER_PATH}${NC}"
echo -e "  Script Log File:      ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "${BOLD}Important Values:${NC}"
echo -e "  Project ID:           ${GREEN}${PROJECT_ID}${NC}"
echo -e "  Service Account:      ${GREEN}${SA_EMAIL}${NC}"
echo -e "  Client ID (for DWD):  ${GREEN}${SA_UNIQUE_ID}${NC}"
echo ""
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Script completed successfully!${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo ""

# ─────────────────────────────────────────────
# CLEANUP OPTION (if something went wrong)
# ─────────────────────────────────────────────
echo -e "${CYAN}If something went wrong and you want to start over, you can delete${NC}"
echo -e "${CYAN}the project and re-run this script:${NC}"
echo -e "  ${YELLOW}gcloud projects delete ${PROJECT_ID}${NC}"
echo ""
