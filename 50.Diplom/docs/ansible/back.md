# back.yml

## Где выполняется

`back.yml` выполняется на группах `backend_master:backend_slave`.

- `backend_master`: `192.168.56.20`, `db_role=master`, `restic_label=backend_master`.
- `backend_slave`: `192.168.56.21`, `db_role=slave`, `restic_label=backend_slave`.
- `become: yes`: задачи выполняются с root-правами.
- `ignore_unreachable: true`: playbook продолжает работу, если один из backend-узлов временно недоступен. Это важно для восстановления HA-сценариев.
- Основные переменные: `db_wp_name`, `db_wp_user`, `db_wp_password`, `db_root_password`, `repl_user`, `repl_password`, `public_base_url`, `domain_name`, `restic_*`.

## Что делает playbook

Playbook настраивает backend-слой WordPress:

1. Готовит MySQL на master и slave.
2. Создает БД, пользователей и demo-данные WordPress.
3. При восстановлении master пытается взять данные со slave или из Restic.
4. Разворачивает файлы WordPress и подключает общий `wp-content` через NFS.
5. Настраивает PHP-FPM и Nginx.
6. Настраивает и проверяет MySQL-репликацию.
7. Создает HA-пользователей и systemd-таймер автосинхронизации.
8. Настраивает Restic backup для backend-узлов.

## Подробно по task'ам

### 1. MySQL — базовая настройка

Блок готовит MySQL перед созданием WordPress-данных и репликации.

- `Разрешение DB proxy к MySQL до проверки HAProxy` выполняет `ufw allow from 10.10.10.40 to any port 3306 proto tcp`. Это временно открывает доступ от HAProxy/общего узла к MySQL до финального `UFW.yml`. Используется `command`; описание модуля см. `ha_shared.md`.
- `Развертывание конфигурации MySQL` рендерит `templates/mysql/mysql_{{ db_role }}.cnf.j2` в `/etc/mysql/mysql.conf.d/zz-{{ db_role }}.cnf`. Префикс `zz-` выбран, чтобы конфиг загружался после стандартного `mysqld.cnf` и мог переопределить `bind-address`. При изменении вызывает `Restart MySQL`.
- `Удаление устаревших конфигов MySQL` удаляет старые master/slave-конфиги из `/etc/mysql/conf.d` и `/etc/mysql/mysql.conf.d`. Это предотвращает конфликт старых настроек с актуальным `zz-*.cnf`.
- `Запуск и активация MySQL` включает и запускает сервис `mysql`.
- `Установка пароля root для MySQL` задает пароль root через Unix socket и отключает запись этой операции в binlog через `sql_log_bin: false`, чтобы служебные изменения пользователей не реплицировались.
- `Создание файла .my.cnf для root` создает `/root/.my.cnf`, чтобы последующие shell-команды `mysql` и `mysqldump` могли подключаться без явного указания пароля.
- `Создание пользователя для репликации` выполняется только на master. Создает пользователя `repl_user` с правом `REPLICATION SLAVE` для IP slave `10.10.10.21`.
- `Применение перезапуска MySQL на Master` вызывает `meta: flush_handlers` только на master, чтобы немедленно применить MySQL-конфиг и включить binlog до настройки репликации.

### 2. WordPress — база данных (только Master)

Блок управляет БД WordPress и выбирает источник данных при восстановлении.

