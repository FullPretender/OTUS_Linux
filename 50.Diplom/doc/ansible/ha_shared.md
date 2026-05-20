# ha_shared.yml

## Где выполняется

`ha_shared.yml` выполняется на группе `logging` из `ansible/hosts.ini`.

- Хост: `192.168.56.40`.
- `become: yes`: все задачи выполняются с повышением привилегий.
- Основные внутренние адреса, используемые playbook'ом: `10.10.10.40` как узел Rest Server, NFS и HAProxy; `10.10.10.0/24` как сеть клиентов.
- Важные переменные: `restic_server_user`, `restic_server_password`, `restic_password`, а также переменные MySQL/WordPress из `group_vars`. Секретные значения берутся через Ansible Vault и в документации не раскрываются.

## Что делает playbook

Playbook готовит общий инфраструктурный узел для backend/frontend:

1. Создает системного пользователя `restic`.
2. Временно разрешает доступ к портам DB endpoint, NFS и Rest Server до финального применения `UFW.yml`.
3. Устанавливает и запускает `rest-server`.
4. Готовит директории Restic-репозиториев для frontend и backend.
5. Создает общий каталог `wp-content` и экспортирует его через NFSv4.
6. Настраивает HAProxy как стабильную точку подключения WordPress к MySQL.

## Подробно по task'ам

### Создание пользователя Restic

Task создает системного пользователя `restic` без shell и домашнего каталога. Он нужен, чтобы процесс `rest-server` и директории backup-репозиториев не работали от `root`, а имели отдельного владельца с минимально необходимыми правами.

Используется `ansible.builtin.user` с параметрами `system: yes`, `shell: /usr/sbin/nologin`, `create_home: no`.

### Разрешение DB endpoint и NFS до монтирования backend-узлами

Task выполняет команды `ufw allow` для портов `6033`, `2049` и `8000`.

- `6033` нужен для HAProxy MySQL endpoint.
- `2049` нужен для NFSv4 export общего `wp-content`.
- `8000` нужен для Rest Server.

Задача использует `loop`, чтобы одинаково применить правило к каждому порту. `changed_when: false` не помечает play как измененный из-за ручной команды UFW, а `failed_when: false` позволяет не падать, если UFW еще не готов или правило уже существует. Финальная политика firewall отдельно закрепляется в `UFW.md`.

### Проверка наличия бинарника Rest Server

Task проверяет путь `/usr/local/bin/rest-server` и сохраняет результат в `rest_server_stat`. Это нужно для идемпотентности: следующий task устанавливает бинарник только если его еще нет.

### Установить бинарник Rest Server из box-архива

Task распаковывает `rest-server` из `/opt/rest-server.tar.gz` в `/usr/local/bin/rest-server` и выставляет права `0755`.

Ключевые детали:

- `args.creates: /usr/local/bin/rest-server` защищает от повторной установки.
- `when: not rest_server_stat.stat.exists` дополнительно делает установку условной.
- `notify: Restart Rest Server` перезапускает сервис только если бинарник был установлен.

Зачем это нужно: стенд использует заранее подготовленный архив в Vagrant box, а не скачивание из интернета во время provisioning.

### Создать директорию для репозиториев Restic

Task создает `/srv/restic` с владельцем `restic:restic` и правами `0755`. Это корневая директория, где `rest-server` будет хранить отдельные репозитории клиентов.

### Создать поддиректории для клиентов Restic

Task создает три поддиректории:

- `/srv/restic/frontend`
- `/srv/restic/backend_master`
- `/srv/restic/backend_slave`

Права `0700` ограничивают доступ к репозиториям владельцем `restic`. `loop` используется, чтобы одинаково создать все клиентские каталоги.

### Создать директорию для htpasswd Rest Server

Task создает `/etc/restic` с владельцем `root:root`. В этой директории хранится файл `.htpasswd` для basic authentication Rest Server.

### Создать файл паролей htpasswd для Rest Server

Task запускает `htpasswd -Bbc /etc/restic/.htpasswd ...`, создавая файл с bcrypt-хэшем пользователя Rest Server.

`args.creates: /etc/restic/.htpasswd` делает команду одноразовой: при повторном запуске файл не перезаписывается. При создании файла вызывается handler `Restart Rest Server`, чтобы сервис перечитал учетные данные.

### Развернуть systemd-юнит Rest Server

Task рендерит шаблон `templates/rest-server/rest-server.service.j2` в `/etc/systemd/system/rest-server.service`. Unit описывает, как systemd должен запускать Rest Server.

`notify: Reload systemd` нужен, потому что после изменения unit-файла systemd должен перечитать конфигурацию.

### Активация Rest Server

Task включает и запускает `rest-server.service`.

- `state: started` гарантирует, что сервис работает сейчас.
- `enabled: yes` включает автозапуск после reboot.
- `daemon_reload: yes` дополнительно перечитывает unit-файлы.

### Создание директории общего wp-content

Task создает `/srv/wordpress/wp-content` с владельцем `www-data:www-data` и правами `0775`. Это общий каталог WordPress-контента, который backend-узлы позже смонтируют в `/var/www/wordpress/wp-content`.

