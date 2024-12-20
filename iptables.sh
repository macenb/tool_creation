
LOG='/var/log/ccdc/harden.log'
pm=""
sudo_group=""
ccdc_users=( "ccdcuser1" "ccdcuser2" )
debug="false"

function print_banner {
    echo
    echo "#######################################"
    echo "#"
    echo "#   $1"
    echo "#"
    echo "#######################################"
    echo
}

function get_input_string {
    read -r -p "$1" input
    echo "$input"
}

function get_input_list {
    local input_list=()

    while [ "$continue" != "false" ]; do
        input=$(get_input_string "Enter input: (one entry per line; hit enter to continue): ")
        if [ "$input" == "" ]; then
            continue="false"
        else
            input_list+=("$input")
        fi
    done

    # Return the list by printing it
    # Note: Bash functions can't return arrays directly, but we can print them
    echo "${input_list[@]}"
}


function detect_system_info {
    print_banner "Detecting system info"
    echo "[*] Detecting package manager"

    sudo which apt-get &> /dev/null
    apt=$?
    sudo which dnf &> /dev/null
    dnf=$?
    sudo which zypper &> /dev/null
    zypper=$?
    sudo which yum &> /dev/null
    yum=$?

    if [ $apt == 0 ]; then
        echo "[*] apt/apt-get detected (Debian-based OS)"
        echo "[*] Updating package list"
        sudo apt-get update
        pm="apt-get"
    elif [ $dnf == 0 ]; then
        echo "[*] dnf detected (Fedora-based OS)"
        pm="dnf"
    elif [ $zypper == 0 ]; then
        echo "[*] zypper detected (OpenSUSE-based OS)"
        pm="zypper"
    elif [ $yum == 0 ]; then
        echo "[*] yum detected (RHEL-based OS)"
        pm="yum"
    else
        echo "[X] ERROR: Could not detect package manager"
        exit 1
    fi

    echo "[*] Detecting sudo group"

    groups=$(compgen -g)
    if echo "$groups" | grep -q '^sudo$'; then
        echo '[*] sudo group detected'
        sudo_group='sudo'
    elif echo "$groups" | grep -q '^wheel$'; then
        echo '[*] wheel group detected'
        sudo_group='wheel'
    else
        echo '[X] ERROR: could not detect sudo group'
	exit 1
    fi
}

# currently defining for Ubuntu, will need changes for other distros
function setup_iptables {
    # TODO: this needs work/testing on different distros
    print_banner "Configuring iptables"
    echo "[*] Installing iptables packages"

    if [ "$pm" == 'apt-get' ]; then
        # Debian and Ubuntu
        sudo "$pm" install -y iptables iptables-persistent #ipset
        SAVE='/etc/iptables/rules.v4'
    elif [ "$pm" == 'dnf']
    elif [ "$pm" == 'dnf' ]; then
        # Fedora
        sudo "$pm" install -y iptables-services
        sudo systemctl enable iptables
        sudo systemctl start iptables
        SAVE='/etc/sysconfig/iptables'
    elif [ "$pm" == 'zypper' ]; then
        # OpenSUSE
        sudo zypper install iptables
        sudo systemctl enable iptables
        sudo systemctl start iptables
        SAVE='/etc/iptables/iptables.rules'
    fi

    # echo "[*] Creating private ip range ipset"
    # sudo ipset create PRIVATE-IP hash:net
    # sudo ipset add PRIVATE-IP 10.0.0.0/8
    # sudo ipset add PRIVATE-IP 172.16.0.0/12
    # sudo ipset add PRIVATE-IP 192.168.0.0/16
    # sudo ipset save | sudo tee /etc/ipset.conf
    # sudo systemctl enable ipset

    echo "[*] defining logging rules"
    sudo touch /etc/rsyslog.d/10-iptables.conf
    touch ~/config
    echo ':msg, contains, "iptables" -/var/log/iptables.log' > ~/config
    echo "& ~" >> ~/config
    sudo cp ~/config /etc/rsyslog.d/10-iptables.conf
    rm ~/config
    sudo systemctl restart rsyslog

    echo "[*] Creating INPUT rules"
    sudo iptables -P INPUT DROP
    sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
    # sudo iptables -A INPUT -i lo -j ACCEPT
    # sudo iptables -A INPUT -s 0.0.0.0/0 -j ACCEPT

    # TODO: maybe add another allowance to the ssh rule that it can only be from internal machines? figure out actual requirements
    echo "[*] Which *TCP* ports should be open for incoming traffic (INPUT)?"
    echo "[*] Warning: Do NOT forget to add 22/SSH if needed- please don't accidentally lock yourself out of the system!"
    ports=$(get_input_list)
    for port in $ports; do
        sudo iptables -A INPUT -p tcp --dport "$port" -j LOG --log-prefix "[iptables INPUT] traffic on port $port allowed: " --log-level 1
        sudo iptables -A INPUT -p tcp --dport "$port" -j LOG --log-prefix "[iptables] CHAIN=INPUT ACTION=ACCEPT " --log-level 1
        sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    done
    echo "[*] Which *UDP* ports should be open for incoming traffic (INPUT)?"
    ports=$(get_input_list)
    for port in $ports; do
        sudo iptables -A INPUT -p udp --dport "$port" -j LOG --log-prefix "[iptables] INPUT traffic on port $port allowed: " --log-level 1
        sudo iptables -A INPUT -p udp --dport "$port" -j LOG --log-prefix "[iptables] CHAIN=INPUT ACTION=ACCEPT " --log-level 1
        sudo iptables -A INPUT -p udp --dport "$port" -j ACCEPT
    done
    # This will log dropped traffic. May be useful for enumerating attacking ip addresses???
    sudo iptables -A INPUT -j LOG --log-prefix "[iptables] CHAIN=INPUT ACTION=DROP "

    echo "[*] Creating OUTPUT rules"
    # TODO: how to harden output?
    # sudo iptables -P OUTPUT DROP
    # sudo iptables -A OUTPUT -o lo -j ACCEPT
    # sudo iptables -A OUTPUT -p tcp -m multiport --dport 80,443 -m set ! --match-set PRIVATE-IP dst -j ACCEPT
    # Web traffic
    sudo iptables -N WEB
    sudo iptables -A OUTPUT -p tcp -m multiport --dport 80,443 -j WEB
    sudo iptables -A WEB -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 -j LOG --log-prefix "[iptables] OUTPUT WEB/private ip "
    sudo iptables -A WEB -d 10.0.0.0/8,172.16.0.0/12,192.168.0.0/16 -j LOG --log-prefix "[iptables] CHAIN=OUTPUT ACTION=ACCEPT "
    sudo iptables -A WEB -j ACCEPT
    # DNS traffic
    sudo iptables -A OUTPUT -p udp --dport 53 -j LOG --log-prefix "[iptables] OUTPUT DNS traffic : " --log-level 1
    sudo iptables -A OUTPUT -p udp --dport 53 -j LOG --log-prefix "[iptables] CHAIN=OUTPUT ACTION=ACCEPT " --log-level 1
    sudo iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    # other allowances
    sudo iptables -A OUTPUT -p icmp -j ACCEPT

    echo "[*] Saving rules"
    # sudo iptables-save | sudo tee $SAVE
}

detect_system_info
setup_iptables