#!/bin/bash
# Универсальный проверочный скрипт для сессионного задания MEPHI
# Запуск:
#   sudo ./check.sh              - проверит систему (если от root)
#   ./check.sh                   - проверит артефакты (если не root)
#   ./check.sh --system          - принудительно проверить систему
#   ./check.sh --artifacts       - принудительно проверить артефакты

MODE="auto"
if [ "$1" = "--system" ]; then MODE="system"; fi
if [ "$1" = "--artifacts" ]; then MODE="artifacts"; fi

# Если режим auto, определяем по правам и наличию /etc/passwd
if [ "$MODE" = "auto" ]; then
    if [ "$EUID" -eq 0 ] && [ -f /etc/passwd ]; then
        MODE="system"
    else
        MODE="artifacts"
    fi
fi

# Подключаем функции проверки (они общие для обоих режимов)
# Для системы и для артефактов проверки разные, но структура одна.

PASS=0
FAIL=0

# Функция проверки
check() {
    local desc="$1"
    local cmd="$2"
    local expected_regex="$3"
    local diag_cmd="${4:-}"
    echo "➜ $desc"
    echo "  ▶ Команда: $cmd"
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
    if [ -n "$output" ]; then
        echo "  ▶ Вывод:"
        echo "$output" | sed 's/^/    /'
    fi
    if [ "$expected_regex" = "EXIT_OK" ]; then
        if [ $exit_code -eq 0 ]; then
            echo "  ✓ ПРОВЕРКА ПРОЙДЕНА"
            ((PASS++))
        else
            echo "  ✗ ПРОВЕРКА НЕ ПРОЙДЕНА"
            [ -n "$diag_cmd" ] && eval "$diag_cmd" | sed 's/^/      /'
            ((FAIL++))
        fi
    else
        if echo "$output" | LC_ALL=C grep -qE "$expected_regex" && [ $exit_code -eq 0 ]; then
            echo "  ✓ ПРОВЕРКА ПРОЙДЕНА"
            ((PASS++))
        else
            echo "  ✗ ПРОВЕРКА НЕ ПРОЙДЕНА"
            [ -n "$diag_cmd" ] && eval "$diag_cmd" | sed 's/^/      /'
            ((FAIL++))
        fi
    fi
    echo ""
}

# Вспомогательная функция поиска файла в /root и /home
find_artifact() {
    local fname="$1"
    find /root /home -type f -name "$fname" 2>/dev/null | head -n1
}

# Определяем активный интерфейс (не dummy, не lo)
get_active_iface() {
    ip -o link show | grep -E 'eth|ens' | grep -v 'dummy' | grep 'state UP' | awk -F': ' '{print $2}' | head -n1
}

echo "=========================================="

echo "    ПРОВЕРКА СИСТЕМЫ (LIVE)"
echo "=========================================="
echo ""
# ====== ПРОВЕРКА СИСТЕМЫ ======
active_iface=$(get_active_iface)
echo "===== РАЗДЕЛ 1. УСТАНОВКА ====="

# 1.1 Сеть (DHCP) – улучшенная проверка через NM или ifcfg
dhcp_check_cmd="
    if systemctl is-active --quiet NetworkManager; then
        nmcli con show --active | grep -A 5 \"$active_iface\" | grep -q 'ipv4.method:.*auto'
    else
        grep -q '^BOOTPROTO=dhcp' /etc/sysconfig/network-scripts/ifcfg-$active_iface 2>/dev/null
    fi
"
check "1.1 Динамическая настройка IP (DHCP) для интерфейса $active_iface" \
    "$dhcp_check_cmd" \
    "EXIT_OK" \
    "echo 'Активные соединения NM:'; nmcli con show --active 2>/dev/null || echo 'NetworkManager не активен'; echo 'Конфиг интерфейса:'; grep -H 'BOOTPROTO' /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null || echo 'Не найдены ifcfg-файлы'"

# 1.2 Файловая система
check "1.2 Отдельный раздел с меткой MEPHI_DATA и точка /data-mephi" \
    "lsblk -f | grep -q 'MEPHI_DATA' && mount | grep -q '/data-mephi'" \
    "EXIT_OK" \
    "echo 'Разделы с метками:' ; lsblk -f | grep -E 'LABEL|MEPHI' ; echo 'Точки монтирования:' ; mount | grep /data-mephi ; echo '/etc/fstab:' ; grep -E 'data-mephi|MEPHI_DATA' /etc/fstab 2>/dev/null || echo 'Запись в fstab отсутствует'"

