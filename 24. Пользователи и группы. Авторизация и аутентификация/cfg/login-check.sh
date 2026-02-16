#!/bin/bash
DAY_OF_WEEK=$(date +%w)

# Если сегодня СБ или ВС
if [[ "$DAY_OF_WEEK" == "6" || "$DAY_OF_WEEK" == "0" ]]; then
    # Проверяем, состоит ли пользователь в группе admin
    if groups "$PAM_USER" | grep -qw admin; then
        exit 0  # Разрешить вход
    else
        exit 1  # Запретить вход
    fi
else
    exit 0  # В будни — все могут входить
fi
