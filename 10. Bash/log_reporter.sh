#!/bin/bash

NGINX_LOGS="/var/log/nginx/access.log"
POSITION_FILE="/tmp/last_position.pos"
BLOCK_FILE="/tmp/nginx_block.lock"
REPORT_FILE="/tmp/report.txt"
TEMP_LOG="/tmp/temp_log_nginx.log"
EMAIL="silva-93@mail.ru"


# Внутри функции забираю из лога перую и последнюю строку, а уже из них получаю даты, тем самым получая диапазон.
get_time_range() {
    export TIME_START=$(head -n 1 "$TEMP_LOG" | awk '{print $4}' | sed 's/[][]//g')
    export TIME_END=$(tail -n 1 "$TEMP_LOG" | awk '{print $4}' | sed 's/[][]//g')
}


# Основная функция, в которой формируется отчет по последним логам
parse_logs() {
    echo "Отчёт по логам NGINX" > "$REPORT_FILE"
    echo "Временной диапазон с $TIME_START по $TIME_END" >> "$REPORT_FILE"
    echo "" >> "$REPORT_FILE"

    echo -e "-- IP-адреса с наибольшим кол-вом запросов --" >> "$REPORT_FILE"
    awk '{print $1}' "$TEMP_LOG" | sort | uniq -c | sort -nr | head -5 >> "$REPORT_FILE"

    echo -e "\n-- URL с наибольшим кол-вом запросов --" >> "$REPORT_FILE"
    awk '{print $7}' "$TEMP_LOG" | sort | uniq -c | sort -nr | head -5 >> "$REPORT_FILE"

    echo -e "\n-- Ошибки сервера --" >> "$REPORT_FILE"
    awk '$9 ~ /^(4|5)/ {print $9, $7}' "$TEMP_LOG" | sort | uniq -c | sort -nr >> "$REPORT_FILE"

    echo -e "\n-- HTTP-коды ответов --" >> "$REPORT_FILE"
    awk '{print $9}' "$TEMP_LOG" | sort | uniq -c | sort -nr >> "$REPORT_FILE"
    cat "$REPORT_FILE" #Проверка отчета в консоле
}


# Функция для оправки отчета на почту
send_email() {
    mail -a "From: silva-93@mail.ru" -s "Отчет nginx $(date '+%d.%m.%Y %H:%M')" "$EMAIL" << EOF
$(cat "$REPORT_FILE")
EOF
}


# Функция для предотвращения дублей запуска скрипта
check_run(){
    if [ -f "$BLOCK_FILE" ]; then
        echo "Скрипт уже запущен. Выход."
        exit 1
    fi
    touch "$BLOCK_FILE"
}


# Функция для сверки последней позиции чтения логов.
check_position(){
    # Узнаем последнюю позицию, если логи читались до этого.
    if [ -f "$POSITION_FILE" ]; then
        LAST_POS=$(cat "$POSITION_FILE")
    else
        LAST_POS=0
    fi

    # Получаем текущий размер логов.
    CURRENT_POS=$(wc -c < "$NGINX_LOGS")

    # Проверяю есть ли новые логи. Если нет - завершаем скрипт.
    if [ "$CURRENT_POS" -le "$LAST_POS" ]; then
        echo "Новых записей в логах нет."
        exit 0
    fi

    # Сохраняю новую позицию.
    echo "$CURRENT_POS" > "$POSITION_FILE"

    # Сохраняю логи с последней позиции, с ними как раз и будем работать.
    tail -c +$((LAST_POS + 1)) "$NGINX_LOGS" > "$TEMP_LOG"
}


# Функция для удаления временных файлов после завершения скрипта
clean_temp() {
    rm -f "$REPORT_FILE"
    rm -f "$BLOCK_FILE"
    rm -f "$TEMP_LOG"
}
# С помощью trap отслеживаю событие завершения, по которому запускается clean_temp()
trap clean_temp EXIT


#Основная часть
check_run
check_position
get_time_range
parse_logs
send_email
