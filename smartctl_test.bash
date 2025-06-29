#!/bin/bash

# Configuration
# Auto-detect all SATA/SCSI drives
DRIVES=()

# Skip SSDs by default (set to false if you want to test SSDs)
SKIP_SSDS=true

# Skip drives that don't work with smartctl (set to false to attempt testing all drives)
SKIP_INACCESSIBLE_DRIVES=true

# Add SATA/SCSI drives (only base drives, not partitions)
for drive in /sys/block/sd*; do
    if [ -d "$drive" ]; then
        drive_name="/dev/$(basename "$drive")"
        if [ -b "$drive_name" ]; then
            DRIVES+=("$drive_name")
        fi
    fi
done

# Function to check if smartctl can access a drive
can_access_drive() {
    local drive="$1"

    # Try basic smartctl info command
    if sudo smartctl -i "$drive" >/dev/null 2>&1; then
        return 0  # Can access
    fi

    return 1  # Cannot access
}

# Function to check if a drive is an SSD
is_ssd() {
    local drive="$1"
    local smart_info

    # Get SMART information and check for SSD indicators
    smart_info=$(sudo smartctl -i "$drive" 2>/dev/null)
    if [ $? -ne 0 ]; then
        return 1  # Can't determine, assume not SSD
    fi

    # Check for common SSD indicators
    if echo "$smart_info" | grep -q "Rotation Rate:.*Solid State Device"; then
        return 0  # Is SSD
    elif echo "$smart_info" | grep -q "Form Factor:.*M.2\|mSATA\|2.5"; then
        # Additional check for form factor (though not 100% reliable)
        if echo "$smart_info" | grep -q "Device Model:.*SSD\|Solid State"; then
            return 0  # Is SSD
        fi
    fi

    return 1  # Not SSD
}

