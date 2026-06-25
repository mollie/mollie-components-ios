#!/usr/bin/env bash
#
# mint-demo-token.sh — mint a clientAccessToken for the MollieCheckoutDemo app.
#
# This stands in for YOUR server. In a real integration your backend holds the
# API key and creates the session; the app only ever receives the resulting
# clientAccessToken. Run this on your own machine (or server) — never embed an
# API key in a shipping app.
#
# Usage:
#   API_KEY=test_xxxxxxxx ./mint-demo-token.sh
#   make mint-demo-token API_KEY=test_xxxxxxxx          # from the repo root
#
# Optional env overrides:
#   AMOUNT=0.01 CURRENCY=EUR DESCRIPTION="Demo subscription"
#   REDIRECT_URL=https://example.com/return SEQUENCE_TYPE=oneoff
#   CUSTOMER_ID=cst_xxx           # required when SEQUENCE_TYPE=first
#   API_BASE=https://api.mollie.com
#
# Output: the clientAccessToken on stdout (copy it into the app's paste field).
set -euo pipefail

API_KEY="${API_KEY:?Set API_KEY (your Mollie API key). It stays on this machine — never ship it in an app.}"
API_BASE="${API_BASE:-https://api.mollie.com}"
AMOUNT="${AMOUNT:-0.01}"
CURRENCY="${CURRENCY:-EUR}"
DESCRIPTION="${DESCRIPTION:-Demo subscription}"
REDIRECT_URL="${REDIRECT_URL:-https://example.com/return}"
SEQUENCE_TYPE="${SEQUENCE_TYPE:-oneoff}"
CUSTOMER_ID="${CUSTOMER_ID:-}"

# Assemble the request body. Mirrors POST /v2/sessions exactly as a merchant
# backend would call it (amount + line item + redirectUrl + sequenceType).
customer_field=""
if [ -n "$CUSTOMER_ID" ]; then
  customer_field="\"customerId\": \"$CUSTOMER_ID\","
fi
read -r -d '' BODY <<JSON || true
{
  "amount": { "value": "$AMOUNT", "currency": "$CURRENCY" },
  "description": "$DESCRIPTION",
  "redirectUrl": "$REDIRECT_URL",
  "sequenceType": "$SEQUENCE_TYPE",
  $customer_field
  "lines": [
    {
      "description": "$DESCRIPTION",
      "quantity": 1,
      "unitPrice": { "value": "$AMOUNT", "currency": "$CURRENCY" },
      "totalAmount": { "value": "$AMOUNT", "currency": "$CURRENCY" }
    }
  ]
}
JSON

echo "Minting a session at $API_BASE/v2/sessions ..." >&2

RESPONSE="$(curl -sS -X POST "$API_BASE/v2/sessions" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY")"

# Prefer jq; fall back to a portable grep/sed extraction.
if command -v jq >/dev/null 2>&1; then
  TOKEN="$(printf '%s' "$RESPONSE" | jq -r '.clientAccessToken // empty')"
else
  TOKEN="$(printf '%s' "$RESPONSE" | grep -o '"clientAccessToken"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')"
fi

if [ -z "$TOKEN" ]; then
  echo "Failed to mint a clientAccessToken. Response was:" >&2
  printf '%s\n' "$RESPONSE" >&2
  exit 1
fi

echo "clientAccessToken:" >&2
printf '%s\n' "$TOKEN"
