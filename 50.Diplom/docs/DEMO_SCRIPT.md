# Сценарий демонстрации проекта

Документ предназначен для защиты проекта перед кураторами и демонстрации аудитории. Он описывает, что показывать, какие команды выполнять и какой результат ожидать.

См. также: [ARCHITECTURE.md](ARCHITECTURE.md), [README.md](../README.md), автоматический тест [scripts/ha_posts_test.sh](../scripts/ha_posts_test.sh).

**Секреты:** пароли БД, Restic, Grafana и SMTP — в Ansible Vault (`ansible/group_vars/all/vault.yml`). Просмотр: `ansible-vault view ansible/group_vars/all/vault.yml --vault-password-file ansible/.vault_pass`. В командах ниже для MySQL через HAProxy используется `sudo mysql --defaults-file=/root/.my.cnf` на backend VM (без пароля в shell history).

## Подготовка

На host OS должна быть запись:

```text
192.168.56.10 lab.diplom.com
```

Перед демонстрацией желательно начать с чистого состояния:

```bash
vagrant destroy -f
vagrant up
```

Если стенд уже поднят и нужно только повторно применить Ansible:

```bash
vagrant provision logging
```

Проверить состояние VM:

```bash
vagrant status
```

Ожидаемый результат: все VM в состоянии `running`.

## 1. Показ общей архитектуры

Что рассказать:

- `frontend` принимает внешний HTTPS-трафик.
- `backend-1` и `backend-2` обслуживают WordPress.
- `logging` хранит shared-state: NFS `wp-content`, HAProxy DB endpoint, Restic backup storage, Loki.
- `monitoring` отвечает только за Prometheus, Grafana и Alertmanager.
- MySQL находится на backend-серверах: master на `backend-1`, slave на `backend-2`.

Короткая формулировка:

> Пользователь заходит на frontend, frontend балансирует WordPress-запросы между двумя backend-ами. Файлы `wp-content` общие через NFS на `logging`, база доступна через HAProxy endpoint на `logging`, а резервные копии хранятся в Restic repositories на `logging`.

## 2. Проверка WordPress

Открыть в браузере:

```text
https://lab.diplom.com/
```

Или проверить из терминала:

```bash
curl -k -I https://lab.diplom.com/
curl -k https://lab.diplom.com/ | grep "Свежие мемы"
```

Ожидаемый результат:

- HTTP `200` или redirect на HTTPS;
- на странице видна демо-лента мемов;
- виден блок «Свежие мемы» (заголовок главной — «Главная лента мемов»).

Admin: логин `admin`, пароль — из Ansible Vault (ключ `vault_*` в `group_vars/all/vault.yml`).

Что рассказать:

- WordPress не установлен вручную через UI.
- Demo-контент разворачивается из SQL seed `forum-demo.sql` и подготовленного `wp-content` на NFS.
- Это делает чистый запуск воспроизводимым.

## 3. Проверка frontend load balancer

Проверить, что frontend видит оба backend:

```bash
vagrant ssh frontend -c "curl -I http://10.10.10.20 && curl -I http://10.10.10.21"
```

Показать upstream:

```bash
vagrant ssh frontend -c "sudo cat /etc/nginx/conf.d/upstream_backends.conf"
```

Ожидаемый результат:

- оба backend отвечают HTTP;
- upstream содержит `10.10.10.20` и `10.10.10.21`;
- используется `least_conn`.

Что рассказать:

- `frontend` терминирует HTTPS.
- Backend-ы получают обычный HTTP.
- Если один backend недоступен, Nginx исключает его по `max_fails` и `fail_timeout`.

## 4. Проверка shared-state на logging

Проверить сервисы:

```bash
vagrant ssh logging -c "systemctl is-active haproxy nfs-server rest-server loki"
```

Проверить NFS mount на backend-ах:

```bash
vagrant ssh backend-1 -c "mount | grep '10.10.10.40:/srv/wordpress/wp-content'"
vagrant ssh backend-2 -c "mount | grep '10.10.10.40:/srv/wordpress/wp-content'"
```

Проверить DB endpoint:

```bash
vagrant ssh backend-1 -c "sudo mysql -h 10.10.10.40 -P 6033 --defaults-file=/root/.my.cnf -NBe 'SELECT COUNT(*) FROM wordpress_db.wp_posts'"
vagrant ssh backend-2 -c "sudo mysql -h 10.10.10.40 -P 6033 --defaults-file=/root/.my.cnf -NBe 'SELECT COUNT(*) FROM wordpress_db.wp_posts'"
```

Ожидаемый результат:

- `haproxy`, `nfs-server`, `rest-server`, `loki` active;
- NFS смонтирован с `10.10.10.40`;
- DB endpoint доступен с обоих backend.

Что рассказать:

- `logging` в демонстрации является persistent shared-state node.
- Перенос shared-state с `monitoring` на `logging` позволил разрушать `monitoring` без влияния на WordPress.

## 5. Проверка MySQL replication

Проверить slave:

```bash
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master|Last_SQL_Error'"
```

Проверить HA marker:

```bash
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -NBe 'SELECT marker FROM wordpress_db.wp_ha_check WHERE id=1'"
```

Ожидаемый результат:

```text
Slave_IO_Running: Yes
Slave_SQL_Running: Yes
Seconds_Behind_Master: 0
replication-ok
```

Что рассказать:

- `backend-1` - master, `backend-2` - slave.
- Репликация нужна для сценария отказа одного backend.
- HAProxy использует `backend-1` как основной DB backend и `backend-2` как backup.

### 5.1. Расширенная демонстрация HAProxy для MySQL

Показать конфигурацию HAProxy на `logging`:

```bash
vagrant ssh logging -c "sudo sed -n '/listen wordpress_mysql_writer/,$p' /etc/haproxy/haproxy.cfg"
vagrant ssh logging -c "sudo ss -ltnp | grep ':6033'"
```

Проверить, что WordPress DB endpoint доступен через HAProxy:

```bash
vagrant ssh backend-1 -c "sudo mysql -h 10.10.10.40 -P 6033 --defaults-file=/root/.my.cnf -NBe 'SELECT @@hostname, COUNT(*) FROM wordpress_db.wp_posts'"
vagrant ssh backend-2 -c "sudo mysql -h 10.10.10.40 -P 6033 --defaults-file=/root/.my.cnf -NBe 'SELECT @@hostname, COUNT(*) FROM wordpress_db.wp_posts'"
```

Проверить валидность конфига и последние события HAProxy:

```bash
vagrant ssh logging -c "sudo haproxy -c -f /etc/haproxy/haproxy.cfg"
vagrant ssh logging -c "sudo journalctl -u haproxy --since '10 min ago' --no-pager | tail -n 30"
```

Демонстрация failover DB endpoint:

```bash
vagrant destroy -f backend-1
vagrant ssh backend-2 -c "for i in {1..10}; do sudo mysql -h 10.10.10.40 -P 6033 --defaults-file=/root/.my.cnf -NBe 'SELECT @@hostname, COUNT(*) FROM wordpress_db.wp_posts' && break; sleep 2; done"
vagrant ssh logging -c "sudo journalctl -u haproxy --since '5 min ago' --no-pager | egrep -i 'backend_master|backend_slave|down|up' || true"
vagrant up backend-1
vagrant provision logging
```

Ожидаемый результат:

- HAProxy слушает `0.0.0.0:6033`;
- в конфиге `backend_master` основной, `backend_slave` помечен как `backup`;
- при отказе `backend-1` endpoint `10.10.10.40:6033` остаётся доступен через backup backend;
- после `vagrant up backend-1` и `vagrant provision logging` репликация снова становится healthy.

Что рассказать:

- WordPress подключается не напрямую к конкретному MySQL, а к стабильному адресу `10.10.10.40:6033`;
- HAProxy скрывает от приложения, какой backend сейчас обслуживает DB endpoint;
- это снижает ручные действия при отказе master-узла и дополняет MySQL replication.

## 6. Проверка мониторинга

Prometheus:

```bash
curl -k -I https://lab.diplom.com/prometheus/-/ready
vagrant ssh monitoring -c "curl -s http://localhost:9090/prometheus/api/v1/targets | grep 10.10.10"
```

