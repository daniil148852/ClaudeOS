#!/bin/bash
# ============================================================
#  ClaudeOS Build Script
#  Собирает минималистичный Linux ISO для Limbo PC Emulator
#  Требования: Ubuntu/Debian, интернет, ~2GB свободного места
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ISO_DIR="$BUILD_DIR/iso"
ROOTFS_DIR="$BUILD_DIR/rootfs"
OUTPUT="$SCRIPT_DIR/claudeos.iso"

KERNEL_VERSION="6.1.90"
KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"
BUSYBOX_VERSION="1.36.1"
BUSYBOX_URL="https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
hdr()  { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

# ── 0. Зависимости ──────────────────────────────────────────
hdr "Установка зависимостей"
sudo apt-get update -q
sudo apt-get install -y \
  build-essential bc bison flex libssl-dev libelf-dev \
  libncurses-dev cpio xz-utils gzip wget curl \
  grub-pc-bin grub-common xorriso isolinux \
  2>/dev/null || err "Не удалось установить зависимости"
log "Зависимости установлены"

mkdir -p "$BUILD_DIR" "$ISO_DIR/boot/grub" "$ROOTFS_DIR"

# ── 1. Ядро Linux ───────────────────────────────────────────
hdr "Шаг 1: Сборка ядра Linux $KERNEL_VERSION"
cd "$BUILD_DIR"
if [ ! -f "linux-${KERNEL_VERSION}.tar.xz" ]; then
  log "Скачиваю ядро..."
  wget -q --show-progress "$KERNEL_URL"
fi
if [ ! -d "linux-${KERNEL_VERSION}" ]; then
  log "Распаковываю ядро..."
  tar xf "linux-${KERNEL_VERSION}.tar.xz"
fi

cd "linux-${KERNEL_VERSION}"
log "Конфигурирую ядро (минимальная конфигурация)..."
make x86_64_defconfig

# Оптимизации для Limbo/QEMU
cat >> .config << 'KCONF'
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_HW_RANDOM_VIRTIO=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_TTY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_EXT2_FS=y
CONFIG_EXT4_FS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_PRINTK=y
CONFIG_EARLY_PRINTK=y
KCONF

make olddefconfig
log "Собираю ядро (это займёт 10-30 минут)..."
make -j$(nproc) bzImage 2>&1 | grep -E "^(LD|CC|AR|LINK|Kernel)" | tail -5 || true
cp arch/x86/boot/bzImage "$ISO_DIR/boot/vmlinuz"
log "Ядро собрано: $(du -sh $ISO_DIR/boot/vmlinuz | cut -f1)"

# ── 2. BusyBox ──────────────────────────────────────────────
hdr "Шаг 2: Сборка BusyBox $BUSYBOX_VERSION"
cd "$BUILD_DIR"
if [ ! -f "busybox-${BUSYBOX_VERSION}.tar.bz2" ]; then
  log "Скачиваю BusyBox..."
  wget -q --show-progress "$BUSYBOX_URL"
fi
if [ ! -d "busybox-${BUSYBOX_VERSION}" ]; then
  tar xf "busybox-${BUSYBOX_VERSION}.tar.bz2"
fi

cd "busybox-${BUSYBOX_VERSION}"
make defconfig
# Статическая сборка (нет зависимостей от libc)
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
sed -i 's/CONFIG_STATIC=n/CONFIG_STATIC=y/' .config
echo 'CONFIG_STATIC=y' >> .config
make oldconfig 2>/dev/null || true
log "Собираю BusyBox..."
make -j$(nproc) 2>&1 | tail -3
make CONFIG_PREFIX="$ROOTFS_DIR" install
log "BusyBox установлен в rootfs"

# ── 3. Сборка rootfs ────────────────────────────────────────
hdr "Шаг 3: Создание файловой системы"
cd "$ROOTFS_DIR"

# Создаём структуру директорий
mkdir -p dev proc sys tmp run var/log var/tmp \
         etc/init.d home/user mnt \
         usr/share/claudeos

log "Создаю /etc файлы..."

# /etc/passwd
cat > etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
user:x:1000:1000:User:/home/user:/bin/sh
EOF

# /etc/group
cat > etc/group << 'EOF'
root:x:0:
users:x:1000:user
EOF

# /etc/hostname
echo "claudeos" > etc/hostname

# /etc/hosts
cat > etc/hosts << 'EOF'
127.0.0.1   localhost claudeos
EOF

# /etc/motd (баннер)
cat > etc/motd << 'EOF'

EOF

# ── 4. Скрипты ОС ───────────────────────────────────────────
log "Создаю скрипты ОС..."

# Главное init (PID 1)
cat > init << 'INITEOF'
#!/bin/sh
# ClaudeOS init - PID 1

# Монтируем виртуальные ФС
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null || \
  (mknod /dev/null c 1 3; mknod /dev/tty c 5 0; mknod /dev/console c 5 1)
mount -t tmpfs tmpfs /tmp 2>/dev/null
mount -t tmpfs tmpfs /run 2>/dev/null

# Настройка консоли
hostname claudeos
echo "claudeos" > /proc/sys/kernel/hostname 2>/dev/null || true

# Создаём устройства если нужно
for i in 0 1 2 3 4; do
  [ -c /dev/tty$i ] || mknod /dev/tty$i c 4 $i 2>/dev/null
done
[ -c /dev/ttyS0 ] || mknod /dev/ttyS0 c 4 64 2>/dev/null
[ -c /dev/random ] || mknod /dev/random c 1 8 2>/dev/null
[ -c /dev/urandom ] || mknod /dev/urandom c 1 9 2>/dev/null
[ -c /dev/zero ] || mknod /dev/zero c 1 5 2>/dev/null

# Запускаем getty на консоли
exec /sbin/getty -L tty1 115200 vt100 -n -l /usr/bin/claude-shell
INITEOF
chmod +x init

# ── 5. Claude Shell (главная оболочка с меню) ───────────────
mkdir -p usr/bin usr/sbin

cat > usr/bin/claude-shell << 'SHELL_EOF'
#!/bin/sh
# ClaudeOS главная оболочка с приветственным меню

# Цвета (ANSI)
R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;33m'
B='\033[1;34m'
M='\033[1;35m'
C='\033[1;36m'
W='\033[1;37m'
DIM='\033[2m'
N='\033[0m'

clear_screen() { printf '\033[2J\033[H'; }

show_banner() {
  clear_screen
  printf "${C}"
  printf "  ██████╗██╗      █████╗ ██╗   ██╗██████╗ ███████╗ ██████╗ ███████╗\n"
  printf " ██╔════╝██║     ██╔══██╗██║   ██║██╔══██╗██╔════╝██╔═══██╗██╔════╝\n"
  printf " ██║     ██║     ███████║██║   ██║██║  ██║█████╗  ██║   ██║███████╗\n"
  printf " ██║     ██║     ██╔══██║██║   ██║██║  ██║██╔══╝  ██║   ██║╚════██║\n"
  printf " ╚██████╗███████╗██║  ██║╚██████╔╝██████╔╝███████╗╚██████╔╝███████║\n"
  printf "  ╚═════╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝ ╚══════╝ ╚═════╝ ╚══════╝\n"
  printf "${N}"
  printf "${DIM}                    Minimal Linux OS v1.0 for Limbo PC${N}\n"
  printf "${DIM}              ────────────────────────────────────────────${N}\n\n"
}

show_main_menu() {
  show_banner
  printf "  ${W}┌─────────────────────────────────────────┐${N}\n"
  printf "  ${W}│          ${Y}✦  ГЛАВНОЕ МЕНЮ  ✦${W}             │${N}\n"
  printf "  ${W}├─────────────────────────────────────────┤${N}\n"
  printf "  ${W}│  ${G}[1]${W} 📁  Файловый менеджер              │${N}\n"
  printf "  ${W}│  ${G}[2]${W} 📝  Текстовый редактор             │${N}\n"
  printf "  ${W}│  ${G}[3]${W} 💻  Терминал (Shell)               │${N}\n"
  printf "  ${W}│  ${G}[4]${W} ℹ️   Информация о системе            │${N}\n"
  printf "  ${W}│  ${G}[5]${W} ⚙️   Настройки                      │${N}\n"
  printf "  ${W}│  ${G}[6]${W} 🎮  Игра (Snake)                   │${N}\n"
  printf "  ${W}│  ${R}[0]${W} 🔌  Выключить систему              │${N}\n"
  printf "  ${W}└─────────────────────────────────────────┘${N}\n\n"
  printf "  ${C}Введите номер: ${N}"
}

show_sysinfo() {
  clear_screen
  printf "${C}╔══════════════════════════════════════╗${N}\n"
  printf "${C}║      ИНФОРМАЦИЯ О СИСТЕМЕ            ║${N}\n"
  printf "${C}╚══════════════════════════════════════╝${N}\n\n"
  
  printf "  ${Y}ОС:${N}        ClaudeOS v1.0\n"
  printf "  ${Y}Ядро:${N}      $(uname -r 2>/dev/null || echo 'Linux')\n"
  printf "  ${Y}Архит.:${N}    $(uname -m 2>/dev/null || echo 'x86_64')\n"
  printf "  ${Y}Хост:${N}      $(hostname)\n"
  printf "  ${Y}Uptime:${N}    $(cat /proc/uptime 2>/dev/null | awk '{printf "%d мин", $1/60}' || echo 'N/A')\n\n"
  
  printf "  ${Y}Память:${N}\n"
  if [ -f /proc/meminfo ]; then
    TOTAL=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    FREE=$(grep MemFree /proc/meminfo | awk '{print $2}')
    USED=$((TOTAL - FREE))
    printf "    Всего:     $((TOTAL/1024)) MB\n"
    printf "    Занято:    $((USED/1024)) MB\n"
    printf "    Свободно:  $((FREE/1024)) MB\n"
  fi
  
  printf "\n  ${Y}Процессор:${N}\n"
  grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | sed 's/model name.*: /    /'
  
  printf "\n  ${Y}Диски:${N}\n"
  df -h 2>/dev/null | grep -v "^Filesystem" | head -5 | while read line; do
    printf "    $line\n"
  done
  
  printf "\n  ${DIM}Нажмите Enter для возврата...${N}"
  read _dummy
}

show_settings() {
  clear_screen
  printf "${C}╔══════════════════════════════════════╗${N}\n"
  printf "${C}║            НАСТРОЙКИ                 ║${N}\n"
  printf "${C}╚══════════════════════════════════════╝${N}\n\n"
  printf "  ${G}[1]${N} Изменить имя хоста\n"
  printf "  ${G}[2]${N} Установить дату/время\n"
  printf "  ${G}[3]${N} Показать переменные окружения\n"
  printf "  ${G}[0]${N} Назад\n\n"
  printf "  ${C}Выбор: ${N}"
  read choice
  case $choice in
    1)
      printf "  Новое имя хоста: "
      read new_hostname
      if [ -n "$new_hostname" ]; then
        hostname "$new_hostname"
        echo "$new_hostname" > /etc/hostname
        printf "  ${G}Имя хоста изменено на: $new_hostname${N}\n"
      fi
      sleep 1 ;;
    2)
      printf "  Дата (YYYY-MM-DD HH:MM:SS): "
      read new_date
      date -s "$new_date" 2>/dev/null && printf "  ${G}Дата установлена${N}\n" || printf "  ${R}Ошибка установки даты${N}\n"
      sleep 1 ;;
    3)
      clear_screen
      env | sort
      printf "\n  ${DIM}Нажмите Enter...${N}"; read _ ;;
  esac
}

