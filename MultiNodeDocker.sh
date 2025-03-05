#!/bin/bash

# Конфигурация
CONFIG_FILE="/etc/multinode.conf"
BASE_IP="192.168.1.100"
NETWORK_INTERFACE="eth0"
TIMEZONE="Europe/Moscow"
LOGO_URL="https://raw.githubusercontent.com/ProNodeRunner/Logo/refs/heads/main/Logo"
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
    # Вывод логотипа
    curl -sSf $LOGO_URL 2>/dev/null || echo -e "=== MultiNodeDocker ==="
    echo -e "\n\n\n"
    echo " ༺ Многоузловая Установка Pro v2.0 ༻ "
    echo "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
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
    sudo mkdir -p /etc/needrestart/conf.d
    echo -e "\$nrconf{restart} = 'a';\n\$nrconf{kernelhints} = 0;" | sudo tee /etc/needrestart/conf.d/99-disable.conf >/dev/null

    sudo apt-get remove -y unattended-upgrades
    sudo apt-get update -y
    sudo apt-get install -yq \
        curl git gnupg ca-certificates lsb-release \
        apt-transport-https software-properties-common \
        jq iproute2 net-tools uidmap dbus-user-session \
        cgroup-tools cgroupfs-mount libcgroup1

    echo -e "${ORANGE}[*] Установка Docker...${NC}"
    curl -fsSL https://get.docker.com | sudo sh -s -- --yes
    sudo usermod -aG docker $USER

    echo -e "${ORANGE}[*] Оптимизация ядра...${NC}"
    sudo modprobe br_netfilter
    sudo sysctl -w net.ipv4.ip_forward=1
    sudo sysctl -w net.ipv6.conf.all.forwarding=1
    sudo sysctl -w vm.drop_caches=3

    echo -e "${ORANGE}[✓] Система готова!${NC}"
}

create_fake_proc() {
    local cpu=$1 ram=$2
    mkdir -p /fake_proc
    
    for i in $(seq 0 $(($cpu-1))); do
        echo "processor : $i" >> /fake_proc/cpuinfo
        echo "model name : Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz" >> /fake_proc/cpuinfo
        echo "cpu MHz : 2900.000" >> /fake_proc/cpuinfo
    done
    
    mem_total_kb=$(($ram * 1024 * 1024))
    sed "s/MemTotal.*/MemTotal:       ${mem_total_kb} kB/" /proc/meminfo > /fake_proc/meminfo
}

spoof_hardware() {
    local cpu=$1 ram=$2
    
    mount --bind /fake_proc/cpuinfo /proc/cpuinfo
    mount --bind /fake_proc/meminfo /proc/meminfo
    
    mkdir -p /sys/fs/cgroup/memory/fake
    echo $((ram * 1024 * 1024 * 1024)) > /sys/fs/cgroup/memory/fake/memory.limit_in_bytes
    echo $$ > /sys/fs/cgroup/memory/fake/cgroup.procs
    
    echo "Architecture:        x86_64
CPU(s):               ${cpu}
Model name:          Intel(R) Xeon(R) Platinum 8375C" > /fake_proc/lscpu
    mount --bind /fake_proc/lscpu /usr/bin/lscpu
}

create_node() {
    local node_num=$1 hw_profile=$2 node_ip=$3
    local volume_name="node${node_num}_data"

    IFS=',' read -ra HW <<< "${HW_PROFILES[$hw_profile]}"
    CPU=$(echo "${HW[0]}" | cut -d'=' -f2)
    RAM=$(echo "${HW[1]}" | cut -d'=' -f2)
    SSD=$(echo "${HW[2]}" | cut -d'=' -f2)

    if ! docker volume inspect "$volume_name" >/dev/null 2>&1; then
        echo -e "${ORANGE}[*] Инициализация ноды ${node_num}...${NC}"
        
        docker volume create "$volume_name"
        docker run --rm -v "$volume_name:/data" alpine sh -c "
            echo -n '00:$(openssl rand -hex 5 | sed 's/\(..\)/\1:/g')' > /data/mac_address
            echo -n 'node-$(openssl rand -hex 4)' > /data/hostname
            echo -n '$(openssl rand -hex 16)' > /data/machine_id
            echo -n '$CPU' > /data/cpu_cores
            echo -n '$RAM' > /data/ram_gb
            echo -n '$SSD' > /data/ssd_gb"
    fi

    sudo ip addr add "$node_ip/24" dev "$NETWORK_INTERFACE" 2>/dev/null

    echo -e "${ORANGE}[*] Запуск ноды ${node_num}...${NC}"
    docker run -d \
        --name "node${node_num}" \
        --restart unless-stopped \
        --privileged \
        --network host \
        -v "${volume_name}:/etc/node_data" \
        -v /fake_proc:/fake_proc \
        -e TZ="$TIMEZONE" \
        your-node-image \
        /bin/sh -c '
            create_fake_proc $(cat /etc/node_data/cpu_cores) $(cat /etc/node_data/ram_gb)
            spoof_hardware $(cat /etc/node_data/cpu_cores) $(cat /etc/node_data/ram_gb)
            exec /app/worker \
                --ip "$(hostname -I | awk "{print \$1}")" \
                --cpu $(cat /etc/node_data/cpu_cores) \
                --ram $(cat /etc/node_data/ram_gb) \
                --ssd $(cat /etc/node_data/ssd_gb)
        '
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

check_containers() {
    if ! docker info &>/dev/null; then
        echo -e "${ORANGE}Докер не запущен! Запустите сначала установку компонентов.${NC}"
        return
    fi
    
    count=$(docker ps -a --filter "name=node" --format "{{.Names}}" | wc -l)
    if [ $count -eq 0 ]; then
        echo -e "${ORANGE}Запущенные контейнеры не найдены${NC}"
    else
        docker ps -a --filter "name=node" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    fi
}

show_fingerprints() {
    for volume in $(docker volume ls -q --filter "name=node"); do
        echo -e "${ORANGE}${volume}${NC}"
        docker run --rm -v "$volume:/data" alpine sh -c '
            echo "MAC: $(cat /data/mac_address)"
            echo "Hostname: $(cat /data/hostname)"
            echo "Machine ID: $(cat /data/machine_id)"
            echo "CPU: $(cat /data/cpu_cores) cores"
            echo "RAM: $(cat /data/ram_gb) GB"
            echo "SSD: $(cat /data/ssd_gb) GB"
        '
        echo "▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔"
    done
}

while true; do
    show_menu
    read -p "Выберите опцию: " choice
    case $choice in
        1) install_dependencies ;;
        2) setup_nodes ;;
        3) check_containers ;;
        4) show_fingerprints ;;
        5) exit 0 ;;
        *) echo -e "${ORANGE}Ошибка выбора!${NC}"; sleep 1 ;;
    esac
    read -p "Нажмите Enter..."
done
