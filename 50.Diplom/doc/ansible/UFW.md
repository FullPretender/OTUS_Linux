# UFW.yml

## Где выполняется

`UFW.yml` выполняется на `hosts: all`.

- Целевые узлы: frontend, backend master/slave, monitoring, logging.
- `become: yes`: firewall настраивается с root-правами.
- Набор правил собирается динамически из `base_ufw_rules` и group-specific списков по `group_names`.

## Что делает playbook

Playbook применяет host-specific firewall-политику:

1. Формирует список правил для каждого хоста на основе его inventory-групп.
2. Разрешает только нужные входящие порты.
3. Устанавливает default deny для входящего трафика.
4. Разрешает исходящий трафик по умолчанию.
5. Включает UFW и логирование.

## Правила по группам

`base_ufw_rules` применяются на всех узлах:

- SSH `22/tcp` из `192.168.56.0/24`.
- SSH `22/tcp` от `10.0.2.2`.
- Node Exporter `9100/tcp` от monitoring-узла `10.10.10.30`.

`frontend_ufw_rules`:

- HTTP `80/tcp` от `any`.
- HTTPS `443/tcp` от `any`.

`backend_master_ufw_rules`:

- MySQL `3306/tcp` от slave `10.10.10.21`.
- MySQL `3306/tcp` от logging/HAProxy `10.10.10.40`.
- HTTP `80/tcp` от frontend `10.10.10.10`.

`backend_slave_ufw_rules`:

- MySQL `3306/tcp` от master `10.10.10.20`.
- MySQL `3306/tcp` от logging/HAProxy `10.10.10.40`.
- HTTP `80/tcp` от frontend `10.10.10.10`.

`monitoring_ufw_rules`:

- Node Exporter `9100/tcp` от `10.10.10.0/24`.
- Prometheus `9090/tcp` от frontend `10.10.10.10`.
- Grafana `3000/tcp` от frontend `10.10.10.10`.
- Alertmanager `9093/tcp` от frontend `10.10.10.10`.

`logging_ufw_rules`:

- Loki `3100/tcp` от `10.10.10.0/24`.
- Node Exporter `9100/tcp` от `10.10.10.0/24`.
- Rest Server `8000/tcp` от `10.10.10.0/24`.
- HAProxy MySQL endpoint `6033/tcp` от `10.10.10.0/24`.
- NFS `2049/tcp` от `10.10.10.0/24`.

## Подробно по task'ам

- `Применение правил UFW` проходит циклом по `ufw_rules`. Этот список собирается из базовых правил и правил групп, в которых находится текущий хост. Для каждого элемента задаются `rule`, `port`, `proto` и `from`. При изменении вызывается handler `Reload UFW`.
- `UFW запрет входящих по умолчанию` задает default policy `deny` для входящего трафика. Это закрывает все входящие подключения, которые не разрешены явными правилами выше.
- `UFW разрешение исходящих по умолчанию` задает default policy `allow` для исходящего трафика. Узлы могут обращаться к репозиториям, сервисам внутри стенда и DNS/системным сервисам без отдельного правила на каждый исходящий порт.
- `UFW включение файервола` включает UFW и логирование. После этого правила начинают применяться постоянно.

## Handlers

- `Reload UFW` выполняет `ufw reload`. `changed_when: false` не помечает reload как самостоятельное изменение при каждом вызове handler.

## Используемые модули

Модуль `command` для handler reload описан в `ha_shared.md`.

### `ufw`

Short name `ufw` соответствует Ansible-модулю управления Uncomplicated Firewall. В зависимости от установленной коллекции он обычно доступен как `community.general.ufw`.

Модуль идемпотентно управляет правилами и политиками UFW:

- `rule`, `port`, `proto`, `from` задают конкретное разрешающее правило.
- `direction` и `default` задают политики по умолчанию.
- `state: enabled` включает firewall.
- `logging: "on"` включает логирование.

В этом playbook'е модуль выбран вместо shell-команд для самих правил, потому что он лучше отражает желаемое состояние firewall и не создает лишних изменений при повторном запуске.

## Связанные шаблоны и файлы

Шаблоны не используются. Логика правил находится прямо в `ansible/UFW.yml`, а принадлежность хостов к группам задается в `ansible/hosts.ini`.
