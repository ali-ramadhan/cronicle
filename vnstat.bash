#!/bin/bash

# Load environment variables from .env file
echo "Loading email configuration from .env file..."
set -a  # automatically export all variables
source .env
set +a  # disable automatic export

VNSTAT_OUTPUT=$(vnstat -i eno1 | aha)

vnstati -i eno1 --large -vs -o vnstati_vs.png
vnstati -i eno1 --large -5g -o vnstati_5g.png
vnstati -i eno1 --large -d -o vnstati_d.png
vnstati -i eno1 --large -m -o vnstati_m.png

curl -s --user "api:$MAILGUN_API_KEY" \
  "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
  -F "from=$FROM_EMAIL" \
  -F "to=$TO_EMAIL" \
  -F "subject=vnstat @ $(date)" \
  --form-string html="${VNSTAT_OUTPUT}" \
  -F attachment=@vnstati_vs.png \
  -F attachment=@vnstati_5g.png \
  -F attachment=@vnstati_d.png \
  -F attachment=@vnstati_m.png

rm -v vnstati_vs.png vnstati_5g.png vnstati_d.png vnstati_m.png
