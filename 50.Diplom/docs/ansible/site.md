# site.yml

Агрегатор полного развёртывания. Обзор архитектуры: [ARCHITECTURE.md](../ARCHITECTURE.md).

## Где выполняется

`site.yml` находится в `ansible/site.yml` и не содержит собственного блока `hosts`. Это агрегирующий playbook: он последовательно импортирует остальные playbook'и проекта и запускает их в том порядке, в котором они перечислены.

Фактические группы хостов, `become`, переменные и handlers определяются внутри импортируемых файлов. Inventory по умолчанию задан в `ansible/ansible.cfg` и указывает на `ansible/hosts.ini`.

## Что делает playbook

Playbook описывает полный сценарий развертывания стенда:

1. Готовит общий узел `logging` для Restic, NFS и HAProxy.
2. Настраивает backend-узлы с MySQL, WordPress, PHP-FPM, Nginx, репликацией и backup.
3. Настраивает frontend-узел с Nginx load balancer и HTTPS.
4. Поднимает Loki, затем мониторинг и Alloy, инициализирует Restic и применяет firewall.

## Подробно по task'ам

В этом файле нет обычных `tasks`; каждая строка `import_playbook` подключает отдельный playbook на этапе разбора Ansible.

- `import_playbook: ha_shared.yml` запускает подготовку общего состояния WordPress на узле `logging`: Rest Server для backup, NFS export для `wp-content` и HAProxy как стабильный DB endpoint. Этот playbook стоит первым, потому что backend позже монтирует NFS и обращается к Rest Server.
- `import_playbook: back.yml` настраивает backend master/slave: MySQL, WordPress, PHP-FPM, Nginx, репликацию, HA-синхронизацию и клиентские backup-задачи.
- `import_playbook: front.yml` настраивает frontend после backend, чтобы upstream-проверки и HTTPS-прокси могли обращаться к уже подготовленным backend-узлам.
- `import_playbook: logging.yml` поднимает Loki на узле `logging` (до Alloy и до scrape Prometheus — Loki должен принимать push).
- `import_playbook: monitoring.yml` ставит Node Exporter на все узлы и поднимает Prometheus, Alertmanager и Grafana на `monitoring`.
- `import_playbook: alloy.yml` разворачивает Grafana Alloy на всех узлах и отправляет логи в Loki.
- `import_playbook: restic_init.yml` дожидается Rest Server, инициализирует Restic-репозитории и запускает первый backup, если репозиторий пуст.
- `import_playbook: UFW.yml` применяет firewall-правила в конце, когда основные сервисы уже развернуты и известны нужные порты.

## Handlers

В `site.yml` handlers отсутствуют. Все перезапуски сервисов и reload-действия определены в импортируемых playbook'ах.

## Используемые модули

### `import_playbook`

`import_playbook` статически подключает другой playbook. Ansible читает импортируемый файл заранее, до выполнения задач, поэтому порядок строк в `site.yml` становится порядком развертывания всего стенда.

В этом проекте `import_playbook` выбран для верхнеуровневой оркестрации: каждый функциональный слой описан отдельным файлом, а `site.yml` собирает их в единый сценарий запуска.

## Связанные шаблоны и файлы

- `ansible/ha_shared.yml`
- `ansible/back.yml`
- `ansible/front.yml`
- `ansible/logging.yml`
- `ansible/monitoring.yml`
- `ansible/alloy.yml`
- `ansible/restic_init.yml`
- `ansible/UFW.yml`
- `ansible/hosts.ini`
- `ansible/ansible.cfg`
