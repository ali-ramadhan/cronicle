#!/bin/bash

# Load environment variables from .env file
echo "Loading email configuration from .env file..."
set -a  # automatically export all variables
source .env
set +a  # disable automatic export

DUF_OUTPUT=$(duf -only local -width 150 | aha --black)

curl -s --user "api:$MAILGUN_API_KEY" \
  "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
  -F "from=$FROM_EMAIL" \
  -F "to=$TO_EMAIL" \
  -F "subject=duf @ $(date)" \
  --form-string "html=${DUF_OUTPUT}"
