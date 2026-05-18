# Сценарий демонстрации проекта

Документ предназначен для защиты проекта перед кураторами и демонстрации аудитории. Он описывает, что показывать, какие команды выполнять и какой результат ожидать.

## Подготовка

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
https://lab.diplom.com:8443/
```

Или проверить из терминала:

```bash
curl -k -I https://lab.diplom.com:8443/
curl -k https://lab.diplom.com:8443/ | grep "Последние обсуждения"
```

Ожидаемый результат:

- HTTP `200` или redirect на HTTPS;
- на странице виден demo forum;
- виден блок `Последние обсуждения`.

Admin credentials:

```text
admin / DemoAdmin123!
```

Что рассказать:

- WordPress не установлен вручную через UI.
- Demo forum разворачивается из SQL seed и заранее подготовленного `wp-content`.
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
vagrant ssh backend-1 -c "mysql -h 10.10.10.40 -P 6033 -u wp_user -p'WpUserSecure!' -NBe 'SELECT COUNT(*) FROM wordpress_db.wp_posts'"
vagrant ssh backend-2 -c "mysql -h 10.10.10.40 -P 6033 -u wp_user -p'WpUserSecure!' -NBe 'SELECT COUNT(*) FROM wordpress_db.wp_posts'"
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

## 6. Проверка мониторинга

Prometheus:

```bash
curl -I http://127.0.0.1:9090/-/ready
vagrant ssh monitoring -c "curl -s http://localhost:9090/api/v1/targets | grep 10.10.10"
```

Grafana:

```bash
curl -I http://127.0.0.1:3000/login
```

Alertmanager:

```bash
curl -I http://127.0.0.1:9093/-/ready
```

Ожидаемый результат:

- Prometheus ready;
- targets включают `frontend`, `backend-1`, `backend-2`, `monitoring`, `logging`;
- Grafana login page доступна;
- Alertmanager ready.

Grafana credentials:

```text
admin / GrafanaSecure!
```

Что рассказать:

- Node Exporter установлен на все VM.
- Prometheus собирает метрики со всех узлов.
- Grafana подключает Prometheus и Loki как datasources.

## 7. Проверка логирования

Loki readiness:

```bash
for i in {1..10}; do curl -fsS http://127.0.0.1:3100/ready && break; sleep 2; done
```

Labels:

```bash
vagrant ssh logging -c "curl -s 'http://localhost:3100/loki/api/v1/labels'"
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
- labels содержат `filename`, `host`, `job`, `service_name`.

Что рассказать:

- Grafana Alloy установлен на все VM.
- Он читает system logs, nginx, mysql, php-fpm, loki, grafana logs.
- Все логи отправляются в Loki на `logging`.

## 8. Проверка backup

Запустить backup вручную:

```bash
vagrant ssh frontend -c "sudo systemctl start restic-backup-frontend.service"
vagrant ssh backend-1 -c "sudo systemctl start restic-backup-backend_master.service"
vagrant ssh backend-2 -c "sudo systemctl start restic-backup-backend_slave.service"
```

Проверить snapshots:

```bash
vagrant ssh frontend -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password restic -r 'rest:http://restic:ResticServerPass!@10.10.10.40:8000/frontend' snapshots"
vagrant ssh backend-1 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password restic -r 'rest:http://restic:ResticServerPass!@10.10.10.40:8000/backend_master' snapshots"
vagrant ssh backend-2 -c "sudo RESTIC_PASSWORD_FILE=/etc/restic_password restic -r 'rest:http://restic:ResticServerPass!@10.10.10.40:8000/backend_slave' snapshots"
```

Ожидаемый результат:

- есть snapshots для `frontend`, `backend_master`, `backend_slave`;
- backend snapshots содержат `/tmp/mysql_backups`, где лежит SQL dump.

Что рассказать:

- Restic repositories находятся на `logging` в `/srv/restic`.
- Backend backup перед сохранением делает `mysqldump`.
- Эти SQL dump используются для восстановления master, если оба backend были пересозданы.

## 9. Демонстрация отказа backend-2

Команды:

```bash
vagrant destroy -f backend-2
curl -k -I https://lab.diplom.com:8443/
vagrant up backend-2
vagrant provision logging
```

Проверка после восстановления:

```bash
vagrant ssh backend-2 -c "sudo mysql --defaults-file=/root/.my.cnf -e 'SHOW SLAVE STATUS\\G' | egrep 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master'"
curl -k https://lab.diplom.com:8443/ | grep "Последние обсуждения"
```

Ожидаемый результат:

- сайт продолжает работать через `backend-1`;
- после восстановления slave снова `Yes/Yes`;
- данные форума не потеряны.

Важно: сразу после destroy может быть короткий timeout, пока frontend исключает недоступный upstream. Повторный запрос должен дать `200`.

## 10. Демонстрация отказа backend-1

Команды:

```bash
vagrant destroy -f backend-1
curl -k -I https://lab.diplom.com:8443/
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
curl -k -I https://lab.diplom.com:8443/
vagrant up monitoring
vagrant provision logging
```

Проверка:

```bash
curl -k -I https://lab.diplom.com:8443/
curl -I http://127.0.0.1:9090/-/ready
curl -I http://127.0.0.1:3000/login
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
curl -k https://lab.diplom.com:8443/ | grep "Последние обсуждения"
```

Ожидаемый результат:

- WordPress восстановился;
- БД восстановилась не из demo seed, а из Restic dump на `logging`;
- данные сохраняются в пределах RPO последнего SQL dump.

## 13. Финальная проверка

```bash
vagrant status
curl -k -I https://lab.diplom.com:8443/
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
- shared-state active;
- monitoring, logging и Alloy services active;
- replication healthy.

## Короткий рассказ для аудитории

1. Сначала показываем WordPress-форум.
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
- WordPress не пустой: сразу доступен demo forum.
- Backend-ы можно пересоздавать без ручного восстановления.
- `monitoring` отделён от runtime shared-state.
- Backup-и не просто создаются, а участвуют в восстановлении БД.
- Логи и метрики централизованы.
