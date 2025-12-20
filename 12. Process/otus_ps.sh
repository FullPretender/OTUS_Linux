#!/bin/bash

# Функция вычисления времени использованного процессом.
get_time() {
    local pid="$1"
    local utime=0 stime=0
    local total_sec
    # Читаем 14 и 15 поля из stat процесса.
    read -r _ _ _ _ _ _ _ _ _ _ _ _ _ utime stime _ < "/proc/$pid/stat" 2>/dev/null

    total_sec=$(( (utime + stime) / 100 )) 
    # Задаем формат вывода в зависимости от времения работы процесса
    if (( total_sec >= 3600 )); then
        printf "%02d:%02d:%02d" $((total_sec / 3600)) $(((total_sec % 3600) / 60)) $((total_sec % 60))
    else
        printf "%02d:%02d" $((total_sec / 60)) $((total_sec % 60))
    fi
}

# Функция получения command
get_command() {
    local pid="$1"
    local cmd
    
    # Читаем cmdline и меняем \0 на пробелы
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    if [[ -n "$cmd" ]]; then
        echo "${cmd% }"
    else
        # Если cmline пуста, скорее всего это процесс ядра, тогда смотрим в comm
        cmd=$(echo $(cat /proc/$pid/comm 2>/dev/null))
        if [[ -n "$cmd" ]]; then
            echo "[$cmd]"
            return
        else
            echo "[unknown]"
        fi
    fi
}

# Функция получения TTY.
get_tty() {
    local pid="$1"
    local fd0="/proc/$pid/fd/0"
    local target

    # Узнаем путь куда ведет симлинк stdin файлового дискриптора.
    target=$(readlink "$fd0" 2>/dev/null)
    if [[ "$target" == /dev/* ]]; then
           echo "${target#/dev/}"
           return
    fi
    echo "?"
}

# Основной цикл.
# Задаем формат печати заголовка чтобы результаты были видны как таблица и не разъехались.
printf "%-8s %-8s %-5s %-8s %s\n" "PID" "TTY" "STAT" "TIME" "COMMAND"

# Циклом проходимся по каталогу с процессами и собираем данные
for pid_path in /proc/[0-9]*; do
    pid=$(echo "$pid_path" | grep -o '[0-9]*$') 
    proc_status=$(awk '/^State:/ { print substr($2,1,1) }' "$pid_path/status" 2>/dev/null)
    tty=$(get_tty "$pid")
    proc_uptime=$(get_time "$pid")
    proc_command=$(get_command "$pid")

    # Выводим результат в том же формате что и заголовок 
    printf "%-8s %-8s %-5s %-8s %s\n" "$pid" "$tty" "$proc_status" "$proc_uptime" "${proc_command:0:150}"
done | sort -nk1