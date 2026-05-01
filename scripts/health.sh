#!/bin/bash

# Скрипт проверки здоровья сетевой инфраструктуры
# Проверяет: связность (ping), DNS-резолвинг, логирует ошибки в syslog

# Настройки
INTERFACE="enp0s9"                    # Сетевой интерфейс для lab_net
DNS_SERVER="10.0.0.2"                 # Адрес DNS-сервера (BIND)
GW_IP="10.0.0.1"                      # Статический IP шлюза (ВМ1)
DNS_IP="10.0.0.2"                     # Статический IP DNS (ВМ2)
PING_COUNT=3                          # Сколько пакетов пинговать
PING_TIMEOUT=2                        # Таймаут ожидания ответа (сек)
LOG_TAG="health-check"                # Тег для logger
LOG_FACILITY="local0"                 # Facility для syslog

# Цвета для вывода в консоль
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция: логирование в syslog и вывод в консоль
# Параметры: $1=уровень (info/warn/error), $2=сообщение
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Вывод в консоль с цветом
    case "$level" in
        error)   echo -e "${RED}[$timestamp] [ERROR] $message${NC}" ;;
        warn)    echo -e "${YELLOW}[$timestamp] [WARN]  $message${NC}" ;;
        info)    echo -e "${GREEN}[$timestamp] [INFO]  $message${NC}" ;;
    esac
    
    # Отправка в syslog через logger
    # -p facility.priority, -t tag
    case "$level" in
        error)   logger -p "${LOG_FACILITY}.error" -t "$LOG_TAG" "$message" ;;
        warn)    logger -p "${LOG_FACILITY}.warning" -t "$LOG_TAG" "$message" ;;
        info)    logger -p "${LOG_FACILITY}.info" -t "$LOG_TAG" "$message" ;;
    esac
}

# Функция: получение собственного IP на интерфейсе enp0s9
get_own_ip() {
    ip -4 addr show "$INTERFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1
}

# Функция: проверка пинга до указанного хоста
# Возвращает: 0 = успех, 1 = ошибка
check_ping() {
    local target="$1"
    local target_name="${2:-$target}"  # Если не передано имя, используем IP
    
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" -q "$target" &>/dev/null; then
        log_message "info" "Ping до $target_name ($target) — ОК"
        return 0
    else
        log_message "error" "Ping до $target_name ($target) — НЕДОСТУПЕН"
        return 1
    fi
}

# Функция: проверка DNS (прямое разрешение имени в IP)
check_dns_forward() {
    local hostname="$1"
    
    result=$(dig +short "$hostname" @"$DNS_SERVER" 2>/dev/null)
    
    if [ -n "$result" ]; then
        log_message "info" "DNS forward: $hostname — $result"
        return 0
    else
        log_message "error" "DNS forward: $hostname — не резолвится"
        return 1
    fi
}

# Функция: проверка обратного DNS (IP — имя)
check_dns_reverse() {
    local ip="$1"
    
    result=$(dig +short -x "$ip" @"$DNS_SERVER" 2>/dev/null | sed 's/\.$//')
    
    if [ -n "$result" ]; then
        log_message "info" "DNS reverse: $ip — $result"
        return 0
    else
        log_message "warn" "DNS reverse: $ip — нет PTR-записи (не всегда критично)"
        return 1  # Не считаем это критической ошибкой
    fi
}

# Функция: получение динамического IP ВМ3 из файла аренды Kea DHCP
# Работает только на ВМ1 (где стоит DHCP-сервер)
get_vm3_ip_from_dhcp() {
    local lease_file="/var/lib/kea/kea-leases4.csv"
    
    if [ ! -f "$lease_file" ]; then
        log_message "warn" "Файл аренды DHCP не найден: $lease_file"
        return 1
    fi
    
    # Формат CSV Kea: address,hwaddr,client_id,valid_lifetime,expire,subnet_id,fqdn,state,user_context
    # Ищем запись с fqdn, содержащим "vm3" или "Maksim3", или "client" и берём IP
    # tail -n +2 → пропустить заголовок
    # grep -i → регистронезависимый поиск
    # cut -d',' -f1 → взять первое поле (IP-адрес)
    vm3_ip=$(tail -n +2 "$lease_file" 2>/dev/null | grep -iE "(vm3|Maksim3|client|ubuntu)" | cut -d',' -f1 | head -n1)
    
    if [ -n "$vm3_ip" ]; then
        echo "$vm3_ip"
        return 0
    else
        log_message "warn" "Не удалось найти активную аренду для ВМ3 в $lease_file"
        return 1
    fi
}