# Встроенная игра Snake
play_snake() {
  clear_screen
  printf "${Y}╔══════════════════════════════════════╗${N}\n"
  printf "${Y}║           🐍 SNAKE GAME              ║${N}\n"
  printf "${Y}╠══════════════════════════════════════╣${N}\n"
  printf "${Y}║  Управление: WASD или стрелки        ║${N}\n"
  printf "${Y}║  Q - выход                           ║${N}\n"
  printf "${Y}╚══════════════════════════════════════╝${N}\n\n"
  printf "  ${DIM}(Простая текстовая версия Snake)${N}\n\n"
  
  # Простая демо-версия на sh
  W=20; H=10
  sx=10; sy=5; fx=5; fy=3
  score=0; dir="r"
  
  draw_field() {
    clear_screen
    printf "${Y}Score: $score${N}\n"
    printf "${W}+"
    for x in $(seq 1 $W); do printf "-"; done
    printf "+${N}\n"
    for y in $(seq 1 $H); do
      printf "${W}|${N}"
      for x in $(seq 1 $W); do
        if [ $x -eq $sx ] && [ $y -eq $sy ]; then
          printf "${G}O${N}"
        elif [ $x -eq $fx ] && [ $y -eq $fy ]; then
          printf "${R}*${N}"
        else
          printf " "
        fi
      done
      printf "${W}|${N}\n"
    done
    printf "${W}+"
    for x in $(seq 1 $W); do printf "-"; done
    printf "+${N}\n"
    printf "${DIM}WASD=движение Q=выход${N}\n"
  }
  
  stty -echo -icanon min 0 time 1 2>/dev/null
  while true; do
    draw_field
    ch=$(dd bs=1 count=1 2>/dev/null)
    case "$ch" in
      q|Q) break ;;
      w|W) [ $sy -gt 1 ] && sy=$((sy-1)) ;;
      s|S) [ $sy -lt $H ] && sy=$((sy+1)) ;;
      a|A) [ $sx -gt 1 ] && sx=$((sx-1)) ;;
      d|D) [ $sx -lt $W ] && sx=$((sx+1)) ;;
    esac
    if [ $sx -eq $fx ] && [ $sy -eq $fy ]; then
      score=$((score+10))
      fx=$((RANDOM % W + 1))
      fy=$((RANDOM % H + 1))
    fi
  done
  stty sane 2>/dev/null
  printf "\n  ${Y}Игра окончена! Счёт: $score${N}\n"
  printf "  ${DIM}Нажмите Enter...${N}"; read _
}