- `Создание БД для WordPress` создает базу `db_wp_name` на master. На slave база должна прийти через репликацию или начальную синхронизацию.
- `Создание пользователя для WordPress` создает пользователя `db_wp_user` с правами `ALL` на БД WordPress и `host: "%"`, чтобы WordPress мог подключаться через DB endpoint.
- `Проверка, установлен ли WordPress demo-сайт` выполняет SQL-запрос к `wp_options` и регистрирует `wp_demo_db_check`. Если таблицы уже есть, импорт demo-данных не нужен.
- `Проверка живой БД WordPress на Slave для восстановления Master` делегирует SQL-проверку на первый хост `backend_slave`. Если master пустой, но slave содержит живую БД, playbook сможет восстановить master со slave.
- `Создание временной директории для восстановления Master` создает локальную директорию `{{ playbook_dir }}/.tmp` на control node. Используется `delegate_to: localhost` и `become: false`, потому что файл сначала переносится через control node.
- `Дамп живой БД WordPress со Slave для восстановления Master` запускает `mysqldump` на slave и сохраняет `/tmp/wpress_master_restore.sql`, если master пустой, а slave живой.
- `Загрузка дампа Slave на control node` использует `fetch`, чтобы скачать дамп со slave в локальную `.tmp`.
- `Копирование дампа Slave на восстановленный Master` копирует скачанный SQL-файл на master в `/tmp/wpress_master_restore.sql`.
- `Восстановление Master из живой БД Slave` импортирует этот дамп в БД WordPress на master.
- `Размещение файла пароля Restic для аварийного восстановления` создает `/etc/restic_password`, если master пустой и slave тоже не может дать живую БД.
- `Проверка наличия Restic snapshot для восстановления Master` проверяет latest snapshot в репозитории `backend_master` с тегом `backend_master`. Команда использует JSON-вывод Restic и Python-проверку, что список snapshot'ов не пуст.
- `Восстановление Master из последнего Restic SQL dump` восстанавливает latest snapshot в `/tmp/restic-db-restore`, ищет последний `wp_db_*.sql` и импортирует его в MySQL.
- `Копирование SQL-дампа demo WordPress на Master` используется только если master пустой, slave пустой и Restic restore не сработал. Это fallback на demo-дамп из `templates/wordpress/demo/forum-demo.sql`.
- `Импорт demo WordPress в пустую БД` импортирует demo SQL в БД WordPress.
- `Удаление временного SQL-дампа demo WordPress`, `Удаление временного дампа восстановления Master` и `Удаление временной директории восстановления Restic` чистят временные файлы после восстановления или импорта.
- `Актуализация публичных URL WordPress` обновляет `siteurl`, `home`, `user_url` и `guid`, чтобы demo или восстановленная БД использовала актуальный `public_base_url`.

### 3. WordPress — файлы и конфигурация

Блок разворачивает код WordPress и подключает общий каталог контента.

- `Создание директории WordPress` создает `/var/www/wordpress` с владельцем `www-data`.
- `Распаковка WordPress из локального архива` распаковывает `/opt/wordpress_latest-ru_RU.tar.gz` в `/var/www/wordpress`, убирая верхний каталог архива через `--strip-components=1`. `creates` защищает от повторной распаковки.
- `Проверка состояния текущего NFS mountpoint wp-content` проверяет, не завис ли текущий mountpoint. Команда использует `findmnt` и `timeout ls`, чтобы выявить stale NFS.
- `Сброс stale NFS mountpoint wp-content` выполняет `umount -f -l`, если предыдущая проверка вернула признаки `Stale file handle`, `Input/output error` или `Transport endpoint is not connected`.
- `Создание точки монтирования общего wp-content` создает `/var/www/wordpress/wp-content` с правами `0775`.
- `Монтирование общего wp-content через NFS` монтирует `10.10.10.40:/srv/wordpress/wp-content` как `nfs4`. Параметры `until`, `retries: 5`, `delay: 10` дают NFS-серверу время подняться.
- `Проверка, что wp-content смонтирован с logging` проверяет источник mountpoint через `findmnt` и падает, если в источнике нет `10.10.10.40`.
- `Проверка наличия demo-темы в общем wp-content` проверяет marker-файл темы.
- `Развёртывание demo wp-content` копирует demo-тему и plugin в общий каталог только если marker-файл отсутствует.
- `Генерация wp-config.php` рендерит `templates/wordpress/wp-config.php.j2`, задавая подключение к БД и параметры WordPress.

### 4. PHP-FPM — конфигурация

- `Настройка PHP-FPM пула для WordPress` рендерит `templates/php-fpm/php-fpm-wordpress.conf.j2` в `/etc/php/8.1/fpm/pool.d/wordpress.conf` и вызывает `Restart PHP-FPM`.
- `Отключение дефолтного PHP-FPM пула` удаляет `/etc/php/8.1/fpm/pool.d/www.conf`, чтобы WordPress обслуживался только проектным pool'ом.

### 5. Nginx — конфигурация и запуск

