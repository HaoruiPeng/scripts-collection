#!/bin/bash

# #############################################################################
#
# A shell script to find and force delete OpenStack resource of a cluster
#
# Usage:
#   ./terminate_cluster_openstack.sh <cluster_name>
#
# Description:
#   This script lists all resources that contain the cluster name. It will then
#   display the list of matching resources and ask for confirmation before
#   deleting them.
#
# Dependencies:
#   - openstack-client: This script requires the OpenStack command-line
#     client to be installed and configured with the appropriate credentials.
#
# #############################################################################

# --- Configuration & Arguments ---

# Exit immediately if a command exits with a non-zero status.
set -e

openstack_loadbalancer() {
  # This is your original alias command
  "$HOME"/.local/share/pipx/venvs/python-octaviaclient/bin/openstack loadbalancer
}

# The string to search for in server names, provided as the first argument.
CLUSTER="$1"

# --- Input Validation ---

# Check if the user provided a search string.
if [ -z "$CLUSTER" ]; then
  echo "Error: No cluster provided."
  echo "Usage: $0 <cluster_name>"
  exit 1
fi

# --- Find Matching Resources ---

echo "Searching for resources with names containing: '$CLUSTER'"

echo "Finding matching servers..."
SERVER_LIST=$(openstack server list --name "$CLUSTER" -f value -c ID -c Name)

echo "Finding matching load balancers..."
LOADBALANCER_LIST=$(openstack_loadbalancer list -f value -c id -c name | grep "$CLUSTER" || true)

echo "Finding matching routers..."
ROUTER_LIST=$(openstack router list -f value -c ID -c Name | grep "$CLUSTER" || true)

echo "Finding matching networks..."
NETWORK_LIST=$(openstack network list -f value -c ID -c Name | grep "$CLUSTER" || true)

# Find security groups matching the name, excluding the 'default' group.
echo "Finding matching security groups..."
SECURITY_GROUP_LIST=$(openstack security group list -f value -c ID -c Name | grep "$CLUSTER" | grep -v " default" || true)


# Check if any resources were found.
if [ -z "$SERVER_LIST" ] && [ -z "$LOADBALANCER_LIST" ] && [ -z "$ROUTER_LIST" ] && [ -z "$NETWORK_LIST" ] && [ -z "$SECURITY_GROUP_LIST" ]; then
  echo "No servers, load balancers, routers, networks, or security groups found matching the name: '$CLUSTER'"
  exit 0
fi

# --- Confirmation ---

echo "The following resources will be DELETED:"
echo "========================================"

if [ -n "$SERVER_LIST" ]; then
    echo
    echo "SERVERS:"
    echo "---------------------------------------"
    echo "$SERVER_LIST"
    echo "---------------------------------------"
fi

if [ -n "$LOADBALANCER_LIST" ]; then
    echo
    echo "LOAD BALANCERS:"
    echo "---------------------------------------"
    echo "$LOADBALANCER_LIST"
    echo "---------------------------------------"
fi

if [ -n "$ROUTER_LIST" ]; then
    echo
    echo "ROUTERS:"
    echo "---------------------------------------"
    echo "$ROUTER_LIST"
    echo "---------------------------------------"
fi

if [ -n "$NETWORK_LIST" ]; then
    echo
    echo "NETWORKS:"
    echo "---------------------------------------"
    echo "$NETWORK_LIST"
    echo "---------------------------------------"
fi

if [ -n "$SECURITY_GROUP_LIST" ]; then
    echo
    echo "SECURITY GROUPS:"
    echo "---------------------------------------"
    echo "$SECURITY_GROUP_LIST"
    echo "---------------------------------------"
fi
echo

# --- Deletion Logic ---

read -p "Are you sure you want to delete ALL of these resources? (y/n): " CONFIRMATION

