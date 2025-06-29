#!/bin/bash

# Load environment variables from .env file
echo "Loading email configuration from .env file..."
set -a  # automatically export all variables
source .env
set +a  # disable automatic export

# Record start time
START_TIME=$(date +%s)
echo "Starting plex preview generation at $(date)"

# Run the plex command and capture exit status
su -l plex -c "cd plex_generate_vid_previews_fork/ && source plex-env/bin/activate && python3 plex_generate_previews.py"
EXIT_STATUS=$?

# Calculate runtime
END_TIME=$(date +%s)
RUNTIME=$((END_TIME - START_TIME))
RUNTIME_FORMATTED=$(date -u -d @${RUNTIME} +"%H hours %M minutes %S seconds")

# Send email based on success or failure
if [ $EXIT_STATUS -eq 0 ]; then
    # Success email
    echo "Command completed successfully. Sending success email..."
    curl -s --user "api:$MAILGUN_API_KEY" \
      "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
      -F "from=$FROM_EMAIL" \
      -F "to=$TO_EMAIL" \
      -F "subject=✅ plex_generate_previews SUCCESS @ $(date)" \
      --form-string html="Plex generate previews completed successfully.<br><br>Runtime: $RUNTIME_FORMATTED"
else
    # Failure email
    echo "Command failed with exit status $EXIT_STATUS. Sending failure email..."
    curl -s --user "api:$MAILGUN_API_KEY" \
      "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
      -F "from=$FROM_EMAIL" \
      -F "to=$TO_EMAIL" \
      -F "subject=❌ plex_generate_previews FAILED @ $(date)" \
      --form-string html="Plex generate previews failed with exit status $EXIT_STATUS.<br><br>Runtime: $RUNTIME_FORMATTED"
fi
