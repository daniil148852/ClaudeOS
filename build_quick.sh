#!/bin/bash
# ============================================================
#  ClaudeOS БЫСТРАЯ СБОРКА (использует TinyCore ядро)
#  Не требует компиляции ядра! Готово за ~5 минут
# ============================================================

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build_quick"
ISO_DIR="$BUILD_DIR/iso"
ROOTFS_DIR="$BUILD_DIR/rootfs"
OUTPUT="$SCRIPT_DIR/claudeos_quick.iso"

# Используем готовое ядро от TinyCore Linux (очень маленькое и быстрое)
TINYCORE_URL="http://tinycorelinux.net/14.x/x86_64/release/TinyCorePure64-14.0.iso"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
hdr()  { echo -e "\n${CYAN}══════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════${NC}"; }

hdr "ClaudeOS Быстрая сборка"
log "Устанавливаю зависимости..."
sudo apt-get install -y xorriso grub-pc-bin grub-common isolinux cpio gzip wget 2>/dev/null

mkdir -p "$BUILD_DIR" "$ISO_DIR/boot/grub" "$ROOTFS_DIR"

hdr "Скачиваю TinyCore Linux (для извлечения ядра)"
cd "$BUILD_DIR"
if [ ! -f "tinycore.iso" ]; then
  wget -q --show-progress "$TINYCORE_URL" -O tinycore.iso || \
  err "Не удалось скачать TinyCore. Используй build.sh для компиляции ядра"
fi

log "Извлекаю ядро из TinyCore ISO..."
mkdir -p tinycore_mnt
sudo mount -o loop tinycore.iso tinycore_mnt 2>/dev/null || \
  (mkdir -p tinycore_ext && cd tinycore_ext && 7z x ../tinycore.iso >/dev/null 2>&1)

# Ищем ядро
VMLINUZ=$(find tinycore_mnt tinycore_ext 2>/dev/null -name "vmlinuz*" | head -1)
INITRD=$(find tinycore_mnt tinycore_ext 2>/dev/null -name "*.gz" -size +1M | head -1)

[ -z "$VMLINUZ" ] && err "Ядро не найдено в TinyCore ISO"
cp "$VMLINUZ" "$ISO_DIR/boot/vmlinuz"
log "Ядро извлечено: $(du -sh $ISO_DIR/boot/vmlinuz | cut -f1)"

hdr "Создаю ClaudeOS rootfs поверх TinyCore initrd"

# Распаковываем оригинальный initrd
if [ -n "$INITRD" ]; then
  cd "$ROOTFS_DIR"
  zcat "$INITRD" | cpio -id 2>/dev/null || gunzip -c "$INITRD" | cpio -id 2>/dev/null || true
  log "Базовый initrd распакован"
fi

# Добавляем наши скрипты (они уже в build.sh, здесь краткая версия)
cd "$ROOTFS_DIR"
mkdir -p usr/bin usr/share/claudeos etc

# Копируем все скрипты из основного build.sh
for f in claude-shell claude-fm claude-editor; do
  if [ -f "$SCRIPT_DIR/scripts/$f" ]; then
    cp "$SCRIPT_DIR/scripts/$f" "usr/bin/$f"
    chmod +x "usr/bin/$f"
    log "Скопирован: $f"
  fi
done

# Перепаковываем
log "Упаковываю initramfs..."
find . | cpio -oH newc 2>/dev/null | gzip -9 > "$ISO_DIR/boot/initramfs.cpio.gz"

# GRUB
cat > "$ISO_DIR/boot/grub/grub.cfg" << 'GRUB_EOF'
set default=0
set timeout=3
set color_normal=cyan/black
set color_highlight=black/cyan

menuentry "ClaudeOS v1.0 (TinyCore base)" {
  linux /boot/vmlinuz quiet loglevel=3
  initrd /boot/initramfs.cpio.gz
}
GRUB_EOF

# Финальная сборка ISO
grub-mkrescue -o "$OUTPUT" "$ISO_DIR" 2>&1 | tail -3

sudo umount tinycore_mnt 2>/dev/null || true

[ -f "$OUTPUT" ] && log "✅ Готово! $OUTPUT ($(du -sh $OUTPUT | cut -f1))" || err "Ошибка!"