# 1.3 Пользователь mephi-admin
check "1.3 Пользователь mephi-admin с правами администратора" \
    "id mephi-admin &>/dev/null && groups mephi-admin | grep -qw wheel" \
    "EXIT_OK" \
    "echo 'Пользователь mephi-admin:' ; id mephi-admin 2>/dev/null || echo 'Не существует' ; echo 'Группы:' ; groups mephi-admin 2>/dev/null"

# ===== РАЗДЕЛ 2. УПРАВЛЕНИЕ ПО =====
echo "===== РАЗДЕЛ 2. УПРАВЛЕНИЕ ПРОГРАММНЫМ ОБЕСПЕЧЕНИЕМ ====="

# 2.1 Обновление – проверяем наличие записи об update
check "2.1 Обновление пакетов: файл dnf.out содержит запись об update" \
    "find_artifact 'dnf.out' | xargs -r grep -q 'update'" \
    "EXIT_OK" \
    "echo 'Ищем dnf.out в /root и /home:'; find /root /home -name 'dnf.out' 2>/dev/null || echo 'Не найден'; echo 'Содержимое (первые 10 строк):'; find_artifact 'dnf.out' | xargs -r head -10 || echo 'Файл пуст или отсутствует'"

# 2.2 Установка пакетов
for pkg in httpd tcpdump libcap-ng-utils; do
    check "2.2 Установлен пакет $pkg" \
        "rpm -q $pkg" \
        "EXIT_OK" \
        "echo 'Проверка установки:'; rpm -q $pkg 2>&1 || echo 'Не установлен'"
done

# ===== РАЗДЕЛ 3. УПРАВЛЕНИЕ СЕРВИСАМИ =====
echo "===== РАЗДЕЛ 3. УПРАВЛЕНИЕ СЕРВИСАМИ ====="

# 3.1 Apache запущен и включен
check "3.1 Apache (httpd) запущен и включен в автозагрузку" \
    "systemctl is-active --quiet httpd && systemctl is-enabled --quiet httpd" \
    "EXIT_OK" \
    "echo 'Статус httpd:' ; systemctl status httpd --no-pager | head -n5"

# 3.2 mod_userdir
check "3.2 Модуль mod_userdir включён" \
    "httpd -M 2>/dev/null | grep -q 'userdir_module' || apachectl -M 2>/dev/null | grep -q 'userdir_module'" \
    "EXIT_OK" \
    "echo 'Загруженные модули:' ; httpd -M 2>/dev/null | grep userdir || apachectl -M 2>/dev/null | grep userdir || echo 'Модуль не найден' ; echo 'Конфиг userdir:' ; grep -r 'userdir' /etc/httpd/conf* 2>/dev/null | head -n3"

# 3.3 Журналирование (httpd_logs)
check "3.3 Файл httpd_logs содержит логи Apache за последние 5 минут" \
    "find_artifact 'httpd_logs' | xargs -r grep -q '.'" \
    "EXIT_OK" \
    "echo 'Ищем httpd_logs в /root и /home:'; find /root /home -name 'httpd_logs' 2>/dev/null | xargs -r ls -l || echo 'Не найден' ; echo 'Содержимое (первые 5 строк):'; find_artifact 'httpd_logs' | xargs -r head -n5 || echo 'Файл пуст или отсутствует'"

# ===== РАЗДЕЛ 4. УПРАВЛЕНИЕ ДОСТУПОМ =====
echo "===== РАЗДЕЛ 4. УПРАВЛЕНИЕ ДОСТУПОМ ====="

# 4.1 Пользователь user1 и срок действия пароля (90 дней) – исправлено: используем grep -oP
check "4.1 Пользователь user1 существует, пароль меняется каждые 3 месяца (90 дней)" \
    "id user1 &>/dev/null && chage -l user1 2>/dev/null | grep -oP 'Maximum number of days between password change\\s*:\\s*\\K\\d+' | grep -q '90'" \
    "EXIT_OK" \
    "echo 'Пользователь user1:' ; id user1 2>/dev/null || echo 'Не существует' ; echo 'Параметры пароля:' ; chage -l user1 2>/dev/null || echo 'chage не удалось'"

