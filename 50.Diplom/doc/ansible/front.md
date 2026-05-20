# front.yml

## Где выполняется

`front.yml` выполняется на группе `frontend`.

- Хост: `192.168.56.10`.
- `become: yes`: задачи выполняются с root-правами.
- Важные переменные: `domain_name`, `public_base_url`, `restic_label=frontend`, `restic_password`, `restic_server_user`, `restic_server_password`.
- Frontend обращается к backend-узлам по внутренним адресам `10.10.10.20` и `10.10.10.21`, а к Rest Server по `10.10.10.40:8000`.

## Что делает playbook

Playbook настраивает входную точку WordPress:

1. Создает self-signed SSL-сертификат для lab-среды.
2. Разворачивает Nginx upstream и HTTPS frontend-конфигурацию.
3. Проверяет, что хотя бы один backend доступен.
4. Проверяет локальный HTTPS endpoint.
5. Настраивает Restic backup frontend-узла через systemd timer.

## Подробно по task'ам

### 1. SSL — самоподписанный сертификат

Блок готовит сертификат для HTTPS в лабораторной среде.

- `Создание директории для SSL-сертификатов` создает `/etc/ssl/private` с владельцем `root:root` и правами `0755`. Директория нужна для приватного ключа `/etc/ssl/private/lab.key`.
- `Генерация самоподписанного SSL-сертификата` запускает `openssl req -x509`. Команда создает ключ и сертификат на 365 дней, использует `CN={{ domain_name }}` и сохраняет результат в `/etc/ssl/private/lab.key` и `/etc/ssl/certs/lab.crt`. `args.creates` делает генерацию одноразовой: существующий сертификат не перезаписывается при каждом запуске.

### 2. Nginx — конфигурация и запуск

Блок превращает frontend в HTTPS reverse proxy/load balancer.

- `Генерация Nginx upstream` рендерит `templates/nginx/nginx_upstream.j2` в `/etc/nginx/conf.d/upstream_backends.conf`. В этом файле описываются backend-узлы, между которыми Nginx распределяет запросы.
- `Генерация основной конфигурации Nginx` рендерит `templates/nginx/nginx_frontend.conf.j2` в `/etc/nginx/sites-available/frontend`. Конфигурация использует SSL-сертификат и проксирует запросы к upstream.
- `Активация сайта Nginx` создает symlink `/etc/nginx/sites-enabled/frontend` на файл из `sites-available`.
- `Удаление дефолтного сайта Nginx` удаляет `/etc/nginx/sites-enabled/default`, чтобы стандартный virtual host не перехватывал запросы.
- `Тест конфигурации Nginx` выполняет `nginx -t`. `changed_when: false` делает задачу проверочной.
- `Активация и запуск Nginx` запускает и включает сервис `nginx`. При изменениях вызывает `Restart Nginx`.
- `Применение перезапуска Nginx перед проверками` выполняет `meta: flush_handlers`, чтобы все накопленные reload/restart действия прошли до health-check'ов.
- `Проверка доступности backend-узлов с frontend` проверяет порт `80` на `10.10.10.20` и `10.10.10.21`. Результаты сохраняются в `backend_http_checks`, но `failed_when: false` не останавливает playbook сразу, чтобы следующий task мог проверить агрегированное условие.
- `Должен быть доступен хотя бы один backend` через `assert` проверяет, что хотя бы одна проверка backend завершилась без ошибки. Это допускает отказ одного backend-узла, но не всего backend-слоя.
- `Ожидание порта HTTPS на frontend` ждет, пока локальный порт `443` станет доступен.
- `Проверка локального HTTPS frontend` выполняет HTTPS-запрос к `https://127.0.0.1/`, отключая проверку сертификата, потому что сертификат self-signed. Допустимые статусы: `200`, `301`, `302`.

### 3. Restic — клиентский backup frontend

Блок настраивает клиентский backup frontend-узла.

- `Размещение файла пароля Restic` создает `/etc/restic_password` с правами `0400`. Файл используется командами Restic через `RESTIC_PASSWORD_FILE`.
- `Инициализация Restic-репозитория frontend` проверяет наличие репозитория через `restic snapshots`; если команда неуспешна, выполняет `restic init`. `failed_when: false` не валит playbook, чтобы сценарий оставался терпимым к временной недоступности Rest Server на этом этапе.
- `Генерация скрипта бэкапа Restic` рендерит `templates/restic/restic_backup.sh.j2` в `/usr/local/bin/restic_backup_frontend.sh` с правами `0755`.
- `Развертывание systemd-юнитов Restic` создает `restic-backup-frontend.service` и `restic-backup-frontend.timer` из общих шаблонов `templates/restic/restic-backup.*.j2`. `loop: [service, timer]` исключает дублирование двух почти одинаковых задач.
- `Активация таймера Restic` запускает и включает `restic-backup-frontend.timer`, чтобы backup выполнялся регулярно.

## Handlers

- `Restart Nginx` перезапускает `nginx` после изменения upstream, frontend-конфига или включения сайта.
- `Reload systemd` выполняет `daemon_reload` после создания Restic unit-файлов.

## Используемые модули

Модули `file`, `command`, `template`, `service`, `meta`, `wait_for`, `assert`, `copy`, `shell`, `systemd` описаны в `ha_shared.md` и `back.md`.

### `ansible.builtin.uri`

Выполняет HTTP/HTTPS-запросы с Ansible-контролем статуса ответа. В этом playbook'е используется для локальной проверки `https://127.0.0.1/`. Параметр `validate_certs: false` нужен из-за self-signed сертификата, а `status_code: [200, 301, 302]` считает нормальными как прямой ответ, так и редиректы.

## Связанные шаблоны и файлы

- `ansible/templates/nginx/nginx_upstream.j2`
- `ansible/templates/nginx/nginx_frontend.conf.j2`
- `ansible/templates/restic/restic_backup.sh.j2`
- `ansible/templates/restic/restic-backup.service.j2`
- `ansible/templates/restic/restic-backup.timer.j2`
- `/etc/ssl/private/lab.key`
- `/etc/ssl/certs/lab.crt`
- `/etc/nginx/conf.d/upstream_backends.conf`
- `/etc/nginx/sites-available/frontend`
- `/etc/nginx/sites-enabled/frontend`
- `/etc/restic_password`
- `/usr/local/bin/restic_backup_frontend.sh`