### Создание директории drop-in exports для NFS

Task создает `/etc/exports.d`, куда помещается отдельный файл export'а. Такой подход не редактирует основной `/etc/exports` и делает настройку NFS изолированной для проекта.

### Проверка наличия demo-темы в общем wp-content

Task проверяет файл `/srv/wordpress/wp-content/themes/demo-forum-theme/style.css` и сохраняет результат в `shared_demo_theme`. Это маркер, что demo-контент уже развернут.

### Развёртывание demo wp-content в общий NFS export

Task копирует `templates/wordpress/demo/wp-content/` в `/srv/wordpress/wp-content/`, если demo-тема еще отсутствует.

Параметр `mode: preserve` сохраняет режимы файлов из исходного дерева. Цель задачи — один раз наполнить общий NFS-каталог темой и плагином demo-сайта, чтобы оба backend-узла видели одинаковый `wp-content`.

### Разрешение NFSv4 export для backend-сети

Task создает файл `/etc/exports.d/wordpress-wp-content.exports` с правилом:

`/srv/wordpress/wp-content 10.10.10.0/24(rw,sync,no_subtree_check,no_root_squash,fsid=10)`

Это разрешает backend-сети читать и писать общий `wp-content` по NFSv4. После изменения файла вызывается handler `Reload NFS exports`.

### Применение NFS exports

Task выполняет `exportfs -ra`, чтобы перечитать exports без ручного вмешательства. `changed_when: false` оставляет задачу проверочной/применяющей, но не помечает каждый запуск как изменение.

### Активация NFS Server

Task запускает и включает `nfs-server.service`. Это делает NFS export доступным для backend-узлов и сохраняет запуск после reboot.

### Развертывание HAProxy для стабильного DB endpoint

Task рендерит `templates/haproxy/mysql-writer.cfg.j2` в `/etc/haproxy/haproxy.cfg`.

HAProxy нужен как стабильная точка подключения к MySQL writer. WordPress может обращаться к одному DB endpoint, а HAProxy уже направляет трафик на нужный backend. При изменении конфигурации вызывается `Restart HAProxy`.

### Активация HAProxy

Task запускает и включает `haproxy.service`. После этого DB endpoint на `10.10.10.40:6033` готов принимать подключения от backend/WordPress-компонентов.

## Handlers

- `Reload NFS exports` выполняет `exportfs -ra`, когда меняется файл export'а.
- `Restart HAProxy` перезапускает `haproxy.service` и включает автозапуск после изменения конфигурации.
- `Restart Rest Server` перезапускает `rest-server.service`, включает автозапуск и делает `daemon_reload`.
- `Reload systemd` перечитывает systemd unit-файлы после размещения нового unit.

## Используемые модули

### `ansible.builtin.user`

Создает, изменяет или удаляет пользователей. В этом playbook'е используется для системного пользователя `restic`, которому не нужен интерактивный вход. Такой модуль идемпотентен: если пользователь уже существует с нужными параметрами, повторный запуск ничего не меняет.

### `ansible.builtin.command`

Выполняет команду без shell-интерпретации. Используется для `ufw allow` и `exportfs -ra`, где не нужны пайпы, редиректы или переменные shell. Важные параметры в проекте: `changed_when` и `failed_when`, которые корректируют статус задачи под инфраструктурный сценарий.

### `ansible.builtin.stat`

Собирает информацию о файле или директории. Здесь проверяет наличие бинарника `rest-server` и demo-темы. Результат сохраняется через `register` и используется в `when`.

### `ansible.builtin.shell`

Выполняет команду через shell. Нужен там, где используются пайпы, редиректы, переменные, `set -eu` или сложные команды. В этом playbook'е применяется для распаковки бинарника из архива и создания htpasswd-файла.

### `ansible.builtin.file`

Управляет файлами, директориями, ссылками и правами. В этом playbook'е создает директории Restic, NFS и WordPress, задает владельца, группу и mode.

### `ansible.builtin.template`

Рендерит Jinja2-шаблон на удаленный хост. Используется для systemd unit Rest Server и конфигурации HAProxy, потому что содержимое зависит от переменных проекта.

### `ansible.builtin.systemd`

Управляет systemd-сервисами и daemon reload. Здесь запускает и включает `rest-server.service`, `nfs-server.service`, `haproxy.service`, а также используется в handlers.

### `ansible.builtin.copy`

Копирует файл или директорию либо создает файл из inline-содержимого. В этом playbook'е используется для demo `wp-content` и NFS export-файла.

## Связанные шаблоны и файлы

- `ansible/templates/rest-server/rest-server.service.j2`
- `ansible/templates/haproxy/mysql-writer.cfg.j2`
- `ansible/templates/wordpress/demo/wp-content/`
- `/opt/rest-server.tar.gz`
- `/srv/restic/`
- `/etc/restic/.htpasswd`
- `/srv/wordpress/wp-content`
- `/etc/exports.d/wordpress-wp-content.exports`
- `/etc/haproxy/haproxy.cfg`