# Filter out SSDs and inaccessible drives
if [ "$SKIP_SSDS" = true ] || [ "$SKIP_INACCESSIBLE_DRIVES" = true ]; then
    echo "Checking drives for SSDs and inaccessible drives to skip..."
    FILTERED_DRIVES=()
    SKIPPED_DRIVES=()

    for drive in "${DRIVES[@]}"; do
        skip_drive=false

        # Check if smartctl can access the drive
        if [ "$SKIP_INACCESSIBLE_DRIVES" = true ] && ! can_access_drive "$drive"; then
            echo "Skipping inaccessible drive: $drive (smartctl cannot access)"
            SKIPPED_DRIVES+=("$drive (inaccessible)")
            skip_drive=true
        fi

        # Check if it's an SSD and should be skipped
        if [ "$skip_drive" = false ] && [ "$SKIP_SSDS" = true ] && is_ssd "$drive"; then
            echo "Skipping SSD: $drive"
            SKIPPED_DRIVES+=("$drive (SSD)")
            skip_drive=true
        fi

        # Add drive if not skipped
        if [ "$skip_drive" = false ]; then
            FILTERED_DRIVES+=("$drive")
        fi
    done

    DRIVES=("${FILTERED_DRIVES[@]}")

    if [ ${#SKIPPED_DRIVES[@]} -gt 0 ]; then
        echo "Skipped ${#SKIPPED_DRIVES[@]} drive(s):"
        for skipped in "${SKIPPED_DRIVES[@]}"; do
            echo "  - $skipped"
        done
    fi
fi

# Check if any drives were found
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "No SATA/SCSI drives found on this system!"
    if [ "$SKIP_SSDS" = true ] && [ ${#SKIPPED_DRIVES[@]} -gt 0 ]; then
        echo "Note: ${#SKIPPED_DRIVES[@]} drive(s) were skipped due to filtering"
        echo "Set SKIP_SSDS=false and SKIP_INACCESSIBLE_DRIVES=false to test all drives"
    fi
    exit 1
fi

echo "Detected drives for testing: ${DRIVES[*]}"

TEST_TYPE="short"
CONCURRENT_TESTS=4
POLL_INTERVAL=10

# Handle existing SMART tests (true = wait for completion, false = abort and start fresh)
WAIT_FOR_EXISTING_TESTS=true

# Load environment variables from .env file
echo "Loading email configuration from .env file..."
set -a  # automatically export all variables
source .env
set +a  # disable automatic export

HOSTNAME=$(hostname)
TOTAL_DRIVES=${#DRIVES[@]}
WORK_DIR="/tmp/smartctl_tests_$$"
mkdir -p "$WORK_DIR"

# Cleanup function
cleanup() {
    rm -rf "$WORK_DIR"
    jobs -p | xargs -r kill 2>/dev/null
}
trap cleanup EXIT

# Function to send email notification
send_email() {
    local drive="$1"
    local status="$2"
    local log_file="$3"
    local start_time="$4"
    local end_time="$5"

    local duration=$((end_time - start_time))
    local duration_formatted=$(printf "%02d:%02d:%02d" $((duration/3600)) $((duration%3600/60)) $((duration%60)))

    # Get mount point information
    local mount_point=""
    # First try the drive itself, then its numbered partitions
    local mount_info=$(lsblk -no MOUNTPOINT "$drive" 2>/dev/null | grep -v '^$' | head -1)
    if [ -z "$mount_info" ] || [ "$mount_info" = "" ]; then
        mount_info=$(lsblk -no MOUNTPOINT "$drive"[0-9]* 2>/dev/null | grep -v '^$' | head -1)
    fi
    if [ -n "$mount_info" ] && [ "$mount_info" != "" ]; then
        mount_point=" ($mount_info)"
    else
        # Try alternative method with findmnt
        mount_info=$(findmnt -rno TARGET -S "$drive" 2>/dev/null | head -1)
        if [ -z "$mount_info" ] || [ "$mount_info" = "" ]; then
            mount_info=$(findmnt -rno TARGET -S "$drive"[0-9]* 2>/dev/null | head -1)
        fi
        if [ -n "$mount_info" ] && [ "$mount_info" != "" ]; then
            mount_point=" ($mount_info)"
        fi
    fi

    # Get drive age from SMART data
    local drive_age_text="Unknown"
    local power_on_hours=$(sudo smartctl -A "$drive" 2>/dev/null | grep -i "Power_On_Hours" | awk '{print $10}' | head -1)
    if [ -n "$power_on_hours" ] && [ "$power_on_hours" -gt 0 ] 2>/dev/null; then
        local total_days=$((power_on_hours / 24))
        local years=$((total_days / 365))
        local remaining_days=$((total_days % 365))
        local months=$((remaining_days / 30))
        local days=$((remaining_days % 30))

        if [ $years -gt 0 ]; then
            if [ $months -gt 0 ]; then
                if [ $days -gt 0 ]; then
                    drive_age_text="${years} years, ${months} months, ${days} days"
                else
                    drive_age_text="${years} years, ${months} months"
                fi
            else
                if [ $days -gt 0 ]; then
                    drive_age_text="${years} years, ${days} days"
                else
                    drive_age_text="${years} years"
                fi
            fi
        elif [ $months -gt 0 ]; then
            if [ $days -gt 0 ]; then
                drive_age_text="${months} months, ${days} days"
            else
                drive_age_text="${months} months"
            fi
        else
            drive_age_text="${days} days"
        fi
        drive_age_text="$drive_age_text (${power_on_hours} hours total)"
    fi

    # Get drive capacity
    local capacity_text="Unknown"
    local capacity_bytes=$(lsblk -bno SIZE "$drive" 2>/dev/null | head -1)
    if [ -n "$capacity_bytes" ] && [ "$capacity_bytes" -gt 0 ] 2>/dev/null; then
        local capacity_gb=$((capacity_bytes / (1000**3)))
        local capacity_gib=$((capacity_bytes / (1024**3)))
        local capacity_tb=$((capacity_bytes / (1000**4)))
        local capacity_tib=$((capacity_bytes / (1024**4)))

        if [ $capacity_tb -gt 0 ]; then
            local tb_decimal=$((capacity_bytes * 10 / (1000**4) % 10))
            local tib_decimal=$((capacity_bytes * 10 / (1024**4) % 10))
            capacity_text="${capacity_tb}.${tb_decimal} TB (${capacity_tib}.${tib_decimal} TiB)"
        else
            capacity_text="${capacity_gb} GB (${capacity_gib} GiB)"
        fi
    fi

    # Get drive usage (if mounted)
    local usage_text="Not mounted"
    if [ -n "$mount_info" ] && [ "$mount_info" != "" ]; then
        local df_output=$(df -B1 "$mount_info" 2>/dev/null | tail -1)
        if [ -n "$df_output" ]; then
            local used_bytes=$(echo "$df_output" | awk '{print $3}')
            local total_bytes=$(echo "$df_output" | awk '{print $2}')
            local use_percent=$(echo "$df_output" | awk '{print $5}' | tr -d '%')

            if [ -n "$used_bytes" ] && [ "$used_bytes" -gt 0 ] 2>/dev/null; then
                local used_gb=$((used_bytes / (1000**3)))
                local used_gib=$((used_bytes / (1024**3)))
                local used_tb=$((used_bytes / (1000**4)))
                local used_tib=$((used_bytes / (1024**4)))

                if [ $used_tb -gt 0 ]; then
                    local tb_decimal=$((used_bytes * 10 / (1000**4) % 10))
                    local tib_decimal=$((used_bytes * 10 / (1024**4) % 10))
                    usage_text="${used_tb}.${tb_decimal} TB (${used_tib}.${tib_decimal} TiB) - ${use_percent}% full"
                else
                    usage_text="${used_gb} GB (${used_gib} GiB) - ${use_percent}% full"
                fi
            fi
        fi
    fi

    # Determine subject based on status
    local subject
    if [ "$status" = "completed" ]; then
        subject="✅ SMART Test PASSED - $drive on $HOSTNAME - $(date)"
    else
        subject="❌ SMART Test FAILED - $drive on $HOSTNAME - $(date)"
    fi

    # Get detailed SMART information
    local smart_info
    smart_info=$(sudo smartctl -a "$drive" 2>/dev/null || echo "Could not retrieve SMART information")

    local selftest_results
    selftest_results=$(sudo smartctl -l selftest "$drive" 2>/dev/null || echo "Could not retrieve self-test results")

    # Create HTML email body
    local html_body
    html_body=$(cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: $([ "$status" = "completed" ] && echo "#d4edda" || echo "#f8d7da");
                  padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .status-pass { color: #155724; }
        .status-fail { color: #721c24; }
        .drive-info { font-family: 'Courier New', Consolas, monospace; font-weight: bold; }
        .section { margin-bottom: 20px; }
        .section h3 { color: #333; border-bottom: 2px solid #007bff; padding-bottom: 5px; }
        pre { background-color: #f8f9fa; padding: 10px; border-radius: 5px; overflow-x: auto; font-size: 12px; }
        .summary-table { border-collapse: collapse; width: 100%; }
        .summary-table th, .summary-table td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        .summary-table th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h2 class="$([ "$status" = "completed" ] && echo "status-pass" || echo "status-fail")">
            SMART Test $([ "$status" = "completed" ] && echo "PASSED" || echo "FAILED") - <span class="drive-info">$drive$mount_point</span>
        </h2>
        <p><strong>Host:</strong> $HOSTNAME</p>
        <p><strong>Test Type:</strong> $TEST_TYPE</p>
        <p><strong>Duration:</strong> $duration_formatted</p>
        <p><strong>Completed:</strong> $(date -d "@$end_time")</p>
    </div>

    <div class="section">
        <h3>Test Summary</h3>
        <table class="summary-table">
            <tr><th>Drive</th><td>$drive$mount_point</td></tr>
            <tr><th>Drive Age</th><td>$drive_age_text</td></tr>
            <tr><th>Drive Capacity</th><td>$capacity_text</td></tr>
            <tr><th>Drive Usage</th><td>$usage_text</td></tr>
            <tr><th>Test Type</th><td>$TEST_TYPE</td></tr>
            <tr><th>Status</th><td>$([ "$status" = "completed" ] && echo "PASSED" || echo "FAILED")</td></tr>
            <tr><th>Start Time</th><td>$(date -d "@$start_time")</td></tr>
            <tr><th>End Time</th><td>$(date -d "@$end_time")</td></tr>
            <tr><th>Duration</th><td>$duration_formatted</td></tr>
        </table>
    </div>

    <div class="section">
        <h3>Self-Test Results</h3>
        <pre>$selftest_results</pre>
    </div>

    <div class="section">
        <h3>Full SMART Information</h3>
        <pre>$smart_info</pre>
    </div>

    <div class="section">
        <h3>Test Log</h3>
        <pre>$(cat "$log_file" 2>/dev/null || echo "No log file available")</pre>
    </div>

    <hr>
    <p><small>Generated by SMART test script on $HOSTNAME at $(date)</small></p>
</body>
</html>
EOF
)

    # Send email via Mailgun
    echo "Sending email notification for $drive ($status)..."
    curl -s --user "api:$MAILGUN_API_KEY" \
        "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
        -F "from=$FROM_EMAIL" \
        -F "to=$TO_EMAIL" \
        -F "subject=$subject" \
        --form-string "html=$html_body" \
        > /dev/null

    if [ $? -eq 0 ]; then
        echo "Email sent successfully for $drive"
    else
        echo "Failed to send email for $drive"
    fi
}

echo "Starting staggered SMART tests on $TOTAL_DRIVES drives..."
echo "0%"

# Function to test a single drive
test_drive() {
    local drive="$1"
    local drive_index="$2"
    local status_file="$WORK_DIR/status_${drive_index}"
    local log_file="$WORK_DIR/log_${drive_index}"
    local start_time_file="$WORK_DIR/start_${drive_index}"

    # Create status file
    echo "waiting" > "$status_file"

    # Record start time
    local start_time=$(date +%s)
    echo "$start_time" > "$start_time_file"

    echo "starting" > "$status_file"
    echo "Starting $TEST_TYPE test on $drive at $(date)" >> "$log_file"

    # Check if a test is already running
    if sudo smartctl -a "$drive" | grep -q "Self-test routine in progress" 2>/dev/null; then
        if [ "$WAIT_FOR_EXISTING_TESTS" = true ]; then
            echo "🔄 Existing test found running on $drive, waiting for completion..." >> "$log_file"
            echo "Existing SMART test detected on $drive, monitoring until completion..."
            echo "running" > "$status_file"

            # Monitor the existing test until completion
            while sudo smartctl -a "$drive" | grep -q "Self-test routine in progress" 2>/dev/null; do
                echo "Existing test still running on $drive..." >> "$log_file"
                sleep 30
            done

            local end_time=$(date +%s)
            echo "Existing test completed on $drive at $(date)" >> "$log_file"

            # Check if the existing test passed or failed
            if sudo smartctl -l selftest "$drive" | head -10 | grep -q "Completed without error"; then
                echo "completed" > "$status_file"
                echo "✅ Existing test PASSED on $drive" >> "$log_file"
                send_email "$drive" "completed" "$log_file" "$start_time" "$end_time"
            else
                echo "failed" > "$status_file"
                echo "❌ Existing test FAILED on $drive" >> "$log_file"
                send_email "$drive" "failed" "$log_file" "$start_time" "$end_time"
            fi
            return
        else
            echo "🛑 Existing test found running on $drive, aborting to start fresh test..." >> "$log_file"
            echo "Aborting existing SMART test on $drive to start fresh..."
            if sudo smartctl -X "$drive" >> "$log_file" 2>&1; then
                echo "Successfully aborted existing test on $drive" >> "$log_file"
                sleep 5  # Give drive a moment to reset
            else
                echo "Warning: Failed to abort existing test on $drive, will try to force new test" >> "$log_file"
            fi
        fi
    fi

    # Start the test
    if sudo smartctl -t "$TEST_TYPE" "$drive" >> "$log_file" 2>&1; then
        echo "running" > "$status_file"
        echo "Test started successfully on $drive" >> "$log_file"

        # Monitor test progress
        while sudo smartctl -a "$drive" | grep -q "Self-test routine in progress" 2>/dev/null; do
            echo "Test still running on $drive..." >> "$log_file"
            sleep 30
        done

        local end_time=$(date +%s)
        echo "Test completed on $drive at $(date)" >> "$log_file"

        # Check if test passed or failed
        if sudo smartctl -l selftest "$drive" | head -10 | grep -q "Completed without error"; then
            echo "completed" > "$status_file"
            echo "✅ Test PASSED on $drive" >> "$log_file"
            send_email "$drive" "completed" "$log_file" "$start_time" "$end_time"
        else
            echo "failed" > "$status_file"
            echo "❌ Test FAILED on $drive" >> "$log_file"
            send_email "$drive" "failed" "$log_file" "$start_time" "$end_time"
        fi
    else
        local end_time=$(date +%s)
        echo "failed_start" > "$status_file"
        echo "❌ Failed to start test on $drive at $(date)" >> "$log_file"
        send_email "$drive" "failed_start" "$log_file" "$start_time" "$end_time"
    fi
}

# Function to count running jobs
count_running_tests() {
    local running_count=0
    for i in "${!DRIVES[@]}"; do
        status_file="$WORK_DIR/status_${i}"
        if [ -f "$status_file" ]; then
            local status=$(cat "$status_file")
            if [ "$status" = "starting" ] || [ "$status" = "running" ]; then
                ((running_count++))
            fi
        fi
    done
    echo $running_count
}

# Start tests with concurrency control
echo "Launching tests with concurrency limit of $CONCURRENT_TESTS..."
test_queue=()
for i in "${!DRIVES[@]}"; do
    test_queue+=("$i")
done

# Monitor overall progress and launch new tests as slots become available
start_time=$(date +%s)
last_progress=-1
test_index=0

# Launch initial batch of tests
while [ $test_index -lt $TOTAL_DRIVES ] && [ $test_index -lt $CONCURRENT_TESTS ]; do
    i=${test_queue[$test_index]}
    echo "Starting test for ${DRIVES[$i]} (slot $((i+1))/$TOTAL_DRIVES)"
    test_drive "${DRIVES[$i]}" "$i" &
    sleep 1  # Brief delay to let status file be created
    ((test_index++))
done

while true; do
    # Launch new tests if we have available slots and remaining tests
    while [ $test_index -lt $TOTAL_DRIVES ] && [ $(count_running_tests) -lt $CONCURRENT_TESTS ]; do
        i=${test_queue[$test_index]}
        echo "Starting test for ${DRIVES[$i]} (slot $((i+1))/$TOTAL_DRIVES)"
        test_drive "${DRIVES[$i]}" "$i" &
        sleep 1  # Brief delay to let status file be created
        ((test_index++))
    done

    # Count drives in each state
    waiting=0
    starting=0
    running=0
    completed=0
    failed=0

    for i in "${!DRIVES[@]}"; do
        status_file="$WORK_DIR/status_${i}"
        if [ -f "$status_file" ]; then
            case $(cat "$status_file") in
                "waiting") ((waiting++)) ;;
                "starting") ((starting++)) ;;
                "running") ((running++)) ;;
                "completed") ((completed++)) ;;
                "failed"|"failed_start") ((failed++)) ;;
            esac
        else
            ((waiting++))
        fi
    done

    # Calculate progress
    # Weight the progress: completed drives = 100%, running drives = 50%
    total_progress=$(( (completed * 100 + running * 50 + failed * 100) / TOTAL_DRIVES ))

    # Only report progress if it changed
    if [ "$total_progress" != "$last_progress" ]; then
        echo "${total_progress}%"
        last_progress=$total_progress
    fi

    # Show status summary
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    active_tests=$((starting + running))
    echo "Status after ${elapsed}s: Active: $active_tests/$CONCURRENT_TESTS, Waiting: $waiting, Completed: $completed, Failed: $failed"

    # Check if all drives are done
    if [ $((completed + failed)) -eq $TOTAL_DRIVES ]; then
        break
    fi

    sleep $POLL_INTERVAL
done

echo "100%"
echo "All drive tests completed!"

# Generate final summary
echo ""
echo "=== FINAL RESULTS SUMMARY ==="
completed_count=0
failed_count=0

for i in "${!DRIVES[@]}"; do
    drive="${DRIVES[$i]}"
    status_file="$WORK_DIR/status_${i}"

    if [ -f "$status_file" ]; then
        status=$(cat "$status_file")
        case "$status" in
            "completed")
                echo "✅ $drive: PASSED"
                ((completed_count++))
                ;;
            "failed"|"failed_start")
                echo "❌ $drive: FAILED"
                ((failed_count++))
                ;;
        esac
    else
        echo "❓ $drive: Unknown status"
        ((failed_count++))
    fi
done

echo ""
echo "FINAL SUMMARY: $completed_count successful, $failed_count failed out of $TOTAL_DRIVES drives"

# Send a final summary email
if [ $TOTAL_DRIVES -gt 1 ]; then
    summary_subject="📊 SMART Test Summary - $completed_count/$TOTAL_DRIVES drives passed on $HOSTNAME"
    summary_html=$(cat <<EOF
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #e7f3ff; padding: 15px; border-radius: 5px; margin-bottom: 20px; }
        .pass { color: green; }
        .fail { color: red; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
    </style>
</head>
<body>
    <div class="header">
        <h2>SMART Test Summary - $HOSTNAME</h2>
        <p><strong>Total Drives:</strong> $TOTAL_DRIVES</p>
        <p><strong>Passed:</strong> <span class="pass">$completed_count</span></p>
        <p><strong>Failed:</strong> <span class="fail">$failed_count</span></p>
        <p><strong>Completed:</strong> $(date)</p>
    </div>

    <table>
        <tr><th>Drive</th><th>Status</th></tr>
$(for i in "${!DRIVES[@]}"; do
    drive="${DRIVES[$i]}"
    status_file="$WORK_DIR/status_${i}"
    if [ -f "$status_file" ]; then
        status=$(cat "$status_file")
        case "$status" in
            "completed") echo "        <tr><td>$drive</td><td class=\"pass\">✅ PASSED</td></tr>" ;;
            *) echo "        <tr><td>$drive</td><td class=\"fail\">❌ FAILED</td></tr>" ;;
        esac
    fi
done)
    </table>
</body>
</html>
EOF
)

    curl -s --user "api:$MAILGUN_API_KEY" \
        "https://api.mailgun.net/v3/$MAILGUN_DOMAIN/messages" \
        -F "from=$FROM_EMAIL" \
        -F "to=$TO_EMAIL" \
        -F "subject=$summary_subject" \
        --form-string "html=$summary_html" \
        > /dev/null
fi

# Exit with error code if any tests failed
if [ $failed_count -gt 0 ]; then
    echo "Some tests failed - check individual email reports"
    exit 1
else
    echo "All tests completed successfully!"
    exit 0
fi
