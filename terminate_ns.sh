#!/bin/bash

# Script to force-delete a Kubernetes namespace that is stuck in the "Terminating" state.
# This script automates the process of fetching the namespace's current state,
# removing the finalizers, and then posting the updated spec to the /finalize
# endpoint of the Kubernetes API server.

# --- Prerequisites ---
# - kubectl: Must be installed and configured to connect to your cluster.
# - jq: Must be installed. This is used to safely parse and manipulate JSON.
#   On macOS: brew install jq
#   On Debian/Ubuntu: sudo apt-get install jq
#   On CentOS/RHEL: sudo yum install jq

# --- Usage ---
# 1. Save this script as `terminate_ns.sh`.
# 2. Make it executable: `chmod +x terminate_ns.sh`
# 3. Run it with the namespace you want to terminate: `./terminate_ns.sh <namespace-name>`

set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail # The return value of a pipeline is the status of the last command to exit with a non-zero status.

# --- Check for Dependencies ---
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl command not found. Please install it and configure it for your cluster."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq command not found. Please install it to proceed."
    echo "  - macOS: brew install jq"
    echo "  - Debian/Ubuntu: sudo apt-get install jq"
    exit 1
fi

# --- Check for Namespace Argument ---
if [ -z "$1" ]; then
    echo "Usage: $0 <namespace-name>"
    exit 1
fi

NAMESPACE=$1
TEMP_JSON_FILE=$(mktemp) # Create a secure temporary file

# --- Main Logic ---

# Ensure cleanup happens on script exit (e.g., Ctrl+C)
# This trap will kill the proxy and remove the temp file.
trap ' {
    echo "---";
    echo "Cleaning up...";
    if kill -0 $PROXY_PID 2>/dev/null; then
        echo "Stopping kubectl proxy (PID: $PROXY_PID)...";
        kill $PROXY_PID;
    fi
    rm -f $TEMP_JSON_FILE;
    echo "Cleanup complete.";
} ' EXIT

echo "Attempting to force-terminate namespace: '$NAMESPACE'"
echo "---"

# 1. Get the namespace definition and remove finalizers using jq
echo "Step 1: Fetching namespace definition and removing finalizers..."
kubectl get namespace "$NAMESPACE" -o json | jq '.spec.finalizers = []' > "$TEMP_JSON_FILE"
if [ $? -ne 0 ]; then
    echo "Error: Failed to get namespace '$NAMESPACE' or process it with jq."
    exit 1
fi
echo "Successfully created modified namespace definition without finalizers."
echo "---"


# 2. Start kubectl proxy in the background
echo "Step 2: Starting 'kubectl proxy' in the background..."
kubectl proxy &
PROXY_PID=$! # Capture the process ID of the last background command
# Give the proxy a moment to start up
sleep 2
echo "'kubectl proxy' started with PID: $PROXY_PID"
echo "---"


# 3. Send the request to the finalize endpoint
echo "Step 3: Sending update request to the Kubernetes API server via the proxy..."
curl -k -H "Content-Type: application/json" -X PUT --data-binary @"$TEMP_JSON_FILE" http://127.0.0.1:8001/api/v1/namespaces/"$NAMESPACE"/finalize
if [ $? -ne 0 ]; then
    echo "Error: curl command failed. The namespace may not have been terminated."
    exit 1
fi
echo "" # Newline for better formatting after curl output
echo "---"
echo "Successfully sent finalize request. The namespace '$NAMESPACE' should now be removed."
echo "You can verify by running: kubectl get ns $NAMESPACE"

# The trap will handle the cleanup, so no explicit commands are needed here.
exit 0