- `Конфигурация Nginx для WordPress` рендерит backend virtual host из `templates/nginx/nginx_backend.conf.j2`.
- `Активация сайта WordPress` создает symlink из `sites-available` в `sites-enabled`.
- `Удаление дефолтного сайта Nginx` удаляет стандартный сайт, чтобы он не конфликтовал с WordPress.
- `Проверка конфигурации Nginx` запускает `nginx -t` до старта или reload, чтобы ошибка конфигурации была видна сразу.
- `Применение перезапуска Nginx после смены конфигурации` вызывает `meta: flush_handlers`, чтобы Nginx был перезапущен до проверки доступности.
- `Запуск Nginx и ожидание порта 80` включает и запускает сервис.
- `Проверка доступности HTTP на backend` ждет порт `80` на IP текущего backend-хоста.

### 6. WordPress — права доступа

`Коррекция прав доступа WordPress` рекурсивно задает владельца `www-data:www-data` и режим `u+rw,g+rx,o-rwx` для `/var/www/wordpress`. Это нужно, чтобы PHP-FPM мог читать и изменять нужные файлы, а лишний доступ для others был закрыт.

### 7. MySQL — репликация (только Slave)

Блок настраивает master-slave репликацию.

- `Пересоздание server_uuid на Slave` останавливает MySQL, удаляет `/var/lib/mysql/auto.cnf` и запускает MySQL снова. Это решает проблему одинакового UUID в Vagrant box. `creates` с маркером `/etc/mysql/.slave-uuid-regenerated` предотвращает повторное выполнение.
- `Маркер пересоздания server_uuid` создает marker-файл после регенерации UUID.
- `Получение координат binlog на Master` делегирует `SHOW MASTER STATUS` на master, выполняется `run_once` и сохраняет координаты binlog в `master_binlog_raw`.
- `Проверка статуса репликации MySQL` на slave читает `SHOW SLAVE STATUS` и собирает значения `Slave_IO_Running` и `Slave_SQL_Running`.
- `Сброс репликации MySQL на Slave при ошибке` делает `STOP SLAVE; RESET SLAVE ALL;`, если репликация не в состоянии `Yes Yes`.
- `Настройка и запуск репликации MySQL` выполняет `CHANGE MASTER TO` с координатами master binlog и запускает `START SLAVE`.

### 8. MySQL — начальная синхронизация данных (Slave)

Блок заполняет slave данными, если таблицы WordPress отсутствуют.

- `Проверка таблиц WordPress на Slave` пытается прочитать `wp_options`.
- `Дамп БД WordPress на Master для начальной синхронизации Slave` делает `mysqldump` на master, если slave пустой и master доступен.
- `Загрузка дампа с Master на control node` скачивает дамп через `fetch`.
- `Копирование дампа на Slave` переносит дамп на slave.
- `Создание БД WordPress на Slave перед импортом` гарантирует наличие БД на slave.
- `Импорт дампа WordPress на Slave` импортирует SQL-файл в БД slave.

### 9. MySQL — проверка репликации

- `Финальная проверка статуса репликации на Slave` снова читает `Slave_IO_Running` и `Slave_SQL_Running`.
- `Репликация MySQL должна быть активна` проверяет через `assert`, что оба значения равны `Yes`.
- `Создание тестовой записи HA на Master` создает/обновляет таблицу `wp_ha_check` с marker `replication-ok`.
- `Ожидание тестовой записи HA на Slave` до 30 раз проверяет, пришел ли marker на slave. Это подтверждает не только статус процессов репликации, но и фактическую доставку данных.

### 10. MySQL — пользователи для HA

- `Создание пользователя WordPress на Slave` создает `db_wp_user` на slave для локального входа WordPress при отказе master.
- `Разрешение root MySQL с peer-узла для HA-синхронизации` разрешает root-доступ с соседнего backend IP. Это нужно для автоматического `mysqldump` между узлами в сценариях HA-синхронизации.

### 11. MySQL — автосинхронизация (только Master)

- `Скрипт автовыравнивания БД WordPress` рендерит `/usr/local/bin/wp-ha-db-sync.sh` (сравнивает `MAX(ID)` в `wp_posts` на master и slave, при расхождении — `mysqldump` в сторону отстающего узла).
- `Systemd unit автосинхронизации БД` рендерит `wp-ha-db-sync.service` и `wp-ha-db-sync.timer`.
- `Включение таймера автосинхронизации БД` запускает и включает `wp-ha-db-sync.timer`.