# Функция: проверка, что текущий хост резолвится по имени
check_own_hostname() {
    local my_hostname=$(hostname -f)  # Полное доменное имя (FQDN)
    
    if [ -z "$my_hostname" ] || [ "$my_hostname" = "localhost" ]; then
        log_message "warn" "Имя хоста не настроено или равно localhost"
        return 1
    fi
    
    # Проверяем, что наше имя резолвится в наш же IP
    resolved_ip=$(dig +short "$my_hostname" @"$DNS_SERVER" 2>/dev/null)
    my_ip=$(get_own_ip)
    
    if [ "$resolved_ip" = "$my_ip" ]; then
        log_message "info" "Собственное имя $my_hostname резолвится корректно — $resolved_ip"
        return 0
    else
        log_message "warn" "Имя $my_hostname резолвится в $resolved_ip, а мой IP: $my_ip"
        return 1
    fi
}

# ОСНОВНАЯ ЛОГИКА СКРИПТА
main() {
    log_message "info" "Запуск проверки здоровья сети"
    
    # Получаем свой IP
    MY_IP=$(get_own_ip)
    if [ -z "$MY_IP" ]; then
        log_message "error" "Не удалось определить IP на интерфейсе $INTERFACE"
        exit 1
    fi
    log_message "info" "Мой IP на $INTERFACE: $MY_IP"
    
    # Счётчики для итоговой статистики
    local errors=0
    
    # 1. ПРОВЕРКА СВЯЗНОСТИ (PING)
    log_message "info" "Проверка ping"
    
    # Всегда пингуем статические узлы
    check_ping "$GW_IP" "gw.lab.local" || ((errors++))
    check_ping "$DNS_IP" "ns.lab.local" || ((errors++))
    
    # Если мы НЕ ВМ3 — пытаемся пропинговать ВМ3
    if [ "$MY_IP" != "10.0.0.1" ] && [ "$MY_IP" != "10.0.0.2" ]; then
        # Мы на ВМ3 — нам не нужно пинговать себя
        log_message "info" "Работаю на ВМ3, пропускаю пинг самого себя"
    else
        # Мы на ВМ1 или ВМ2 — ищем динамический IP ВМ3
        VM3_IP=$(get_vm3_ip_from_dhcp)
        if [ -n "$VM3_IP" ]; then
            check_ping "$VM3_IP" "vm3.lab.local (dynamic)" || ((errors++))
        else
            log_message "warn" "Пропускаю пинг ВМ3: не удалось определить её IP"
        fi
    fi
    
    # 2. ПРОВЕРКА DNS
    log_message "info" "Проверка DNS"
    
    # Прямые записи (A): имя — IP
    check_dns_forward "gw.lab.local" || ((errors++))
    check_dns_forward "ns.lab.local" || ((errors++))
    check_dns_forward "services.lab.local" || ((errors++))
    
    # Обратные записи (PTR): IP — имя (не критично, если нет)
    check_dns_reverse "$GW_IP"
    check_dns_reverse "$DNS_IP"
    
    # Проверяем, что наше собственное имя резолвится
    check_own_hostname
    
    # 3. ДОПОЛНИТЕЛЬНАЯ ПРОВЕРКА: доступен ли порт 53 на DNS-сервере
    log_message "info" "Проверка доступности DNS-сервиса"
    
    if command -v nc &>/dev/null; then
        if nc -z -w 2 "$DNS_SERVER" 53 &>/dev/null; then
            log_message "info" "Порт 53 (DNS) на $DNS_SERVER доступен"
        else
            log_message "error" "Порт 53 (DNS) на $DNS_SERVER НЕ доступен"
            ((errors++))
        fi
    else
        log_message "warn" "Команда nc не найдена, пропускаю проверку порта"
    fi
    
    # ИТОГИ
    log_message "info" "Проверка завершена"
    
    if [ "$errors" -gt 0 ]; then
        log_message "error" "Обнаружено ошибок: $errors"
        exit 1  # Код 1 = есть проблемы
    else
        log_message "info" "Все проверки пройдены успешно"
        exit 0  # Код 0 = всё ОК
    fi
}

# Запускаем main-функцию
main "$@"
