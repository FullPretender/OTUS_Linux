# monitoring.yml

## Где выполняется

`monitoring.yml` содержит два play.

Первый play выполняется на `hosts: all` и устанавливает Node Exporter на все узлы стенда.

Второй play выполняется на группе `monitoring`:

- Хост: `192.168.56.30`.
- `become: yes`: все задачи выполняются с root-правами.
- Важные переменные из inventory: `alertmanager_smtp_server`, `alertmanager_smtp_user`, `alertmanager_email_to`, а пароль SMTP берется из Vault через `alertmanager_smtp_password`.

## Что делает playbook

Playbook разворачивает метрики и визуализацию:

1. На каждом узле создает пользователя `node_exporter`, проверяет preinstalled Node Exporter в box `diplom-ubuntu`, создает textfile collector и systemd unit.
2. На monitoring-узле создает пользователей `prometheus` и `alertmanager`.
3. Проверяет preinstalled Prometheus, promtool и Alertmanager (`assert`).
4. Разворачивает конфиги Prometheus, alert rules, Alertmanager и Grafana provisioning.
5. Создает systemd units и запускает Prometheus, Alertmanager и Grafana.

## Подробно по task'ам

### Play 1. Установка Node Exporter на все узлы

- `Создание пользователя node_exporter` создает системного пользователя без интерактивного shell. Сервис Node Exporter работает от отдельного пользователя, а не от root.
- `Создать директорию textfile collector` создает `/var/lib/node_exporter/textfile_collector`. Эта директория нужна для дополнительных метрик в формате `.prom`, которые могут складывать другие скрипты.
- `Проверка наличия бинарника Node Exporter` проверяет `/usr/local/bin/node_exporter` и сохраняет результат в `node_exporter_stat`.
- `Проверка бинарника Node Exporter в box-образе` — `assert`, что `/usr/local/bin/node_exporter` существует и executable (предустановлен в `diplom-ubuntu`).
- `Развернуть systemd-юнит Node Exporter` рендерит `templates/node_exporter/node_exporter.service.j2` в `/etc/systemd/system/node_exporter.service` и вызывает `Reload systemd`.
- `Активация и запуск Node Exporter` запускает `node_exporter.service`, включает автозапуск и делает `daemon_reload`.

### Play 2. Настройка Monitoring

- `Создание пользователей для сервисов` создает системных пользователей `prometheus` и `alertmanager` через `loop`. Каждый сервис получает отдельного пользователя.
- `Проверка наличия бинарника Prometheus` проверяет `/usr/local/bin/prometheus` и сохраняет результат в `prometheus_stat`.
- `Проверка бинарников Prometheus в box-образе` — `assert` для `/usr/local/bin/prometheus` и `/usr/local/bin/promtool`.
- `Создать директории Prometheus` создает `/etc/prometheus` для конфигурации и `/var/lib/prometheus` для данных TSDB.
- `Проверка наличия бинарника Alertmanager` проверяет `/usr/local/bin/alertmanager`.
- `Проверка бинарника Alertmanager в box-образе` — `assert` для `/usr/local/bin/alertmanager`.
- `Создать директории Alertmanager` создает `/etc/alertmanager` и `/var/lib/alertmanager` для конфигурации и runtime-данных.
- `Развернуть prometheus.yml` рендерит основной конфиг Prometheus в `/etc/prometheus/prometheus.yml`. В нем задаются scrape targets и подключение alert rules.
- `Развернуть alert_rules.yml` рендерит правила алертов в `/etc/prometheus/alert_rules.yml`.
- `Развернуть alertmanager.yml` рендерит конфигурацию Alertmanager, включая SMTP-настройки и получателя уведомлений.
- `Развернуть grafana.ini` рендерит основной конфиг Grafana в `/etc/grafana/grafana.ini`.
- `Создать директории provisioning Grafana` создает каталоги для datasources и dashboards provisioning. Это позволяет Grafana автоматически подхватить источники данных и dashboard definitions.
- `Создать директорию Grafana dashboards` создает `/var/lib/grafana/dashboards`, где хранится JSON dashboard.
- `Развернуть datasource Prometheus+Loki для Grafana` рендерит datasource provisioning, чтобы Grafana видела Prometheus и Loki без ручной настройки через UI.
- `Развернуть provider dashboards для Grafana` рендерит provider, который говорит Grafana читать dashboards из `/var/lib/grafana/dashboards`.
- `Развернуть dashboard инфраструктуры` рендерит `node-overview-dashboard.json` для обзора инфраструктурных метрик.
- `Развернуть systemd-юниты сервисов` создает unit-файлы для `prometheus` и `alertmanager` через `loop`. Grafana unit предполагается установленным пакетом.
- `Активация и запуск сервисов мониторинга` запускает и включает `prometheus.service`, `alertmanager.service` и `grafana-server.service`.

## Handlers

- `Reload UFW` выполняет `ufw reload`; в текущем playbook'е handler определен, но задачи его не вызывают.
- `Restart Prometheus` перезапускает `prometheus.service` после установки бинарника или изменения конфигурации/правил.
- `Restart Alertmanager` перезапускает `alertmanager.service` после установки бинарника или изменения конфигурации.
- `Restart Grafana` перезапускает `grafana-server.service` после изменения `grafana.ini`, datasource или dashboard provisioning.
- `Reload systemd` перечитывает unit-файлы после их размещения.
- `Restart Node Exporter` перезапускает `node_exporter.service` после установки бинарника.

## Используемые модули

В этом playbook'е используются уже описанные модули: `user`, `file`, `stat`, `shell`, `template`, `systemd`, `command`. Их описание см. в `ha_shared.md`.

Короткая форма handlers вида `systemd: { name: prometheus.service, state: restarted, daemon_reload: yes }` является YAML inline-записью тех же параметров модуля `ansible.builtin.systemd`.

## Связанные шаблоны и файлы

- `ansible/templates/node_exporter/node_exporter.service.j2`
- `ansible/templates/prometheus/prometheus.yml.j2`
- `ansible/templates/prometheus/alert_rules.yml.j2`
- `ansible/templates/prometheus/prometheus.service.j2`
- `ansible/templates/alertmanager/alertmanager.yml.j2`
- `ansible/templates/alertmanager/alertmanager.service.j2`
- `ansible/templates/grafana/grafana.ini.j2`
- `ansible/templates/grafana/grafana-datasources.yml.j2`
- `ansible/templates/grafana/grafana-dashboards.yml.j2`
- `ansible/templates/grafana/node-overview-dashboard.json.j2`
- `/usr/local/bin/node_exporter`
- `/usr/local/bin/prometheus`
- `/usr/local/bin/promtool`
- `/usr/local/bin/alertmanager`
- `/etc/prometheus`
- `/etc/alertmanager`
- `/etc/grafana/provisioning`
- `/var/lib/grafana/dashboards`