Grafana:

```bash
curl -k -I https://lab.diplom.com/grafana/login
```

Alertmanager:

```bash
curl -k -I https://lab.diplom.com/alertmanager/-/ready
```

Ожидаемый результат:

- Prometheus ready;
- targets включают `frontend`, `backend-1`, `backend-2`, `monitoring`, `logging`;
- Grafana login page доступна;
- Alertmanager ready.

Grafana credentials:

```text
admin / `<grafana_admin_password из vault>`
```

Что рассказать:

- Node Exporter установлен на все VM.
- Prometheus собирает метрики со всех узлов.
- Grafana подключает Prometheus и Loki как datasources.

### 6.1. Расширенная демонстрация Alertmanager

Показать, что Prometheus знает Alertmanager с учётом subpath:

```bash
vagrant ssh monitoring -c "curl -s http://localhost:9090/prometheus/api/v1/alertmanagers | python3 -m json.tool"
vagrant ssh monitoring -c "curl -s http://localhost:9093/alertmanager/api/v2/status | python3 -m json.tool"
```

Показать routing и SMTP-настройки без вывода пароля:

```bash
vagrant ssh monitoring -c "sudo grep -E 'smtp_smarthost|smtp_from|receiver|group_wait|group_interval|repeat_interval|severity|to:' /etc/alertmanager/alertmanager.yml"
```

Создать управляемый инцидент, например выключить `backend-2`:

```bash
vagrant destroy -f backend-2
```

Дождаться перехода alert-а в `firing` и доставки в Alertmanager:

```bash
vagrant ssh monitoring -c "for i in {1..45}; do \
  firing=\$(curl -s http://localhost:9090/prometheus/api/v1/alerts | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(1 for a in d[\"data\"][\"alerts\"] if a[\"labels\"].get(\"alertname\")==\"InstanceDown\" and a.get(\"state\")==\"firing\"))'); \
  delivered=\$(curl -s http://localhost:9093/alertmanager/api/v2/alerts | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))'); \
  echo \"try=\$i prometheus_firing=\$firing alertmanager_alerts=\$delivered\"; \
  [ \"\$firing\" -ge 1 ] && [ \"\$delivered\" -ge 1 ] && exit 0; \
  sleep 2; \
done; exit 1"
```

Показать active alerts:

```bash
vagrant ssh monitoring -c "curl -s http://localhost:9093/alertmanager/api/v2/alerts | python3 -m json.tool"
```

Проверить, что email notification была отправлена без ошибок:

```bash
vagrant ssh monitoring -c "curl -s http://localhost:9093/alertmanager/metrics | egrep 'alertmanager_notifications_(total|failed_total).*email'"
vagrant ssh monitoring -c "sudo journalctl -u alertmanager --since '10 min ago' --no-pager | egrep -i 'error|failed|smtp|notify|email' || true"
```

Восстановить VM:

```bash
vagrant up backend-2
vagrant provision logging
```

Ожидаемый результат:

- Prometheus переводит `InstanceDown` в `firing` после `for: 1m`;
- Alertmanager получает alert через `/alertmanager/api/v2/alerts`;
- alert имеет receiver `email-critical`;
- `alertmanager_notifications_total{integration="email"}` увеличивается;
- `alertmanager_notifications_failed_total{integration="email",...}` остаётся `0`;
- после восстановления VM alert становится resolved и отправляется resolved notification.

Что рассказать:

- Prometheus отвечает за вычисление правил и состояние `pending/firing`;
- Alertmanager отвечает за группировку, routing, deduplication, repeat interval и отправку уведомлений;
- critical alerts маршрутизируются в `email-critical`;
- `group_wait: 15s` уменьшает задержку демонстрации, а `repeat_interval: 4h` защищает от постоянного спама.

## 7. Проверка логирования

### 7.1. Проверка Loki и источников логов

Loki остаётся внутренним API-сервисом без публичной веб-морды. Проверяем его с VM `logging`:

```bash
vagrant ssh logging -c "curl -fsS http://localhost:3100/ready"
```

Показать labels, которые приходят от Alloy:

```bash
vagrant ssh logging -c "curl -s 'http://localhost:3100/loki/api/v1/labels'"
vagrant ssh logging -c "curl -s 'http://localhost:3100/loki/api/v1/label/job/values'"
vagrant ssh logging -c "curl -s 'http://localhost:3100/loki/api/v1/label/host/values'"
```

Alloy services:

```bash
vagrant ssh frontend -c "systemctl is-active alloy"
vagrant ssh backend-1 -c "systemctl is-active alloy"
vagrant ssh backend-2 -c "systemctl is-active alloy"
vagrant ssh monitoring -c "systemctl is-active alloy"
vagrant ssh logging -c "systemctl is-active alloy"
```

Ожидаемый результат:

- Loki отвечает ready;
- Alloy active на всех VM;
- labels содержат `filename`, `host`, `job`, `service_name`;
- `job` содержит `system`, `nginx`, `mysql`, `php-fpm`, `loki`, `grafana`;
- `host` содержит `frontend`, `backend-1`, `backend-2`, `monitoring`, `logging`.

### 7.2. Сгенерировать тестовое событие и найти его

Создать понятную тестовую запись в syslog на `frontend`:

```bash
vagrant ssh frontend -c "logger -t diplom-demo 'Loki demo: frontend test log from syslog'"
```

Через несколько секунд найти её через Loki API:

```bash
vagrant ssh logging -c "curl -G -s 'http://localhost:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={job=\"system\",host=\"frontend\"} |= \"Loki demo\"' \
  --data-urlencode 'limit=5' | python3 -m json.tool"
```

Ожидаемый результат:

- в ответе есть stream с labels `job="system"` и `host="frontend"`;
- в `values` видна строка `Loki demo: frontend test log from syslog`.

Что рассказать:

- событие создано на `frontend`;
- Alloy прочитал его из `/var/log/syslog`;
- Alloy отправил событие в Loki по `10.10.10.40:3100`;
- Loki сохранил запись, а API/Grafana позволяют её найти по labels и текстовому фильтру.

### 7.3. Показать поиск в Grafana Explore

Открыть Grafana:

```text
https://lab.diplom.com/grafana/explore
```

Выбрать datasource `Loki` и выполнить запросы:

```logql
{job="system", host="frontend"} |= "Loki demo"
```

```logql
{job="nginx", host="frontend"}
```

```logql
{job="system"} |= "error"
```

```logql
{job="grafana", host="monitoring"}
```

```logql
{job="loki", host="logging"}
```

Показать агрегации:

```logql
sum by (host) (count_over_time({job="system"}[5m]))
```

```logql
sum by (job) (count_over_time({host="logging"}[10m]))
```

Ожидаемый результат:

- Grafana показывает живые логи из Loki;
- фильтры по `host` и `job` позволяют быстро сузить область поиска;
- агрегации показывают интенсивность логов по хостам и типам сервисов.

### 7.4. Связать логи с инцидентом

Если во время демонстрации выключается один из backend, например `backend-2`, показать:

```logql
{host="backend-2", job="system"}
```

```logql
{host="frontend", job="nginx"}
```

```logql
{job="system"} |~ "shutdown|Stopped|Started|systemd"
```

Что рассказать:

- Prometheus показывает метрику/alert `InstanceDown`;
- Loki помогает посмотреть, что происходило на узле и вокруг него по логам;
- на `frontend` можно смотреть nginx logs и убедиться, что трафик продолжает обслуживаться вторым backend.

### 7.5. Retention и compactor

Показать настройки хранения:

```bash
vagrant ssh logging -c "sudo grep -E 'retention_period|retention_enabled|compaction_interval|delete_request_store' /etc/loki/loki.yml"
```

Ожидаемый результат:

- `retention_period: 168h`;
- `retention_enabled: true`;
- `compaction_interval: 10m`;
- `delete_request_store: filesystem`.

Что рассказать:

- Loki хранит логи 7 дней;
- compactor регулярно уплотняет индекс и удаляет данные старше retention;
- для учебного стенда это ограничивает расход диска и оставляет достаточно истории для диагностики.

Что рассказать:

- Grafana Alloy установлен на все VM.
- Он читает system logs, nginx, mysql, php-fpm, loki, grafana logs.
- Все логи отправляются в Loki на `logging`.
- Grafana подключается к Loki как datasource и даёт удобный интерфейс поиска через Explore.
- Loki не публикуется через frontend как веб-интерфейс; Alloy внутри сети пишет напрямую в `10.10.10.40:3100`.

## 8. Проверка backup

### 8.1. Проверка Rest Server и репозиториев

Rest Server остаётся внутренним API-сервисом на `logging`. Проверить сервис и каталоги репозиториев:

```bash
vagrant ssh logging -c "systemctl is-active rest-server"
vagrant ssh logging -c "sudo find /srv/restic -maxdepth 1 -mindepth 1 -type d -printf '%f\n' | sort"
vagrant ssh logging -c "curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8000/"
```

Ожидаемый результат:

- `rest-server` active;
- есть репозитории `frontend`, `backend_master`, `backend_slave`;
- HTTP API без Basic Auth отвечает `401`, значит Rest Server доступен и защищён.

### 8.2. Запустить backup вручную

```bash
vagrant ssh frontend -c "sudo systemctl start restic-backup-frontend.service"
vagrant ssh backend-1 -c "sudo systemctl start restic-backup-backend_master.service"
vagrant ssh backend-2 -c "sudo systemctl start restic-backup-backend_slave.service"
```

Проверить логи backup-скриптов:

```bash
vagrant ssh frontend -c "sudo tail -n 20 /var/log/restic_backup_frontend.log"
vagrant ssh backend-1 -c "sudo tail -n 20 /var/log/restic_backup_master.log"
vagrant ssh backend-2 -c "sudo tail -n 20 /var/log/restic_backup_slave.log"
```

Ожидаемый результат:

- systemd-команды завершаются без ошибок;
- в логах Restic виден созданный snapshot или сообщение `snapshot ... saved`.

### 8.3. Проверить snapshots и содержимое backup

URL репозитория (с паролем Rest Server) уже задан в `/usr/local/bin/restic_backup_*.sh` на каждой VM — не дублируем секрет в документе:

```bash
vagrant ssh frontend -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_frontend.sh | head -1); restic -r \"\$RESTIC_REPO\" snapshots'"
vagrant ssh backend-1 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_backend_master.sh | head -1); restic -r \"\$RESTIC_REPO\" snapshots'"
vagrant ssh backend-2 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_backend_slave.sh | head -1); restic -r \"\$RESTIC_REPO\" snapshots'"
```

Показать, что внутри snapshot есть конфиги и SQL dump:

```bash
vagrant ssh frontend -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_frontend.sh | head -1); restic -r \"\$RESTIC_REPO\" ls latest' | egrep '/etc/nginx|lab.crt|lab.key'"
vagrant ssh backend-1 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_backend_master.sh | head -1); restic -r \"\$RESTIC_REPO\" ls latest' | egrep '/tmp/mysql_backups|wp_db_.*\\.sql|/var/www/wordpress'"
vagrant ssh backend-2 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_backend_slave.sh | head -1); restic -r \"\$RESTIC_REPO\" ls latest' | egrep '/tmp/mysql_backups|wp_db_slave_.*\\.sql|wp-content'"
```

Ожидаемый результат:

- есть snapshots для `frontend`, `backend_master`, `backend_slave`;
- backend snapshots содержат `/tmp/mysql_backups`, где лежит SQL dump.

### 8.4. Тестовый restore без изменения рабочих файлов

Восстановить часть snapshot во временный каталог:

```bash
vagrant ssh backend-1 -c "sudo rm -rf /tmp/restic-demo-restore && sudo mkdir -p /tmp/restic-demo-restore"
vagrant ssh backend-1 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password bash -c 'eval \$(grep ^RESTIC_REPO= /usr/local/bin/restic_backup_backend_master.sh | head -1); restic -r \"\$RESTIC_REPO\" restore latest --target /tmp/restic-demo-restore --path /tmp/mysql_backups'"
vagrant ssh backend-1 -c "sudo find /tmp/restic-demo-restore -type f -name 'wp_db_*.sql' -print | tail -n 5"
vagrant ssh backend-1 -c "sudo rm -rf /tmp/restic-demo-restore"
```