# Главный цикл
while true; do
  show_main_menu
  read choice
  case "$choice" in
    1) claude-fm ;;
    2) printf "  ${C}Имя файла: ${N}"; read fname; [ -n "$fname" ] && nano "$fname" 2>/dev/null || vi "$fname" 2>/dev/null || claude-editor "$fname" ;;
    3) clear_screen; printf "${G}ClaudeOS Shell${N} (введите 'exit' для возврата)\n"; sh; ;;
    4) show_sysinfo ;;
    5) show_settings ;;
    6) play_snake ;;
    0) 
      clear_screen
      printf "\n  ${Y}Завершение работы ClaudeOS...${N}\n\n"
      sync
      poweroff -f 2>/dev/null || halt -f 2>/dev/null || echo b > /proc/sysrq-trigger
      ;;
    *) printf "  ${R}Неверный выбор${N}\n"; sleep 1 ;;
  esac
done
SHELL_EOF
chmod +x usr/bin/claude-shell

# ── 6. Файловый менеджер ────────────────────────────────────
cat > usr/bin/claude-fm << 'FM_EOF'
#!/bin/sh
# ClaudeOS Файловый менеджер

R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[1;37m'
DIM='\033[2m'; N='\033[0m'

CWD="/"
SELECTED=0

list_dir() {
  ls -la --color=never "$CWD" 2>/dev/null
}

draw_fm() {
  printf '\033[2J\033[H'
  printf "${C}╔══════════════════════════════════════════════╗${N}\n"
  printf "${C}║  📁 ФАЙЛОВЫЙ МЕНЕДЖЕР  ClaudeOS FM          ║${N}\n"
  printf "${C}╠══════════════════════════════════════════════╣${N}\n"
  printf "${C}║  Путь: %-38s║${N}\n" "$CWD"
  printf "${C}╚══════════════════════════════════════════════╝${N}\n\n"
  
  # Список файлов
  i=0
  ls -la "$CWD" 2>/dev/null | while IFS= read -r line; do
    if echo "$line" | grep -q "^d"; then
      printf "  ${B}%s${N}\n" "$line"
    elif echo "$line" | grep -q "^-x\|rwx"; then
      printf "  ${G}%s${N}\n" "$line"
    elif echo "$line" | grep -q "^l"; then
      printf "  ${C}%s${N}\n" "$line"
    else
      printf "  ${W}%s${N}\n" "$line"
    fi
  done
  
  printf "\n${C}─────────────────────────────────────────────────${N}\n"
  printf "${Y}[cd]${N} Перейти  ${Y}[cp]${N} Копировать  ${Y}[mv]${N} Переместить\n"
  printf "${Y}[rm]${N} Удалить  ${Y}[mk]${N} Создать дир ${Y}[vi]${N} Редактировать\n"
  printf "${Y}[ls]${N} Обновить ${Y}[q]${N}  Выход\n"
  printf "\n${C}Команда: ${N}"
}

while true; do
  draw_fm
  read cmd arg1 arg2
  
  case "$cmd" in
    cd)
      if [ "$arg1" = ".." ]; then
        CWD=$(dirname "$CWD")
      elif [ -d "$CWD/$arg1" ]; then
        CWD="$CWD/$arg1"
      elif [ -d "$arg1" ]; then
        CWD="$arg1"
      else
        printf "${R}Директория не найдена: $arg1${N}\n"; sleep 1
      fi ;;
    cp)
      [ -n "$arg1" ] && [ -n "$arg2" ] && cp -r "$CWD/$arg1" "$CWD/$arg2" && \
        printf "${G}Скопировано!${N}\n" && sleep 1 ;;
    mv)
      [ -n "$arg1" ] && [ -n "$arg2" ] && mv "$CWD/$arg1" "$CWD/$arg2" && \
        printf "${G}Перемещено!${N}\n" && sleep 1 ;;
    rm)
      if [ -n "$arg1" ]; then
        printf "${R}Удалить $arg1? [y/N]: ${N}"
        read confirm
        [ "$confirm" = "y" ] && rm -rf "$CWD/$arg1" && \
          printf "${G}Удалено!${N}\n" && sleep 1
      fi ;;
    mk|mkdir)
      [ -n "$arg1" ] && mkdir -p "$CWD/$arg1" && \
        printf "${G}Директория создана!${N}\n" && sleep 1 ;;
    vi|edit)
      [ -n "$arg1" ] && (nano "$CWD/$arg1" 2>/dev/null || vi "$CWD/$arg1" 2>/dev/null || claude-editor "$CWD/$arg1") ;;
    cat|view)
      [ -n "$arg1" ] && cat "$CWD/$arg1" 2>/dev/null | head -50
      printf "\n${DIM}Нажмите Enter...${N}"; read _ ;;
    ls) ;; # просто перерисует
    q|quit|exit) break ;;
    *) [ -n "$cmd" ] && printf "${R}Неизвестная команда: $cmd${N}\n" && sleep 1 ;;
  esac
