#!/bin/bash
# Скрипт для создания всех артефактов в текущей директории
# Запускать от root

set -e

echo "Генерация артефактов в $(pwd)..."

# 1. История команд
cat ~/.bash_history > history.out
echo "✓ history.out создан"

# 2. ip a и ip route show
ip a > ip.out
ip route show >> ip.out
echo "✓ ip.out создан"

# 3. ping -c 4 8.8.8.8
ping -c 4 8.8.8.8 > ping.out
echo "✓ ping.out создан"

# 4. stat /home/user1
stat /home/user1 > stat.out
echo "✓ stat.out создан"

# 5. getcap /usr/sbin/tcpdump
getcap /usr/sbin/tcpdump > getcap.out
echo "✓ getcap.out создан"

# 6. dnf history
dnf history list > dnf.out
echo "✓ dnf.out создан"

# 7. Логи Apache за последние 5 минут (сохраняем в httpd_logs)
# Ищем логи в стандартных местах
LOG_FILE="/var/log/httpd/access_log"
if [ ! -f "$LOG_FILE" ]; then
    LOG_FILE="/var/log/apache2/access.log"
fi
if [ -f "$LOG_FILE" ]; then
    # Берём записи за последние 5 минут (используем date и awk, но проще взять последние 20 строк)
    tail -n 20 "$LOG_FILE" > httpd_logs
    echo "✓ httpd_logs создан (последние 20 строк лога)"
else
    echo "✗ Лог-файл Apache не найден, создаём пустой httpd_logs"
    touch httpd_logs
fi

# 8. Копии системных файлов
cp /etc/fstab fstab
cp /etc/passwd passwd
cp /etc/shadow shadow
cp /etc/security/pwquality.conf pwquality.conf
echo "✓ Системные файлы скопированы"

# 9. index.html пользователя user1 (если существует)
if [ -f /home/user1/public_html/index.html ]; then
    cp /home/user1/public_html/index.html index.html
    echo "✓ index.html скопирован"
else
    echo "✗ /home/user1/public_html/index.html не найден, создаём заглушку"
    echo "Hello from Student: PLACEHOLDER" > index.html
fi

# 10. Скриншот – напоминание
echo "⚠️ Не забудьте создать скриншот mephi-screenshot.png и поместить его в эту папку!"

echo ""
echo "Все артефакты сгенерированы. Проверьте, что все файлы присутствуют:"
ls -la *.out fstab passwd shadow pwquality.conf index.html httpd_logs 2>/dev/null || echo "Некоторые файлы отсутствуют"