if [[ "$CONFIRMATION" == "y" || "$CONFIRMATION" == "Y" ]]; then
    # Delete Servers
    if [ -n "$SERVER_LIST" ]; then
        echo
        echo "--- Starting Server Deletion ---"
        echo "$SERVER_LIST" | while read -r SERVER_ID SERVER_NAME; do
            if [ -n "$SERVER_ID" ]; then
            echo "Deleting server: $SERVER_NAME (ID: $SERVER_ID)..."
            openstack server delete "$SERVER_ID"
            fi
        done
    echo "Server deletion complete."
    fi


    # Delete Load Balancers
    if [ -n "$LOADBALANCER_LIST" ]; then
        echo
        echo "Starting deleting loadbalancers..."
        echo "$LOADBALANCER_LIST" | while read -r LB_ID LB_NAME; do
            if [ -n "$LB_ID" ]; then
                echo "Processing load balancer: $LB_NAME (ID: $LB_ID)..."

                # Find and disassociate the floating IP
                VIP_PORT_ID=$(openstack_loadbalancer show "$LB_ID" -c vip_port_id -f value)
                if [ -n "$VIP_PORT_ID" ]; then
                    FIP_ID=$(openstack floating ip list --port "$VIP_PORT_ID" -c ID -f value)
                    if [ -n "$FIP_ID" ]; then
                        echo "  -> Found and disassociating Floating IP: $FIP_ID"
                        openstack floating ip unset --port "$VIP_PORT_ID" "$FIP_ID"
                    else
                        echo "  -> No floating IP associated."
                    fi
                fi

                # Delete the load balancer and its associated resources
                echo "  -> Deleting load balancer (cascade)..."
                openstack_loadbalancer delete "$LB_ID" --cascade
                echo "Deletion of $LB_NAME complete."
            fi
        done
        echo "Load balancer deletion complete."
    fi

    # Delete Routers
    if [ -n "$ROUTER_LIST" ]; then
        echo
        echo "Start deleting routers..."
        echo "$ROUTER_LIST" | while read -r ROUTER_ID ROUTER_NAME; do
        if [ -n "$ROUTER_ID" ]; then
            echo "Processing router: $ROUTER_NAME (ID: $ROUTER_ID)..."

            # CORRECTED ORDER: Remove all internal router interfaces (ports) FIRST.
            PORT_IDS=$(openstack port list --router "$ROUTER_ID" --device-owner network:router_interface -c ID -f value)
            if [ -n "$PORT_IDS" ]; then
                echo "  -> Removing router interfaces..."
                echo "$PORT_IDS" | while read -r PORT_ID; do
                    if [ -n "$PORT_ID" ]; then
                        # Get subnet ID from port to use `router remove subnet`
                        SUBNET_ID=$(openstack port show "$PORT_ID" -c fixed_ips -f value | sed -n "s/.*subnet_id='\(.*\)', ip_address.*/\1/p")
                        if [ -n "$SUBNET_ID" ]; then
                            echo "    -> Removing interface to subnet $SUBNET_ID from router..."
                            openstack router remove subnet "$ROUTER_ID" "$SUBNET_ID"
                        fi
                    fi
                done
            else
                echo "  -> No internal interfaces to remove."
            fi

            # Clear the external gateway if it exists
            GATEWAY_INFO=$(openstack router show "$ROUTER_ID" -c external_gateway_info -f value)
            if [ "$GATEWAY_INFO" != "None" ] && [ -n "$GATEWAY_INFO" ]; then
                echo "  -> Clearing external gateway..."
                openstack router unset --external-gateway "$ROUTER_ID"
            else
                echo "  -> No external gateway to clear."
            fi

            # Delete the router
            echo "  -> Deleting router..."
            openstack router delete "$ROUTER_ID"
            echo "Deletion of $ROUTER_NAME complete."
        fi
        done
        echo "Router deletion complete."
    fi

    #Delete networks
    if [ -n "$NETWORK_LIST" ]; then
    echo
    echo "Starte deleting networks..."
    echo "$NETWORK_LIST" | while read -r NET_ID NET_NAME; do
        if [ -n "$NET_ID" ]; then
            echo "Processing network: $NET_NAME (ID: $NET_ID)..."

            # Find and delete ports attached to the network that are not owned by network services
            # (DHCP and Router ports are handled by their parent resource deletions)
            PORT_IDS=$(openstack port list --network "$NET_ID" -c ID -c device_owner -f value | grep -v "network:")
            if [ -n "$PORT_IDS" ]; then
                echo "  -> Deleting attached ports..."
                echo "$PORT_IDS" | while read -r PORT_ID PORT_OWNER; do
                    if [ -n "$PORT_ID" ]; then
                        echo "    -> Deleting port $PORT_ID..."
                        openstack port delete "$PORT_ID"
                    fi
                done
            else
                echo "  -> No user-created ports to delete."
            fi

            # Find and delete subnets in the network
            SUBNET_IDS=$(openstack subnet list --network "$NET_ID" -c ID -f value)
            if [ -n "$SUBNET_IDS" ]; then
                echo "  -> Deleting subnets..."
                echo "$SUBNET_IDS" | while read -r SUBNET_ID; do
                    if [ -n "$SUBNET_ID" ]; then
                        echo "    -> Deleting subnet $SUBNET_ID..."
                        openstack subnet delete "$SUBNET_ID"
                    fi
                done
            else
                echo "  -> No subnets to delete."
            fi

            # Delete the network itself
            echo "  -> Deleting network..."
            openstack network delete "$NET_ID"
            echo "Deletion of $NET_NAME complete."
        fi
    done
    echo "Network deletion complete."
    fi

    # Delete Security Groups
    if [ -n "$SECURITY_GROUP_LIST" ]; then
        echo
        echo "Starting deleting security groups..."
        echo "$SECURITY_GROUP_LIST" | while read -r SG_ID SG_NAME; do
            if [ -n "$SG_ID" ]; then
                echo "Deleting security group: $SG_NAME (ID: $SG_ID)..."
                openstack security group delete "$SG_ID"
            fi
        done
        echo "Security group deletion complete."
    fi
    
    echo
    echo "All operations finished."
    else
    echo "Deletion aborted by user."
fi
exit 0