done
FM_EOF
chmod +x usr/bin/claude-fm

# ── 7. Текстовый редактор ───────────────────────────────────
cat > usr/bin/claude-editor << 'ED_EOF'
#!/bin/sh
# ClaudeOS простой текстовый редактор

R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
C='\033[1;36m'; W='\033[1;37m'; DIM='\033[2m'; N='\033[0m'

FILE="${1:-/tmp/untitled.txt}"
TMPFILE="/tmp/editor_$$.tmp"

# Читаем файл в переменную
if [ -f "$FILE" ]; then
  cp "$FILE" "$TMPFILE"
else
  > "$TMPFILE"
fi

printf '\033[2J\033[H'
printf "${C}╔══════════════════════════════════════════════╗${N}\n"
printf "${C}║  📝 ТЕКСТОВЫЙ РЕДАКТОР - ClaudeOS Editor    ║${N}\n"
printf "${C}║  Файл: %-38s║${N}\n" "$FILE"
printf "${C}╠══════════════════════════════════════════════╣${N}\n"
printf "${C}║  ${Y}:w${C} - сохранить  ${Y}:q${C} - выйти  ${Y}:wq${C} - оба  ║${N}\n"
printf "${C}╚══════════════════════════════════════════════╝${N}\n\n"

printf "${DIM}Содержимое файла:${N}\n"
printf "${W}─────────────────────────────────────────────────${N}\n"
cat -n "$TMPFILE" 2>/dev/null
printf "${W}─────────────────────────────────────────────────${N}\n\n"

