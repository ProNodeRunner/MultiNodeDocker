#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/multinode.conf"
BASE_IP="192.168.1.100"
NETWORK_INTERFACE="eth0"
TIMEZONE="Europe/Moscow"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
NC='\033[0m'

declare -A HW_PROFILES=(
    ["basic"]="CPU=4,RAM=8,SSD=512"
    ["pro"]="CPU=8,RAM=32,SSD=2048"
    ["ultra"]="CPU=16,RAM=128,SSD=4096"
)

show_menu() {
    clear
    echo -e "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo -e "=== MultiNodeDocker ==="
    echo -e "\n\n\n"
    echo " ༺ Многоузловая Установка Pro v2.0 ༻ "
    echo "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    echo "1) Установить все компоненты"
    echo "2) Задать количество нод"
    echo "3) Проверить работу контейнеров"
    echo "4) Проверить отпечатки"
    echo "5) Выход"
    echo -e "${NC}"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p /etc/needrestart/conf.d
    echo -e "\$nrconf{restart} = 'a';\n\$nrconf{kernelhints} = 0;" > /etc/needrestart/conf.d/99-disable.conf

    apt-get remove -y unattended-upgrades
    apt-get update -y
    apt-get install -yq \
        curl git gnupg ca-certificates lsb-release \
        apt-transport-https software-properties-common \
        jq iproute2 net-tools uidmap dbus-user-session \
        cgroup-tools cgroupfs-mount libcgroup1

    echo -e "${ORANGE}[*] Установка Docker...${NC}"
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker $USER

    echo -e "${ORANGE}[✓] Система готова!${NC}"
}

create_fake_proc() {
    local cpu=$1 ram=$2
    mkdir -p /fake_proc
    
    for i in $(seq 0 $(($cpu-1))); do
        echo "processor : $i" >> /fake_proc/cpuinfo
        echo "model name : Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz" >> /fake_proc/cpuinfo
    done
    
    mem_total_kb=$(($ram * 1024 * 1024))
    echo "MemTotal: $mem_total_kb kB" > /fake_proc/meminfo
}

spoof_hardware() {
    local cpu=$1 ram=$2
    
    mount -t proc none /proc -o remount
    mount --bind /fake_proc/meminfo /proc/meminfo
    
    mkdir -p /sys/fs/cgroup/memory/fake
    echo $((ram * 1024 * 1024 * 1024)) > /sys/fs/cgroup/memory/fake/memory.limit_in_bytes
    echo $$ > /sys/fs/cgroup/memory/fake/cgroup.procs
}

create_node() {
    local node_num=$1 hw_profile=$2 node_ip=$3
    local volume_name="node${node_num}_data"

    IFS=',' read -ra HW <<< "${HW_PROFILES[$hw_profile]}"
    CPU=$(echo "${HW[0]}" | cut -d'=' -f2)
    RAM=$(echo "${HW[1]}" | cut -d'=' -f2)
    SSD=$(echo "${HW[2]}" | cut -d'=' -f2)

    docker rm -f "node${node_num}" 2>/dev/null
    
    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        echo -e "${ORANGE}[*] Инициализация ноды ${node_num}...${NC}"
        
        docker volume create "$volume_name"
        docker run --rm -v "$volume_name:/data" alpine sh -c "
            printf '00:%02x:%02x:%02x:%02x:%02x\n' \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) > /data/mac_address
            echo -n 'node-$(openssl rand -hex 4)' > /data/hostname
            echo -n '$(uuidgen)' > /data/machine_id"
    fi

    ip addr add "$node_ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null

    screen -dmS "node${node_num}" docker run -d \
        --name "node${node_num}" \
        --restart unless-stopped \
        --privileged \
        --network host \
        -v "${volume_name}:/etc/node_data" \
        -v /fake_proc:/fake_proc \
        your-node-image \
        /bin/sh -c '
            create_fake_proc $(cat /etc/node_data/cpu_cores) $(cat /etc/node_data/ram_gb)
            spoof_hardware $(cat /etc/node_data/cpu_cores) $(cat /etc/node_data/ram_gb)
            exec /app/worker \
                --ip "$(hostname -I | awk "{print \$1}")" \
                --cpu $(cat /etc/node_data/cpu_cores) \
                --ram $(cat /etc/node_data/ram_gb) \
                --ssd $(cat /etc/node_data/ssd_gb)'
}

setup_nodes() {
    read -p "Введите количество нод: " NODE_COUNT
    select profile in "${!HW_PROFILES[@]}"; do
        [[ -n $profile ]] && break
    done
    
    for ((i=1; i<=NODE_COUNT; i++)); do
        node_ip=$(echo "$BASE_IP" | awk -F. -v i="$i" '{OFS="."; $4 += i; print}')
        create_node "$i" "$profile" "$node_ip"
    done
}

# Добавление автозапуска
cat > /etc/systemd/system/nodes.service <<EOF
[Unit]
Description=Nodes Service
After=docker.service

[Service]
Type=oneshot
ExecStart=/usr/bin/screen -dmS nodes /bin/bash $0
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nodes.service
