#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/multinode.conf"
BASE_IP="192.168.1.100"
NETWORK_INTERFACE="eth0"
TIMEZONE="Europe/Moscow"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/main/Logo"
ORANGE='\033[0;33m'
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

declare -A HW_PROFILES=(
    ["basic"]="CPU=4,RAM=8,SSD=512"
    ["pro"]="CPU=8,RAM=32,SSD=2048"
    ["ultra"]="CPU=16,RAM=128,SSD=4096"
)

show_menu() {
    clear
    echo -e "${ORANGE}"
    curl -sSf $LOGO_URL 2>/dev/null || echo "=== MultiNodeDocker ==="
    echo -e "\n\n1) Установить все компоненты\n2) Задать количество нод\n3) Проверить контейнеры\n4) Проверить отпечатки\n5) Выход${NC}"
}

install_dependencies() {
    echo -e "${ORANGE}[*] Инициализация системы...${NC}"
    
    export DEBIAN_FRONTEND=noninteractive
    mkdir -p /etc/needrestart/conf.d
    echo -e "\$nrconf{restart} = 'a';\n\$nrconf{kernelhints} = 0;" > /etc/needrestart/conf.d/99-disable.conf

    apt-get remove -y unattended-upgrades
    apt-get update -y
    apt-get install -yq \
        curl git screen cgroup-tools docker.io jq

    systemctl enable docker
    usermod -aG docker $USER

    sysctl -w vm.drop_caches=3 >/dev/null
    echo -e "${GREEN}[✓] Система готова!${NC}"
}

create_fake_env() {
    local cpu=$1 ram=$2 ssd=$3
    mkdir -p /fake_env/$cpu-$ram-$ssd
    
    # Генерация аппаратных данных
    echo "model name : Intel(R) Xeon(R) Platinum 8375C" > /fake_env/$cpu-$ram-$ssd/cpuinfo
    for i in $(seq 0 $(($cpu-1))); do
        echo "processor : $i" >> /fake_env/$cpu-$ram-$ssd/cpuinfo
    done
    
    echo "MemTotal: $(($ram * 1024 * 1024)) kB" > /fake_env/$cpu-$ram-$ssd/meminfo
    mkdir -p /fake_env/$cpu-$ram-$ssd/block/sda
    echo $((ssd * 1024 * 1024 * 2)) > /fake_env/$cpu-$ram-$ssd/block/sda/size
}

spoof_hardware() {
    local cpu=$1 ram=$2 ssd=$3
    mount --bind /fake_env/$cpu-$ram-$ssd/cpuinfo /proc/cpuinfo
    mount --bind /fake_env/$cpu-$ram-$ssd/meminfo /proc/meminfo
    mount --bind /fake_env/$cpu-$ram-$ssd/block /sys/block
    
    # Cgroups спуфинг
    mkdir -p /sys/fs/cgroup/{cpu,memory}/node$NODE_NUM
    echo $((cpu * 100000)) > /sys/fs/cgroup/cpu/node$NODE_NUM/cpu.cfs_quota_us
    echo $((ram * 1024 * 1024 * 1024)) > /sys/fs/cgroup/memory/node$NODE_NUM/memory.limit_in_bytes
    echo $$ > /sys/fs/cgroup/cpu/node$NODE_NUM/cgroup.procs
    echo $$ > /sys/fs/cgroup/memory/node$NODE_NUM/cgroup.procs
}

create_node() {
    local node_num=$1 hw_profile=$2 node_ip=$3
    IFS=',' read -ra HW <<< "${HW_PROFILES[$hw_profile]}"
    CPU=$(echo "${HW[0]}" | cut -d'=' -f2)
    RAM=$(echo "${HW[1]}" | cut -d'=' -f2)
    SSD=$(echo "${HW[2]}" | cut -d'=' -f2)

    docker rm -f node$node_num 2>/dev/null
    docker volume create node${node_num}_data >/dev/null

    screen -dmS node$node_num bash -c "
        docker run --rm -v node${node_num}_data:/data alpine sh -c '
            printf \"00:%02x:%02x:%02x:%02x:%02x\" \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) \$((RANDOM%256)) > /data/mac_address;
            echo node-$(openssl rand -hex 4) > /data/hostname;
            echo \$(uuidgen) > /data/machine_id;
        ';

        docker run -d --name node$node_num \
            --restart unless-stopped \
            --privileged \
            --network host \
            -v node${node_num}_data:/etc/node_data \
            -v /fake_env:/fake_env \
            -e NODE_NUM=$node_num \
            your-node-image \
            /bin/sh -c '
                create_fake_env $CPU $RAM $SSD;
                spoof_hardware $CPU $RAM $SSD;
                exec /app/worker \
                    --ip $node_ip \
                    --cpu $CPU \
                    --ram $RAM \
                    --ssd $SSD
            '
    "
}

setup_nodes() {
    read -p "Количество нод: " NODE_COUNT
    select profile in "${!HW_PROFILES[@]}"; do [[ -n $profile ]] && break; done
    
    for ((i=1; i<=NODE_COUNT; i++)); do
        node_ip=$(echo $BASE_IP | awk -F. -v i="$i" '{OFS="."; $4 += i; print}')
        create_node $i $profile $node_ip
        ip addr add $node_ip/24 dev $NETWORK_INTERFACE 2>/dev/null
    done
}

# Systemd сервис
cat > /etc/systemd/system/nodes.service <<EOF
[Unit]
Description=Nodes Service
After=docker.service

[Service]
ExecStart=/usr/bin/screen -dmS nodes /bin/bash $0
ExecStop=/usr/bin/screen -XS nodes quit
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nodes.service

echo -e "${GREEN}\nНОДА УСПЕШНО УСТАНОВЛЕНА${NC}"