printf "${Y}Режимы:${N}\n"
printf "  ${G}a${N}  - добавить строку в конец\n"
printf "  ${G}i N${N} - вставить строку перед строкой N\n"
printf "  ${G}d N${N} - удалить строку N\n"
printf "  ${G}r N${N} - заменить строку N\n"
printf "  ${G}:w${N} - сохранить\n"
printf "  ${G}:q${N} - выйти без сохранения\n"
printf "  ${G}:wq${N} - сохранить и выйти\n\n"

MODIFIED=0
while true; do
  printf "${C}editor>${N} "
  read cmd arg rest
  
  case "$cmd" in
    a|append)
      printf "Введите строку: "
      read new_line
      echo "$new_line" >> "$TMPFILE"
      MODIFIED=1
      printf "${G}Добавлено.${N}\n" ;;
    i)
      [ -z "$arg" ] && printf "${R}Укажите номер строки${N}\n" && continue
      printf "Вставить перед строкой $arg: "
      read new_line
      sed -i "${arg}i\\$new_line" "$TMPFILE" 2>/dev/null
      MODIFIED=1
      printf "${G}Вставлено.${N}\n" ;;
    d)
      [ -z "$arg" ] && printf "${R}Укажите номер строки${N}\n" && continue
      sed -i "${arg}d" "$TMPFILE" 2>/dev/null
      MODIFIED=1
      printf "${G}Удалено.${N}\n" ;;
    r)
      [ -z "$arg" ] && printf "${R}Укажите номер строки${N}\n" && continue
      printf "Новое содержимое строки $arg: "
      read new_line
      sed -i "${arg}s/.*/$new_line/" "$TMPFILE" 2>/dev/null
      MODIFIED=1
      printf "${G}Заменено.${N}\n" ;;
    p|print|show)
      printf "\n${W}─────────────────────────────────────────────────${N}\n"
      cat -n "$TMPFILE" 2>/dev/null
      printf "${W}─────────────────────────────────────────────────${N}\n" ;;
    :w)
      cp "$TMPFILE" "$FILE"
      printf "${G}Сохранено: $FILE${N}\n"
      MODIFIED=0 ;;
    :q)
      if [ $MODIFIED -eq 1 ]; then
        printf "${Y}Есть несохранённые изменения. Выйти? [y/N]: ${N}"
        read confirm
        [ "$confirm" = "y" ] && break
      else
        break
      fi ;;
    :wq|:x)
      cp "$TMPFILE" "$FILE"
      printf "${G}Сохранено и выход: $FILE${N}\n"
      break ;;
    "") ;; # пустая строка - ничего
    *) printf "${R}Неизвестная команда. Введите :q для выхода${N}\n" ;;
  esac