Все три задачи выполняются только на master.

### 12. Restic — клиентский backup backend

- `Размещение файла пароля Restic` создает `/etc/restic_password` с правами `0400`.
- `Генерация скрипта бэкапа` рендерит `/usr/local/bin/restic_backup_{{ restic_label }}.sh`; шаблон зависит от `db_role`.

`restic init` и первый backup — в [`restic_init.yml`](restic_init.md), не в `back.yml`.
- `Развертывание systemd-юнитов Restic` создает service и timer для backup.
- `Активация таймера Restic` включает и запускает `restic-backup-{{ restic_label }}.timer`.

### 13. PHP-FPM — запуск сервиса

`Активация PHP-FPM` запускает и включает `php8.1-fpm`. Этот блок находится в конце, когда конфигурация pool'а, WordPress-файлы и Nginx уже подготовлены.

## Handlers

- `Restart MySQL` перезапускает `mysql`.
- `Restart PHP-FPM` перезапускает `php8.1-fpm`.
- `Restart Nginx Backend` перезапускает `nginx`.
- `Reload systemd` выполняет `daemon_reload` после изменения unit-файлов.

## Используемые модули

Модули `command`, `shell`, `file`, `copy`, `template`, `systemd`, `stat` описаны в `ha_shared.md`.

### `community.mysql.mysql_user`

Управляет MySQL-пользователями и их правами. В этом playbook'е используется для root, пользователя репликации, пользователя WordPress и HA-доступа. Параметр `login_unix_socket` позволяет подключаться локально через MySQL socket, а `sql_log_bin: false` предотвращает попадание служебных изменений пользователей в binary log.

### `community.mysql.mysql_db`

Управляет базами данных MySQL. Здесь создает БД WordPress на master и при необходимости на slave перед импортом дампа.

### `ansible.builtin.meta`

Управляет внутренним поведением Ansible. Используется как `meta: flush_handlers`, чтобы немедленно выполнить накопленные handlers, не дожидаясь конца play. Это важно для MySQL binlog и Nginx-проверок.

### `ansible.builtin.fetch`

Скачивает файл с удаленного хоста на control node. В этом playbook'е переносит SQL-дампы со slave или master через локальную `.tmp` директорию.

### `ansible.builtin.unarchive`

Распаковывает архив. Используется для локального архива WordPress на удаленном хосте с `remote_src: yes`.

### `ansible.posix.mount`

Управляет mountpoint'ами и `/etc/fstab`. Здесь монтирует общий `wp-content` по NFSv4 и обеспечивает его состояние `mounted`.

### `ansible.builtin.wait_for`

Ожидает порт, файл или состояние. В этом playbook'е проверяет доступность HTTP-порта backend.

### `ansible.builtin.assert`

Проверяет условие и завершает play с понятной ошибкой, если оно ложно. Здесь используется для финальной проверки, что MySQL-репликация здорова.

### `ansible.builtin.service`

Управляет сервисами через service manager целевой ОС. По смыслу близок к `systemd`, но использует более общий интерфейс. В playbook'е запускает MySQL, Nginx и PHP-FPM, а также применяется в handlers.

## Связанные шаблоны и файлы

- `ansible/templates/mysql/mysql_master.cnf.j2`
- `ansible/templates/mysql/mysql_slave.cnf.j2`
- `ansible/templates/mysql/wp-ha-db-sync.sh.j2`
- `ansible/templates/mysql/wp-ha-db-sync.service.j2`
- `ansible/templates/mysql/wp-ha-db-sync.timer.j2`
- `ansible/templates/wordpress/wp-config.php.j2`
- `ansible/templates/wordpress/demo/forum-demo.sql`
- `ansible/templates/wordpress/demo/wp-content/`
- `ansible/templates/php-fpm/php-fpm-wordpress.conf.j2`
- `ansible/templates/nginx/nginx_backend.conf.j2`
- `ansible/templates/restic/restic_backup_master.sh.j2`
- `ansible/templates/restic/restic_backup_slave.sh.j2`
- `ansible/templates/restic/restic-backup.service.j2`
- `ansible/templates/restic/restic-backup.timer.j2`
- `/var/www/wordpress`
- `/var/www/wordpress/wp-content`
- `/root/.my.cnf`
- `/etc/restic_password`