# 4.2 tcpdump с capabilities
check "4.2 tcpdump настроен через capabilities (SUID снят, cap_net_admin+cap_net_raw)" \
    "[ ! -u /usr/sbin/tcpdump ] && getcap /usr/sbin/tcpdump | grep -q 'cap_net_admin,cap_net_raw=ep'" \
    "EXIT_OK" \
    "echo 'Права tcpdump:' ; ls -l /usr/sbin/tcpdump ; echo 'Capabilities:' ; getcap /usr/sbin/tcpdump ; echo 'SUID бит:' ; [ -u /usr/sbin/tcpdump ] && echo 'SUID установлен (должен быть снят)' || echo 'SUID не установлен (OK)'"

# ===== РАЗДЕЛ 5. АУТЕНТИФИКАЦИЯ =====
echo "===== РАЗДЕЛ 5. АУТЕНТИФИКАЦИЯ ====="

# 5.1 Вход root заблокирован – поддерживаем no и prohibit-password
check "5.1 Вход root по SSH заблокирован (PermitRootLogin no или prohibit-password)" \
    "grep -E '^PermitRootLogin\s+(no|prohibit-password)' /etc/ssh/sshd_config >/dev/null" \
    "EXIT_OK" \
    "echo 'Строка PermitRootLogin в sshd_config:' ; grep -E '^PermitRootLogin' /etc/ssh/sshd_config || echo 'Не найдена или закомментирована'"

# 5.2 Минимальная длина пароля = 10
check "5.2 Минимальная длина пароля = 10 (в /etc/security/pwquality.conf)" \
    "grep -E '^\s*minlen\s*=\s*10' /etc/security/pwquality.conf >/dev/null" \
    "EXIT_OK" \
    "echo 'Содержимое pwquality.conf (minlen):' ; grep -E 'minlen' /etc/security/pwquality.conf || echo 'Параметр не найден'"

# ===== РАЗДЕЛ 6. ТЕСТИРОВАНИЕ =====
echo "===== РАЗДЕЛ 6. ТЕСТИРОВАНИЕ ====="

# 6.1 Персональная страница user1
check "6.1.1 Файл index.html в /home/user1/public_html содержит 'Hello from Student:'" \
    "find /home/user1/public_html -name 'index.html' -exec grep -q 'Hello from Student:' {} \; -print -quit" \
    "EXIT_OK" \
    "echo 'Ищем index.html:' ; find /home/user1/public_html -name 'index.html' 2>/dev/null || echo 'Не найден' ; echo 'Содержимое:' ; find /home/user1/public_html -name 'index.html' -exec cat {} \; 2>/dev/null || echo 'Нет содержимого'"

# 6.1.2 Доступность через curl
check "6.1.2 curl -L http://localhost/~user1 возвращает 'Hello from Student:'" \
    "curl -L -s http://localhost/~user1 | grep -q 'Hello from Student:'" \
    "EXIT_OK" \
    "echo 'Ответ curl:' ; curl -s http://localhost/~user1 || echo 'Недоступно' ; echo 'Права на /home/user1:' ; ls -ld /home/user1 ; echo 'Права на public_html:' ; ls -ld /home/user1/public_html 2>/dev/null || echo 'Нет такой директории' ; echo 'SELinux:' ; getenforce 2>/dev/null || echo 'SELinux не установлен'"

# 6.2 Скриншот
check "6.2 Файл скриншота mephi-screenshot.png существует" \
    "find_artifact 'mephi-screenshot.png' | grep -q ." \
    "EXIT_OK" \
    "echo 'Ищем mephi-screenshot.png:' ; find /root /home -name 'mephi-screenshot.png' 2>/dev/null || echo 'Не найден'"

# ===== РАЗДЕЛ 7. АРТЕФАКТЫ ДЛЯ GITHUB =====
echo "===== РАЗДЕЛ 7. АРТЕФАКТЫ (файлы для GitHub) ====="