Ожидаемый результат:

- Restic восстанавливает SQL dump в `/tmp/restic-demo-restore`;
- рабочая директория WordPress и текущая БД не затрагиваются.

### 8.5. Политика хранения backup

Показать retention policy в скриптах:

```bash
vagrant ssh frontend -c "sudo grep 'restic forget' /usr/local/bin/restic_backup_frontend.sh"
vagrant ssh backend-1 -c "sudo grep 'restic forget' /usr/local/bin/restic_backup_backend_master.sh"
vagrant ssh backend-2 -c "sudo grep 'restic forget' /usr/local/bin/restic_backup_backend_slave.sh"
```

Ожидаемый результат:

- используется `--keep-hourly 24`;
- используется `--keep-daily 7`;
- используется `--keep-weekly 4`;
- после forget выполняется `--prune`.

Что рассказать:

- Restic repositories находятся на `logging` в `/srv/restic`.
- Backend backup перед сохранением делает `mysqldump`.
- Эти SQL dump используются для восстановления master, если оба backend были пересозданы.
- Backup идёт по внутренней сети на `10.10.10.40:8000`, Rest Server не публикуется наружу как веб-морда.
- Проверка restore во временный каталог показывает, что backup не только создаётся, но и реально пригоден для восстановления.

## 9. Демонстрация отказа backend-2

Команды:

```bash
vagrant destroy -f backend-2
curl -k -I https://lab.diplom.com/
vagrant up backend-2
vagrant provision logging
```

Проверка после восстановления:

```bash
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'"
curl -k https://lab.diplom.com/ | grep "Свежие мемы"
```

Ожидаемый результат:

- сайт продолжает работать через `backend-1`;
- после восстановления slave снова `Yes/Yes`;
- данные ленты мемов не потеряны.

Важно: сразу после destroy может быть короткий timeout, пока frontend исключает недоступный upstream. Повторный запрос должен дать `200`.

## 10. Демонстрация отказа backend-1

Команды:

```bash
vagrant destroy -f backend-1
curl -k -I https://lab.diplom.com/
vagrant up backend-1
vagrant provision logging
```

Проверка:

```bash
vagrant ssh backend-1 -c "sudo mysql --defaults-file=/root/.my.cnf -NBe \"SELECT COUNT(*) FROM wordpress_db.wp_posts WHERE post_type='demo_forum_message' AND post_status='publish'\""
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'"
```

Ожидаемый результат:

- сайт работает через `backend-2`;
- восстановленный `backend-1` получает актуальную БД;
- replication снова healthy.

Что рассказать:

- При восстановлении master Ansible может забрать dump с живого slave.
- Это защищает от отката к demo seed при отказе одного backend.

## 11. Демонстрация отказа monitoring

Команды:

```bash
vagrant destroy -f monitoring
curl -k -I https://lab.diplom.com/
vagrant up monitoring
vagrant provision logging
```

Проверка:

```bash
curl -k -I https://lab.diplom.com/
curl -k -I https://lab.diplom.com/prometheus/-/ready
curl -k -I https://lab.diplom.com/grafana/login
```

Ожидаемый результат:

- WordPress продолжает работать во время отсутствия `monitoring`;
- после восстановления возвращаются Prometheus и Grafana.

Что рассказать:

- Раньше `monitoring` был SPOF, потому что там жили NFS/HAProxy/Restic.
- Теперь shared-state на `logging`, поэтому отказ `monitoring` не влияет на пользовательский сервис.

## 12. Демонстрация восстановления обоих backend из Restic

Перед разрушением сделать backup:

```bash
vagrant ssh backend-1 -c "sudo systemctl start restic-backup-backend_master.service"
```

Разрушить оба backend:

```bash
vagrant destroy -f backend-1 backend-2
vagrant up backend-1 backend-2
vagrant provision logging
```

Проверить:

```bash
vagrant ssh backend-1 -c "sudo mysql --defaults-file=/root/.my.cnf -NBe \"SELECT COUNT(*) FROM wordpress_db.wp_posts WHERE post_type='demo_forum_message' AND post_status='publish'\""
curl -k https://lab.diplom.com/ | grep "Свежие мемы"
```

