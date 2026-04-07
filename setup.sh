#!/bin/bash

# Проверка root
if [ "$EUID" -ne 0 ]; then
  echo "Запусти через sudo"
  exit 1
fi

echo "=== Создание пользователя ==="

# Имя пользователя
read -p "Введите имя пользователя: " USERNAME

if id "$USERNAME" &>/dev/null; then
  echo "Пользователь уже существует!"
  exit 1
fi

# Пароль
read -s -p "Введите пароль: " PASSWORD
echo
read -s -p "Повторите пароль: " PASSWORD2
echo

if [ "$PASSWORD" != "$PASSWORD2" ]; then
  echo "Пароли не совпадают!"
  exit 1
fi

# SSH ключ
echo "Вставь публичный SSH ключ (ssh-rsa / ssh-ed25519):"
read -p "> " SSH_KEY

if [[ -z "$SSH_KEY" ]]; then
  echo "SSH ключ не может быть пустым!"
  exit 1
fi

# IP панели
read -p "Введите IP панели (для доступа к порту 2222): " PANEL_IP

if [[ -z "$PANEL_IP" ]]; then
  echo "IP панели не может быть пустым!"
  exit 1
fi

# SECRET KEY
read -p "Введите SECRET_KEY для remnanode: " SECRET_KEY

if [[ -z "$SECRET_KEY" ]]; then
  echo "SECRET_KEY не может быть пустым!"
  exit 1
fi

# Создание пользователя
useradd -m -s /bin/bash "$USERNAME"

# Установка пароля
echo -e "$PASSWORD\n$PASSWORD" | passwd "$USERNAME"

# SSH настройка
USER_HOME=$(eval echo "~$USERNAME")

mkdir -p "$USER_HOME/.ssh"
echo "$SSH_KEY" > "$USER_HOME/.ssh/authorized_keys"

chmod 700 "$USER_HOME/.ssh"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

chown -R "$USERNAME:$USERNAME" "$USER_HOME/.ssh"

echo "=== Настройка SSH ==="

SSHD_CONFIG="/etc/ssh/sshd_config"

sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"
sed -i 's/^#\?UsePAM.*/UsePAM yes/' "$SSHD_CONFIG"
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$SSHD_CONFIG"

grep -q '^PubkeyAuthentication yes$' "$SSHD_CONFIG" || echo 'PubkeyAuthentication yes' >> "$SSHD_CONFIG"
grep -q '^PasswordAuthentication no$' "$SSHD_CONFIG" || echo 'PasswordAuthentication no' >> "$SSHD_CONFIG"
grep -q '^KbdInteractiveAuthentication no$' "$SSHD_CONFIG" || echo 'KbdInteractiveAuthentication no' >> "$SSHD_CONFIG"
grep -q '^ChallengeResponseAuthentication no$' "$SSHD_CONFIG" || echo 'ChallengeResponseAuthentication no' >> "$SSHD_CONFIG"
grep -q '^UsePAM yes$' "$SSHD_CONFIG" || echo 'UsePAM yes' >> "$SSHD_CONFIG"
grep -q '^PermitRootLogin no$' "$SSHD_CONFIG" || echo 'PermitRootLogin no' >> "$SSHD_CONFIG"

sshd -t && systemctl restart ssh || systemctl restart sshd

# Sudo доступ
read -p "Добавить в sudo группу? (y/n): " SUDO
if [[ "$SUDO" == "y" || "$SUDO" == "Y" ]]; then
  usermod -aG sudo "$USERNAME"
  echo "Добавлен в sudo"
fi

echo "=== Настройка UFW ==="

apt update -y
apt install -y ufw curl

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 443/tcp
ufw allow from $PANEL_IP to any port 2222 proto tcp

ufw --force enable

echo "=== Установка Docker ==="

curl -fsSL https://get.docker.com | sh

echo "=== Установка Remnanode ==="

mkdir -p /opt/remnanode
cd /opt/remnanode

cat > docker-compose.yml <<EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=2222
      - SECRET_KEY="$SECRET_KEY"
EOF

echo "=== Запуск контейнера ==="

docker compose up -d

echo "=== Включение BBR ==="

if ! grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf; then
  echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
fi

if ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf; then
  echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
fi

sysctl -p

echo "=== Перезагрузка сервера ==="
#reboot
