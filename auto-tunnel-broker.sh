#!/bin/bash
export USERNAME="$1"
export PASSWORD="$2"

COOKIE=$(curl -sS  -H 'Content-Type: application/x-www-form-urlencoded' \
             --data-urlencode "f_user=$USERNAME" \
             --data-urlencode "f_pass=$PASSWORD" \
             --data-urlencode "Login=Login" \
             -c - https://tunnelbroker.net/login.php)

function DeleteTunnel() {
    local id=$1
    curl "https://tunnelbroker.net/tunnel_detail.php?tid=$id" \
                --cookie <(echo "$COOKIE") \
                -H 'Content-Type: application/x-www-form-urlencoded' \
                --data-raw 'delete=Delete+Tunnel'
}

# https://forums.he.net/index.php?topic=3153.0

HOST_IPV4=$(hostname -I | awk '{print $1}')

function TunnelsBrokerClientv4() {
    local xml_data=$(curl -u "$USERNAME:$PASSWORD" https://tunnelbroker.net/tunnelInfo.php -sS)
    local tunnel_data
    local tunnel_id
    local server_v4
    local client_v4
    local server_v6
    local client_v6
    local routed64
    tunnel_data=$(echo "$xml_data" | sed -n '/<tunnel/,/<\/tunnel>/p')

    echo "$tunnel_data" | while IFS= read -r line; do
        if [[ $line =~ \<tunnel\ id=\"([0-9]+)\"\> ]]; then
            tunnel_id="${BASH_REMATCH[1]}"
        elif [[ $line =~ \<serverv4\>([0-9.]+)\</serverv4\> ]]; then
             server_v4="${BASH_REMATCH[1]}"
        elif [[ $line =~ \<serverv6\>(.*?)\</serverv6\> ]]; then
             server_v6="${BASH_REMATCH[1]}"
        elif [[ $line =~ \<clientv6\>(.*?)\</clientv6\> ]]; then
             client_v6="${BASH_REMATCH[1]}"
        elif [[ $line =~ \<routed64\>(.*?)\</routed64\> ]]; then
             routed64="${BASH_REMATCH[1]}"
             echo "$tunnel_id $server_v4 $client_v4 $server_v6 $client_v6 $routed64"
        elif [[ $line =~ \<clientv4\>([0-9.]+)\</clientv4\> ]]; then
            client_v4="${BASH_REMATCH[1]}"
        fi
    done
}

while IFS= read -r tunnel_id server_v4 client_v4 server_v6 client_v6 routed64; do
    if [ "$tunnel_v4" == "$HOST_IPV4" ]
    then
        echo "A tunnel already exists for your ip ($HOST_IPV4) with id of $tunnel_v4"
        echo "Removing..."
        DeleteTunnel "$tunnel_id"
        exit 0
    fi
done <<< "$(TunnelsBrokerClientv4)"


PingServer() {
    local ip=$1
    local server=$2
    local ping_result=$(ping -c 3 -w 3 $ip 2>/dev/null | awk -F '/' 'END {print $5}')
    if [ ! -z "$ping_result" ]; then
        echo "$ping_result $ip $server"
    fi
}
export -f PingServer

function ListServers() {
    local IP_SRV=$(curl 'https://tunnelbroker.net/new_tunnel.php' -sS --cookie <(echo "$COOKIE") | grep 'name="tserv"' | grep -oP '(?<=value=")[^"]*|(?<=>)[^<]+(?=<span)' | paste -d '\t' - -)
    local temp_file=$(mktemp)
    local pids=()

    while read -r ip server; do
        PingServer "$ip" "$server" >> "$temp_file" &
        pids+=($!)
    done <<< "$IP_SRV"

    # Wait for all background processes to finish
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Sort and format the results
    local RESULT=$(cat "$temp_file" | \
        awk '$1 != "" {printf "%.2f ms\t%s\t%s\n", $1, $2, $3}' | \
        sort -n)
    # Clean up
    rm "$temp_file"
    echo "$RESULT"
}

function SelectServer() {
    local -n out=$2
    local server_list="$1"
    local lines
    mapfile -t lines <<< "$server_list"
    local num_lines=${#lines[@]}
    local current_line=0
    local scroll_position=0

    # Get terminal height
    local term_height=$(tput lines)
    local display_height=$((term_height - 2))  # Reserve 2 lines for header and footer

    # Hide cursor
    tput civis

    # Clear screen and move cursor to top-left
    clear

    while true; do
        # Print header
        echo "Use arrow keys to navigate, Enter to select, q to quit"
        
        # Print visible lines
        for ((i=0; i<display_height; i++)); do
            local index=$((scroll_position + i))
            if [ $index -ge $num_lines ]; then
                break
            fi
            if [ $index -eq $current_line ]; then
                echo -e "\e[1;33m> ${lines[$index]}\e[0m"  # Highlight selected line
            else
                echo "  ${lines[$index]}"
            fi
        done

        # Print footer
        echo "Showing $((scroll_position + 1))-$((scroll_position + i)) of $num_lines"

        # Move cursor back to top
        tput cup 1 0

        # Read a single character
        read -s -n 1 key

        case "$key" in
            A)  # Up arrow
                if [ $current_line -gt 0 ]; then
                    ((current_line--))
                    if [ $current_line -lt $scroll_position ]; then
                        ((scroll_position--))
                    fi
                fi
                ;;
            B)  # Down arrow
                if [ $current_line -lt $((num_lines - 1)) ]; then
                    ((current_line++))
                    if [ $current_line -ge $((scroll_position + display_height)) ]; then
                        ((scroll_position++))
                    fi
                fi
                ;;
            '')  # Enter key
                clear
                # Show cursor
                tput cnorm
                out="${lines[$current_line]}"
                return
                ;;
            q)  # Quit
                clear
                # Show cursor
                tput cnorm
                echo "Selection cancelled."
                return
                ;;
        esac

        # Clear screen and move cursor to top-left
        clear
    done
}

function CreateTunnel() {
    TSERV=$1

    OUT=$(curl 'https://tunnelbroker.net/new_tunnel.php' \
      -sS -o ./create-tunnel -w '%header{location}' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --cookie <(echo "$COOKIE") \
      --data-raw "ipv4z=$HOST_IPV4&tserv=$TSERV&normaltunnel=Create+Tunnel")
    
    echo $OUT | grep -oP '(?<=tid=)\d+'
}

server_list=$(ListServers)
SERVER=""
SelectServer "$server_list" SERVER
TSERV=$(echo $SERVER | awk '{print $3}')
echo "Creating tunnel..."
TID=$(CreateTunnel "$TSERV")
echo "Tunnel created. Tunnel Id=$TSERV"

while IFS= read -r tunnel_id server_v4 client_v4 server_v6 client_v6 routed64; do
    if [ "$tunnel_id" == "$TID" ]
    then
        echo "Setting up tunnel..."
        sudo modprove -r sit
        sudo ifconfig sit0 up
        sudo ifconfig sit0 inet6 tunnel "::$server_v4"
        sudo ifconfig sit1 up
        sudo ifconfig sit1 inet6 add "$client_v6/64"
        sudo route -A inet6 add ::/0 dev sit1
        echo "Done! testing..."
        ping6 google.com
        break
    fi
done <<< "$(TunnelsBrokerClientv4)"