done

rm -f "$TMPFILE"
ED_EOF
chmod +x usr/bin/claude-editor

# ── 8. Профиль и алиасы ─────────────────────────────────────
cat > etc/profile << 'PROF_EOF'
export PATH="/bin:/sbin:/usr/bin:/usr/sbin"
export HOME="/root"
export PS1="\033[1;32mclaudeos\033[0m:\033[1;34m\w\033[0m\$ "
export TERM="linux"

alias ll='ls -la'
alias la='ls -la'
alias l='ls -lh'
alias cls='clear'
alias menu='claude-shell'
alias fm='claude-fm'
alias edit='claude-editor'

# Показываем MOTD при входе в shell
if [ -f /etc/motd ]; then
  cat /etc/motd
fi
echo "ClaudeOS v1.0 | Введите 'menu' для главного меню"
PROF_EOF

# ── 9. Создание initramfs ────────────────────────────────────
hdr "Шаг 4: Создание initramfs"
cd "$ROOTFS_DIR"
find . | cpio -oH newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initramfs.cpio.gz"
log "initramfs создан: $(du -sh $ISO_DIR/boot/initramfs.cpio.gz | cut -f1)"

# ── 10. GRUB конфигурация ────────────────────────────────────
hdr "Шаг 5: Настройка GRUB загрузчика"
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
# ClaudeOS GRUB конфигурация
set default=0
set timeout=3

insmod all_video
insmod gfxterm
insmod vbe

# Тема
set color_normal=cyan/black
set color_highlight=black/cyan
set menu_color_normal=white/black
set menu_color_highlight=cyan/black

menuentry "ClaudeOS v1.0" --class os {
  echo "Запуск ClaudeOS..."
  linux /boot/vmlinuz console=ttyS0,115200 console=tty0 \
        root=/dev/ram0 rootfstype=tmpfs \
        quiet loglevel=3
  initrd /boot/initramfs.cpio.gz
}

menuentry "ClaudeOS v1.0 (отладка)" --class os {
  linux /boot/vmlinuz console=ttyS0,115200 console=tty0 \
        root=/dev/ram0 rootfstype=tmpfs \
        loglevel=7 debug
  initrd /boot/initramfs.cpio.gz
}
GRUB_EOF

log "GRUB конфигурация создана"

# ── 11. Сборка ISO ───────────────────────────────────────────
hdr "Шаг 6: Сборка ISO образа"
grub-mkrescue -o "$OUTPUT" "$ISO_DIR" \
  --compress=xz \
  2>&1 | tail -5

if [ -f "$OUTPUT" ]; then
  SIZE=$(du -sh "$OUTPUT" | cut -f1)
  log "✅ ISO успешно создан!"
  echo ""
  echo -e "${GREEN}═══════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ✦  claudeos.iso  |  Размер: $SIZE  ✦${NC}"
  echo -e "${GREEN}═══════════════════════════════════════════${NC}"
  echo ""
  echo "  Файл: $OUTPUT"
  echo ""
  echo "  Настройки Limbo PC Emulator:"
  echo "  ─────────────────────────────"
  echo "  Архитектура: x86_64"
  echo "  RAM: 256 MB+"
  echo "  CDROM: claudeos.iso"
  echo "  CPU cores: 2+"
  echo ""
else
  err "Ошибка создания ISO!"
fi