Ожидаемый результат:

- WordPress восстановился;
- БД восстановилась не из demo seed, а из Restic dump на `logging`;
- данные сохраняются в пределах RPO последнего SQL dump.

## 13. Финальная проверка

```bash
vagrant status
curl -k -I https://lab.diplom.com/
curl -k -I https://lab.diplom.com/grafana/login
curl -k -I https://lab.diplom.com/prometheus/-/ready
curl -k -I https://lab.diplom.com/alertmanager/-/ready
vagrant ssh logging -c "curl -fsS http://localhost:3100/ready"
vagrant ssh logging -c "systemctl is-active haproxy nfs-server rest-server loki"
vagrant ssh frontend -c "systemctl is-active nginx node_exporter alloy"
vagrant ssh backend-1 -c "systemctl is-active nginx php8.1-fpm mysql node_exporter alloy"
vagrant ssh backend-2 -c "systemctl is-active nginx php8.1-fpm mysql node_exporter alloy"
vagrant ssh monitoring -c "systemctl is-active prometheus alertmanager grafana-server node_exporter alloy"
vagrant ssh logging -c "systemctl is-active haproxy nfs-server rest-server loki node_exporter alloy"
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'"
```

Ожидаемый результат:

- все VM running;
- WordPress доступен;
- веб-интерфейсы monitoring доступны через frontend paths;
- shared-state active;
- monitoring, logging и Alloy services active;
- replication healthy.

## 14. Автоматический HA-тест (`scripts/ha_posts_test.sh`)

После полного развёртывания стенда можно прогнать автоматизированную проверку отказоустойчивости (21 шаг, ~15–30 минут в зависимости от скорости VM):

```bash
./scripts/ha_posts_test.sh
```

**Предусловия:** все VM `running`, в `/etc/hosts` есть `lab.diplom.com` → `192.168.56.10`.

**Что делает скрипт:**

| Фаза | Действие |
|------|----------|
| A | `vagrant halt backend-1` → публикация поста «HA Test Post 1» → `vagrant up backend-1` |
| B | `halt backend-2` → пост #2 → `up backend-2` |
| C | `destroy backend-1` → пост #3 → `up` + `vagrant provision logging` |
| D | `destroy backend-2` → пост #4 → `up` + `provision logging` |
| E | Restic backup → `destroy` оба backend → `vagrant provision` → проверка всех 4 постов |

Посты создаются через **curl** и форму `demo_forum` (nonce). При ожидании данных вызывается `wp-ha-db-sync.service` на master.

**Ожидаемый результат:** в конце на https://lab.diplom.com/ видны заголовки `HA Test Post 1` … `HA Test Post 4`; скрипт завершается сообщением `HA posts test completed successfully`.

**Отличие от ручных сценариев §9–10:** здесь в фазах A–B используется **`vagrant halt`** (быстрее), а не только `destroy`; полное уничтожение обоих backend — только в фазе E с восстановлением из Restic.

Подробности архитектуры: [ARCHITECTURE.md](ARCHITECTURE.md#автоматический-ha-тест-scriptsha_posts_testsh).

## Короткий рассказ для аудитории

1. Сначала показываем WordPress и демо-ленту мемов.
2. Затем объясняем, что frontend балансирует трафик между двумя backend.
3. Показываем, что shared files вынесены на NFS.
4. Показываем, что БД доступна через HAProxy endpoint.
5. Показываем MySQL replication.
6. Показываем monitoring/logging/backup.
7. Разрушаем один backend и демонстрируем восстановление.
8. Разрушаем monitoring и показываем, что WordPress не падает.
9. Объясняем, что `logging` - persistent state node для демонстрации.

## Что подчеркнуть в выводах

- Проект воспроизводим: чистый `vagrant up` разворачивает готовый demo service.
- WordPress не пустой: сразу доступна demo-лента мемов.
- Backend-ы можно пересоздавать без ручного восстановления.
- `monitoring` отделён от runtime shared-state.
- Backup-и не просто создаются, а участвуют в восстановлении БД.
- Логи и метрики централизованы.
