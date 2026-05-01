#!/bin/bash

# Скрипт резервного копирования

# 1. Настройки (переменные)
BACKUP_DIR="/backup" # директория сохранения архивов
DATE=$(date +%Y.%m.%d_%H.%M.%S) # дата и время в формате 2026.04.16_19.23.00
LOG_FILE="/var/log/base_pet_project_backup.log" # файл лога
RETENTION_DAYS=7 # срок хранения 7 дней

# Список директорий для бэкапа
CONFIG_DIRS="/etc/kea /etc/netplan"

# 2. Проверки

# Проверяем, существует ли папка для бэкапов. Если нет — создаём.
if [ ! -d "$BACKUP_DIR" ]; then
        echo "$(date): Папка $BACKUP_DIR не найдена. Создаем..." | tee -a "$LOG_FILE"
        sudo mkdir -p "$BACKUP_DIR"
fi

# Проверяем, что переданные директории существуют
for DIR in $CONFIG_DIRS; do
        if [ ! -d "$DIR" ]; then
                echo "$(date): ОШИБКА - Директория $DIR не существует!" | tee -a "$LOG_FILE"
                exit 1
        fi
done

# 3. Создание архива
ARCHIVE_NAME="backup_${DATE}.tar.gz" # имя архива
ARCHIVE_PATH="${BACKUP_DIR}/${ARCHIVE_NAME}" # путь к архиву

echo "$(date): Начинаю создание архива $ARCHIVE_NAME" | tee -a "$LOG_FILE"

sudo tar -czf "$ARCHIVE_PATH" $CONFIG_DIRS 2>> "$LOG_FILE" # создание архива

# Проверяем, успешно ли создался архив
if [ $? -eq 0 ]; then
        echo "$(date): УСПЕШНО создан архив $ARCHIVE_NAME" | tee -a "$LOG_FILE"
else
        echo "$(date): ОШИБКА при создании архива!" | tee -a "$LOG_FILE"
        exit 1
fi

# 4. Ротация (удаление старых архивов)
echo "$(date): Удаляю архивы старше $RETENTION_DAYS дней" | tee -a "$LOG_FILE"
sudo find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f -mtime +"$RETENTION_DAYS" -delete

echo "$(date): Скрипт бэкапа завершен" | tee -a "$LOG_FILE"
