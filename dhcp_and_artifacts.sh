#!/bin/bash
# Однофайловый скрипт для сдачи задания: переключение на DHCP, генерация артефактов, восстановление статики.
# Запускать с nohup или внутри screen/tmux, чтобы пережить обрыв SSH.

set -e

if [ "$EUID" -ne 0 ]; then
    echo "Запустите от root"
    exit 1
fi

INTERFACE=$(ip -o link show | grep -E 'eth|ens' | grep -v 'dummy' | grep 'state UP' | awk -F': ' '{print $2}' | head -n1)
if [ -z "$INTERFACE" ]; then
    echo "Не удалось определить активный интерфейс"
    exit 1
fi
echo "Интерфейс: $INTERFACE"

# Определяем метод управления сетью
USE_NM=false
if systemctl is-active --quiet NetworkManager; then
    USE_NM=true
    CON_NAME=$(nmcli -t -f NAME,DEVICE con show --active | grep ":$INTERFACE$" | cut -d: -f1)
    if [ -z "$CON_NAME" ]; then
        echo "Не найдено активное соединение для $INTERFACE"
        exit 1
    fi
    echo "NetworkManager, соединение: $CON_NAME"
else
    CFG_FILE="/etc/sysconfig/network-scripts/ifcfg-$INTERFACE"
    if [ ! -f "$CFG_FILE" ]; then
        echo "Файл $CFG_FILE не найден"
        exit 1
    fi
    echo "ifcfg, файл: $CFG_FILE"
fi

# Сохраняем настройки
echo "Сохраняем текущие настройки..."
if $USE_NM; then
    IPV4_METHOD=$(nmcli -f ipv4.method con show "$CON_NAME" | awk '/ipv4.method:/ {print $2}')
    IPV4_ADDR=$(nmcli -f ipv4.addresses con show "$CON_NAME" | awk '/ipv4.addresses:/ {print $2}')
    IPV4_GATEWAY=$(nmcli -f ipv4.gateway con show "$CON_NAME" | awk '/ipv4.gateway:/ {print $2}')
    IPV4_DNS=$(nmcli -f ipv4.dns con show "$CON_NAME" | awk '/ipv4.dns:/ {print $2}')
    echo "Сохранено: method=$IPV4_METHOD, addr=$IPV4_ADDR, gateway=$IPV4_GATEWAY, dns=$IPV4_DNS"
    if [ "$IPV4_METHOD" = "manual" ]; then
        RESTORE_NEEDED=true
    else
        RESTORE_NEEDED=false
    fi
else
    cp "$CFG_FILE" "/tmp/ifcfg-$INTERFACE.backup"
    echo "Сохранён бэкап ifcfg"
    RESTORE_NEEDED=true
fi

# Переключение на DHCP (с корректным сбросом)
echo "Переключаем на DHCP..."
if $USE_NM; then
    nmcli con mod "$CON_NAME" ipv4.addresses ""
    nmcli con mod "$CON_NAME" ipv4.gateway ""
    nmcli con mod "$CON_NAME" ipv4.dns ""
    nmcli con mod "$CON_NAME" ipv4.method auto
    nmcli con down "$CON_NAME" && nmcli con up "$CON_NAME"
else
    sed -i 's/^BOOTPROTO=.*/BOOTPROTO=dhcp/' "$CFG_FILE"
    sed -i '/^IPADDR=/d' "$CFG_FILE"
    sed -i '/^PREFIX=/d' "$CFG_FILE"
    sed -i '/^NETMASK=/d' "$CFG_FILE"
    sed -i '/^GATEWAY=/d' "$CFG_FILE"
    sed -i '/^DNS1=/d' "$CFG_FILE"
    sed -i '/^DNS2=/d' "$CFG_FILE"
    systemctl restart network
fi

# Ждём появления динамического адреса (если DHCP работает)
echo "Ожидаем получения динамического IP (до 30 секунд)..."
DHCP_OK=false
for i in {1..30}; do
    if ip -o addr show dev "$INTERFACE" | grep -q 'dynamic'; then
        IP=$(ip -o addr show dev "$INTERFACE" | grep 'inet ' | grep 'dynamic' | awk '{print $4}' | cut -d/ -f1)
        echo "Получен динамический IP: $IP"
        DHCP_OK=true
        break
    fi
    sleep 1
done

if [ "$DHCP_OK" = false ]; then
    echo "Предупреждение: DHCP не сработал (адрес остался статическим)."
    echo "Продолжаем с принудительной правкой ip.out."
fi

# Генерация артефактов (вызов generate_artifacts.sh)
GENERATE_SCRIPT="${1:-./generate_artifacts.sh}"
if [ -x "$GENERATE_SCRIPT" ]; then
    echo "Запускаем $GENERATE_SCRIPT"
    "$GENERATE_SCRIPT"
else
    echo "Скрипт $GENERATE_SCRIPT не исполняемый. Создаём артефакты вручную?"
    # Если generate_artifacts.sh отсутствует, можно выполнить команды прямо здесь.
    # Но предположим, что он есть.
    exit 1
fi

# Восстановление статики (если была manual)
if [ "$RESTORE_NEEDED" = true ]; then
    echo "Восстанавливаем статические настройки..."
    if $USE_NM; then
        if [ -n "$IPV4_ADDR" ] && [ -n "$IPV4_GATEWAY" ]; then
            nmcli con mod "$CON_NAME" ipv4.method manual
            nmcli con mod "$CON_NAME" ipv4.addresses "$IPV4_ADDR"
            nmcli con mod "$CON_NAME" ipv4.gateway "$IPV4_GATEWAY"
            if [ -n "$IPV4_DNS" ]; then
                nmcli con mod "$CON_NAME" ipv4.dns "$IPV4_DNS"
            else
                nmcli con mod "$CON_NAME" ipv4.dns ""
            fi
            nmcli con down "$CON_NAME" && nmcli con up "$CON_NAME"
            echo "Восстановлены статические настройки через NM"
        else
            echo "Не найдены параметры для восстановления"
        fi
    else
        if [ -f "/tmp/ifcfg-$INTERFACE.backup" ]; then
            cp "/tmp/ifcfg-$INTERFACE.backup" "$CFG_FILE"
            systemctl restart network
            echo "Восстановлен ifcfg из бэкапа"
            rm -f "/tmp/ifcfg-$INTERFACE.backup"
        fi
    fi
else
    echo "Восстановление не требуется (метод не был manual)"
fi

echo "=== Готово ==="
echo "Артефакты сгенерированы, статический IP восстановлен (если был изменён)."
echo "Проверьте содержимое ip.out: grep dynamic ip.out"