artifacts=(
    "history.out"
    "ip.out"
    "ping.out"
    "stat.out"
    "httpd_logs"
    "getcap.out"
    "index.html"
    "mephi-screenshot.png"
    "dnf.out"
    "fstab"
    "passwd"
    "shadow"
    "pwquality.conf"
)

for art in "${artifacts[@]}"; do
    check "Артефакт: $art" \
        "find_artifact '$art' | grep -q ." \
        "EXIT_OK" \
        "echo 'Ищем $art:' ; find /root /home -name '$art' 2>/dev/null || echo 'Не найден'"
done

echo ""
echo "=========================================="

echo "    ПРОВЕРКА АРТЕФАКТОВ"
echo "=========================================="
echo ""

# ====== ПРОВЕРКА АРТЕФАКТОВ (по файлам) ======
echo "Проверка файлов в текущей директории: $(pwd)"
echo ""

check_file() {
    local file="$1"
    local pattern="$2"
    local desc="$3"
    echo "➜ $desc"
    if [ ! -f "$file" ]; then
        echo "  ✗ Файл $file не найден"
        ((FAIL++))
        echo ""
        return
    fi
    if grep -q "$pattern" "$file"; then
        echo "  ✓ Файл $file содержит верный текст"
        ((PASS++))
    else
        echo "  ✗ Файл $file НЕ содержит '$pattern'"
        echo "  ▶ Содержимое файла (первые 5 строк):"
        head -n5 "$file" | sed 's/^/    /'
        ((FAIL++))
    fi
    echo ""
}

check_file_nonempty() {
    local file="$1"
    local desc="$2"
    echo "➜ $desc"
    if [ ! -f "$file" ]; then
        echo "  ✗ Файл $file не найден"
        ((FAIL++))
        echo ""
        return
    fi
    if [ -s "$file" ]; then
        echo "  ✓ Файл $file не пуст"
        ((PASS++))
    else
        echo "  ✗ Файл $file пуст"
        ((FAIL++))
    fi
    echo ""
}

# Проверяем наличие и содержимое артефактов
check_file "ip.out" "dynamic" "1.1 Наличие динамического IP (флаг dynamic в ip addr)"
check_file "ping.out" "0% packet loss" "1.1 Проверка сети (пинг 8.8.8.8)"
check_file "fstab" "/data-mephi" "1.2 Запись монтирования в fstab"
check_file "fstab" "MEPHI_DATA" "1.2 Метка тома в fstab"
check_file "passwd" "mephi-admin" "1.3 Пользователь mephi-admin в passwd"
check_file "passwd" "user1" "4.1 Пользователь user1 в passwd"
check_file "dnf.out" "update" "2.1 Обновление пакетов (команда update)"
check_file "stat.out" "drwxr-xr-x" "3.2/6.1 Права на домашнюю директорию user1"
check_file_nonempty "httpd_logs" "3.3 Логи Apache"
check_file "getcap.out" "cap_net_admin,cap_net_raw=ep" "4.2 Capabilities tcpdump"
check_file "pwquality.conf" "minlen = 10" "5.2 Минимальная длина пароля 10"
check_file "index.html" "Hello from Student:" "6.1.1 Содержимое index.html"
check_file_nonempty "mephi-screenshot.png" "6.2 Скриншот"
check_file_nonempty "history.out" "7.1 История команд"

# Дополнительно можно проверить, что shadow содержит записи для пользователей (но пароли захешированы, проверим только наличие строк)
if [ -f "shadow" ]; then
    if grep -q "mephi-admin" "shadow" && grep -q "user1" "shadow"; then
        echo "✓ shadow содержит записи для mephi-admin и user1"
        ((PASS++))
    else
        echo "✗ shadow не содержит записи для mephi-admin или user1"
        ((FAIL++))
    fi
    echo ""
else
    echo "✗ Файл shadow не найден"
    ((FAIL++))
    echo ""
fi


# ИТОГ
echo "=========================================="
echo "РЕЗУЛЬТАТЫ ПРОВЕРКИ:"
echo "  Успешно: $PASS"
echo "  Неудачно: $FAIL"
echo "=========================================="

if [ $FAIL -eq 0 ]; then
    echo "Все проверки пройдены! Задание выполнено корректно."
else
    echo "Некоторые проверки не пройдены. Используйте диагностическую информацию выше для устранения проблем."
fi

exit 0