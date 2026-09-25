#!/usr/bin/env bash
#
# setup-nvidia-debian-sid.sh — Driver NVIDIA para Debian Sid
#
# Instala el driver nvidia-open vía el repositorio CUDA oficial de NVIDIA
# (rama debian13), switcheroo-control si hay GPU híbrida, y el wrapper
# nvidia-run para PRIME offload selectivo.
#
# Proyecto hermano de setup-debian-sid.sh: antes esta lógica vivía ahí
# (secciones 8 y 9), pero se separó a su propio repo/script para poder
# ser una acción independiente del lanzador (lanzador-debian-sid) y
# para no volver a tocar el setup base cada vez que cambie algo del
# driver NVIDIA.
#
# Uso:
#   chmod +x setup-nvidia-debian-sid.sh
#   ./setup-nvidia-debian-sid.sh          # modo interactivo
#   ./setup-nvidia-debian-sid.sh -y       # no interactivo (ver --help)
#
# Licencia: MIT

set -euo pipefail

TITLE="Driver NVIDIA — Debian Sid csr79a"
VERSION="1.0.0"

log()   { echo -e "\e[1;34m[*]\e[0m $*"; }
ok()    { echo -e "\e[1;32m[OK]\e[0m $*"; }
warn()  { echo -e "\e[1;33m[!]\e[0m $*"; }
error() { echo -e "\e[1;31m[ERROR]\e[0m $*" >&2; exit 1; }

# ----------------------------------------------------------------------
# 0. Opciones de línea de comandos
# ----------------------------------------------------------------------

ASSUME_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -y|--yes)
      ASSUME_YES=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Uso: $0 [-y|--yes] [-h|--help]

  -y, --yes   Modo no interactivo: acepta automáticamente TODAS las
              preguntas, incluida la instalación del driver y la
              modificación de GRUB/initramfs/blacklist de nouveau.

  -h, --help  Muestra esta ayuda.
EOF
      exit 0
      ;;
    *)
      echo "Opción desconocida: $1" >&2
      exit 1
      ;;
  esac
done

confirm() {
  local prompt="$1" height="${2:-14}" width="${3:-70}"
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  whiptail --title "$TITLE" --yesno "$prompt" "$height" "$width"
}

if [[ "$ASSUME_YES" -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  warn "MODO -y ACTIVO: se aceptarán automáticamente TODAS las preguntas, incluidas:"
  warn "  - instalar el driver NVIDIA y modificar GRUB/initramfs/blacklist de nouveau;"
  warn "  - instalar switcheroo-control y crear el wrapper nvidia-run."
fi

# ----------------------------------------------------------------------
# 1. Comprobaciones previas
# ----------------------------------------------------------------------

if [[ $EUID -eq 0 ]]; then
  error "No ejecutes este script como root. Usa tu usuario normal; se te pedirá la contraseña de sudo cuando haga falta."
fi

if ! command -v apt >/dev/null 2>&1; then
  error "Este script está pensado para sistemas basados en APT (Debian/derivados)."
fi

if ! command -v sudo >/dev/null 2>&1; then
  error "No se encontró el comando 'sudo' en este sistema."
fi

if ! command -v whiptail >/dev/null 2>&1; then
  log "Instalando whiptail (necesario para las pantallas de este script)..."
  sudo apt update
  sudo apt install -y whiptail
fi

log "Comprobando permisos de sudo..."
if ! sudo -v; then
  error "No se pudieron validar los permisos de sudo."
fi

# ensure_cmd <comando> <paquete>: devuelve 0 si el comando existe (o se ha
# podido instalar) y 1 si no.
ensure_cmd() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  warn "No se encontró '$cmd'; se intenta instalar '$pkg'..."
  if sudo apt install -y "$pkg" && command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  warn "No se pudo instalar '$pkg'."
  return 1
}

WGET_OK=0
if ensure_cmd wget wget; then
  WGET_OK=1
fi

# ----------------------------------------------------------------------
# 2. Pantalla de bienvenida
# ----------------------------------------------------------------------

confirm "Driver NVIDIA para Debian Sid csr79a ${VERSION}\n\nInstala el driver nvidia-open (repo CUDA oficial de NVIDIA), switcheroo-control si hay GPU híbrida, y el wrapper nvidia-run.\n\n¿Desea continuar?" 16 76 || exit 0

# En Sid, VERSION_CODENAME en /etc/os-release NO siempre es fiable.
# Este chequeo es un AVISO, no un aborto duro (a diferencia de
# setup-debian-sid.sh): este script puede correr suelto y no reescribe
# tus repos, solo asume que el pin al repo debian13 de NVIDIA tiene
# sentido en Sid/unstable. Si no lo es, se pide confirmación manual.
DETECTED_CODENAME=""
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  DETECTED_CODENAME="${VERSION_CODENAME:-}"
  if [[ "$DETECTED_CODENAME" != "sid" && "$DETECTED_CODENAME" != "unstable" ]]; then
    confirm "Aviso: este script está pensado para Debian Unstable (Sid).\n\nSe ha detectado: ${PRETTY_NAME:-desconocido} (VERSION_CODENAME='${DETECTED_CODENAME:-vacío}').\n\nEl repositorio y el pin de NVIDIA que usa este script asumen Sid/unstable. Confirma tú mismo que tus repos ya apuntan a unstable antes de continuar.\n\n¿Confirmas que este sistema ya apunta a unstable/sid?" 18 76 || exit 1
  fi
fi

# ----------------------------------------------------------------------
# 3. Driver NVIDIA (opcional)
# ----------------------------------------------------------------------
#
# Mismo patrón que en setup-debian-trixie.sh y setup-debian-testing.sh:
# detectar -> preguntar -> instalar por repo oficial (cuda-keyring), sin
# pinear versión.
#
# NOTA sobre el repo: NVIDIA publica el keyring/repo CUDA por versión de
# Debian estable (p. ej. "debian13"), no existe una rama "sid" dedicada.
# Se usa aquí el paquete de debian13 -- es la combinación ya probada y
# en uso, la misma que en trixie/testing; si en el futuro deja de
# funcionar, revisa la URL vigente en
# https://developer.download.nvidia.com/compute/cuda/repos/ y ajusta
# NVIDIA_KEYRING_URL más abajo.
#
# LIMITACIÓN CONOCIDA: "nvidia-open" solo soporta GPUs Turing en
# adelante (RTX 20xx, GTX 16xx, y más recientes). El script no
# distingue el modelo concreto, solo detecta "es NVIDIA".
#
# Secure Boot / MOK enrollment queda deliberadamente FUERA de este
# script: solo se detecta y se avisa, remitiendo a MANUAL.md.

NVIDIA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/debian13/x86_64/cuda-keyring_1.1-1_all.deb"

GPU_INFO=""
if ensure_cmd lspci pciutils; then
  GPU_INFO="$(lspci | grep -Ei 'vga|3d' || true)"
else
  warn "No se puede detectar la GPU sin 'lspci'; se omiten las secciones de NVIDIA y switcheroo-control."
fi

# Estado de Secure Boot: imprime "enabled", "disabled", "noefi" (sistema
# sin UEFI o sin soporte de Secure Boot: no aplica) o "unknown".
# Primero se usa mokutil, si está instalado; si no, se lee directamente la
# variable EFI SecureBoot (el último byte vale 1 si está activado).
# No se instala ningún paquete para esta comprobación.
detect_secure_boot() {
  local state efivar value
  if command -v mokutil >/dev/null 2>&1; then
    state="$(mokutil --sb-state 2>/dev/null || true)"
    case "${state,,}" in
      *"secureboot enabled"*)  echo "enabled";  return 0 ;;
      *"secureboot disabled"*) echo "disabled"; return 0 ;;
      *"not supported"*|*"doesn't support"*) echo "noefi"; return 0 ;;
    esac
  fi

  if [[ ! -d /sys/firmware/efi ]]; then
    echo "noefi"
    return 0
  fi

  efivar="$(compgen -G '/sys/firmware/efi/efivars/SecureBoot-*' | head -n 1 || true)"
  if [[ -n "$efivar" && -r "$efivar" ]]; then
    value="$(od -An -t u1 -j 4 -N 1 "$efivar" 2>/dev/null | tr -d '[:space:]' || true)"
    case "$value" in
      1) echo "enabled";  return 0 ;;
      0) echo "disabled"; return 0 ;;
    esac
  fi

  echo "unknown"
}

if echo "$GPU_INFO" | grep -qi nvidia; then
  NVIDIA_LINE="$(echo "$GPU_INFO" | grep -i nvidia)"

  # Secure Boot se comprueba ANTES de instalar, para que se sepa de
  # antemano si hará falta completar el proceso MOK/firma del módulo.
  SECURE_BOOT_STATE="$(detect_secure_boot)"
  case "$SECURE_BOOT_STATE" in
    enabled)
      SB_NOTE="ATENCIÓN: Secure Boot está ACTIVADO. Tras instalar, el módulo del kernel de NVIDIA no cargará hasta que completes el proceso de firma/MOK (requiere reiniciar y confirmar en el MOK Manager; consulta MANUAL.md)."
      warn "$SB_NOTE"
      ;;
    disabled)
      SB_NOTE="Secure Boot está desactivado: no hace falta firmar el módulo de NVIDIA."
      log "$SB_NOTE"
      ;;
    noefi)
      SB_NOTE="Este sistema no arranca en modo UEFI o no soporta Secure Boot: no aplica el proceso de firma MOK."
      log "$SB_NOTE"
      ;;
    *)
      SB_NOTE="AVISO: no se ha podido determinar el estado de Secure Boot. Si lo tienes activado, tras instalar puede hacer falta completar el proceso de firma/MOK (consulta MANUAL.md)."
      warn "$SB_NOTE"
      ;;
  esac

  if [[ "$WGET_OK" -ne 1 ]] && ! dpkg -s cuda-keyring >/dev/null 2>&1; then
    warn "Se ha detectado una GPU NVIDIA, pero falta 'wget' (necesario para añadir el repositorio de NVIDIA) y no se pudo instalar. Se omite el driver NVIDIA."
  elif confirm "GPU NVIDIA detectada:\n  ${NVIDIA_LINE}\n\nAviso: este paso instala 'nvidia-open', el módulo de kernel de código abierto de NVIDIA, vía el repositorio CUDA oficial de NVIDIA (rama debian13, la combinación usada y probada también en trixie/testing). Solo soporta GPUs Turing en adelante (RTX 20xx, GTX 16xx, RTX 30xx/40xx/50xx...). En una GPU más antigua (GTX 10xx y anteriores) este driver no cargará; en ese caso necesitarías el paquete 'nvidia-driver' (propietario clásico) en su lugar. El script no comprueba el modelo concreto, solo que el fabricante sea NVIDIA.\n\n${SB_NOTE}\n\n¿Instalar el driver NVIDIA (nvidia-open, última versión disponible en el repo)?" 28 76; then

    # --- Repositorio de NVIDIA (cuda-keyring) ---
    NVIDIA_REPO_READY=0
    if dpkg -s cuda-keyring >/dev/null 2>&1; then
      ok "El repositorio de NVIDIA (cuda-keyring) ya está instalado."
      NVIDIA_REPO_READY=1
    else
      log "Añadiendo el repositorio de NVIDIA (cuda-keyring)..."
      NVIDIA_KEYRING_TMP="$(mktemp --suffix=.deb)"
      if wget -qO "$NVIDIA_KEYRING_TMP" "$NVIDIA_KEYRING_URL" && [[ -s "$NVIDIA_KEYRING_TMP" ]]; then
        if sudo dpkg -i "$NVIDIA_KEYRING_TMP"; then
          NVIDIA_REPO_READY=1
        else
          warn "No se pudo instalar cuda-keyring (falló 'dpkg -i')."
        fi
      else
        warn "No se pudo descargar cuda-keyring desde $NVIDIA_KEYRING_URL (¿sin conexión o URL cambiada?)."
      fi
      rm -f "$NVIDIA_KEYRING_TMP"
    fi

    if [[ "$NVIDIA_REPO_READY" -ne 1 ]]; then
      warn "Se omite la instalación del driver NVIDIA: el repositorio de NVIDIA no está disponible. No se ha tocado nouveau ni GRUB."
    else

      # Pin de origen para el repo NVIDIA CUDA. Sin esto, paquetes como
      # nvidia-driver-libs también existen de forma nativa en el repo
      # non-free de Debian con una versión distinta; sin pin explícito,
      # APT podría resolver algún paquete del stack NVIDIA desde un
      # origen distinto al resto, mezclando versiones entre el módulo
      # de kernel y las librerías.
      #
      # Los comodines 'nvidia-*' / 'libnvidia-*' NO cubren (a) paquetes
      # del driver con otros nombres (libcuda1, libglx-nvidia0,
      # libegl-nvidia0, libgles-nvidia*, libnvcuvid1, libnvoptix1,
      # libxnvctrl0, xserver-xorg-video-nvidia, firmware-nvidia-gsp), ni
      # (b) las variantes de 32 bits (':i386'): en las pruebas, los
      # comodines no les aplicaron el pin, así que se nombran
      # explícitamente. Si una versión nueva del driver renombra alguno
      # de estos paquetes (p. ej. libnvidia-egl-wayland21), añade aquí
      # el nombre nuevo.
      log "Fijando el repositorio de NVIDIA como origen preferente para el stack nvidia-*..."
      sudo tee /etc/apt/preferences.d/nvidia-cuda >/dev/null <<'EOF'
Package: nvidia-* libnvidia-* libegl-nvidia* libgles-nvidia* libglx-nvidia* libcuda1 libcudadebugger1 libnvcuvid1 libnvoptix1 libxnvctrl0 xserver-xorg-video-nvidia firmware-nvidia-gsp
Pin: origin developer.download.nvidia.com
Pin-Priority: 1000

Package: nvidia-driver-libs:i386 nvidia-vulkan-icd:i386 libcuda1:i386 libegl-nvidia0:i386 libgles-nvidia1:i386 libgles-nvidia2:i386 libglx-nvidia0:i386
Pin: origin developer.download.nvidia.com
Pin-Priority: 1000

Package: libnvidia-allocator1:i386 libnvidia-egl-gbm1:i386 libnvidia-egl-wayland21:i386 libnvidia-egl-xcb1:i386 libnvidia-egl-xlib1:i386 libnvidia-eglcore:i386 libnvidia-glcore:i386 libnvidia-glvkspirv:i386 libnvidia-gpucomp:i386 libnvidia-ml1:i386 libnvidia-ptxjitcompiler1:i386
Pin: origin developer.download.nvidia.com
Pin-Priority: 1000
EOF

      log "Instalando el driver NVIDIA (sin pinear versión -> se resuelve la más reciente del repo, ahora con origen fijado)..."
      sudo dpkg --add-architecture i386
      if ! sudo apt update; then
        warn "'apt update' terminó con errores; se intenta la instalación con los índices disponibles."
      fi

      # Detecta las cabeceras del kernel EN EJECUCIÓN, en vez de asumir el
      # metapaquete genérico (que apunta siempre al kernel estándar de
      # turno de Debian). Importante porque también se pueden compilar
      # kernels propios: ese kernel puede no tener un paquete
      # linux-headers-<version> en los repos oficiales, y DKMS necesita
      # las cabeceras exactas del kernel en ejecución para compilar el
      # módulo. Se comprueba AQUÍ, después de 'apt update', para que
      # también se detecten cabeceras servidas por un repo propio y no
      # solo las instaladas a mano con 'dpkg -i'.
      KERNEL_RELEASE="$(uname -r)"
      HEADERS_PKG="linux-headers-${KERNEL_RELEASE}"

      if apt-cache show "$HEADERS_PKG" >/dev/null 2>&1; then
        log "Cabeceras específicas encontradas para el kernel en ejecución (${KERNEL_RELEASE})."
      else
        warn "No hay un paquete '${HEADERS_PKG}' en los repos (¿kernel compilado a mano?)."
        warn "Se usa el metapaquete genérico 'linux-headers-amd64', que puede NO coincidir con el kernel en ejecución."
        warn "Si este es un kernel propio, instala sus cabeceras correspondientes ANTES de continuar o el módulo NVIDIA no compilará."
        HEADERS_PKG="linux-headers-amd64"
      fi

      # Si esta instalación falla NO se toca nouveau ni GRUB: bloquear
      # nouveau sin tener el driver de NVIDIA funcionando dejaría el
      # sistema sin driver gráfico para esa GPU.
      if ! sudo apt install -y \
        "$HEADERS_PKG" \
        nvidia-open \
        nvidia-kernel-open-dkms \
        nvidia-settings \
        libvulkan-dev \
        nvidia-vulkan-icd \
        vulkan-tools \
        vulkan-validationlayers \
        nvidia-driver-libs:i386 \
        nvidia-vaapi-driver; then
        warn "Falló la instalación del driver NVIDIA. No se ha tocado nouveau ni GRUB, para no dejar el sistema sin driver gráfico."
        warn "Revisa el error de arriba y reintenta: sudo apt install nvidia-open nvidia-kernel-open-dkms nvidia-driver-libs:i386"
      else

        log "Deshabilitando el driver nouveau..."
        sudo tee /etc/modprobe.d/blacklist-nouveau.conf >/dev/null <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

        # Fichero propio (no se tocan los de los paquetes NVIDIA). Se
        # sobrescribe entero en cada ejecución, así que no se duplica.
        # NVreg_PreserveVideoMemoryAllocations=1 hace coherentes los
        # servicios nvidia-suspend/hibernate/resume que se habilitan más
        # abajo. NVreg_TemporaryFilePath=/var/tmp se usa para que el
        # volcado de la VRAM no vaya a /tmp, que en Debian puede ser un
        # tmpfs (RAM). Ojo: /var/tmp tampoco garantiza por sí solo estar
        # en disco (depende de cómo esté montado), y el sistema de
        # archivos que lo contenga debe tener espacio libre suficiente
        # para volcar la VRAM completa.
        log "Configurando la preservación de memoria de vídeo para suspensión/hibernación..."
        sudo tee /etc/modprobe.d/nvidia-preserve-vram.conf >/dev/null <<'EOF'
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
EOF

        log "Configurando GRUB para KMS de NVIDIA..."
        NVIDIA_GRUB_PARAMS=(nvidia-drm.modeset=1 nvidia-drm.fbdev=1)
        if [[ ! -f /etc/default/grub ]]; then
          warn "No se encontró /etc/default/grub (¿otro gestor de arranque?); se omite la configuración de GRUB."
          warn "Añade a mano estos parámetros del kernel en tu gestor de arranque: ${NVIDIA_GRUB_PARAMS[*]}"
        else
          NVIDIA_GRUB_BACKUP="/etc/default/grub.bak.$(date +%Y%m%d%H%M%S)"
          sudo cp /etc/default/grub "$NVIDIA_GRUB_BACKUP"
          ok "Copia de seguridad: $NVIDIA_GRUB_BACKUP"

          CURRENT_CMDLINE="$(grep -oP '^GRUB_CMDLINE_LINUX_DEFAULT="\K[^"]*' /etc/default/grub || true)"

          # Compara clave Y valor, no solo si la clave aparece: si ya
          # hubiera, p. ej., "nvidia-drm.modeset=0" puesto a mano, no se
          # sobrescribe en silencio, se avisa para que lo revises tú.
          NEW_CMDLINE="$CURRENT_CMDLINE"
          for param in "${NVIDIA_GRUB_PARAMS[@]}"; do
            key="${param%%=*}"
            if [[ "$NEW_CMDLINE" =~ (^|[[:space:]])${key}=([^[:space:]]*) ]]; then
              existing_value="${BASH_REMATCH[2]}"
              if [[ "${key}=${existing_value}" != "$param" ]]; then
                warn "Ya existe '${key}=${existing_value}' en GRUB_CMDLINE_LINUX_DEFAULT, distinto de '${param}'. No se toca automáticamente; revísalo a mano en /etc/default/grub."
              fi
            else
              NEW_CMDLINE="${NEW_CMDLINE:+$NEW_CMDLINE }${param}"
            fi
          done

          if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub; then
            sudo sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"|" /etc/default/grub
          else
            echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_CMDLINE}\"" | sudo tee -a /etc/default/grub >/dev/null
          fi
          ok "GRUB_CMDLINE_LINUX_DEFAULT resultante: ${NEW_CMDLINE}"

          # command -v no alcanza aquí: update-grub vive en /usr/sbin, que
          # no está en el $PATH de un usuario normal en Debian (solo en el
          # de root/sudo). Por eso se comprueba también la ruta directa.
          if command -v update-grub >/dev/null 2>&1 || [[ -x /usr/sbin/update-grub ]]; then
            sudo update-grub || warn "update-grub ha fallado; revisa la configuración de GRUB y ejecútalo a mano: sudo update-grub"
          else
            warn "No se encontró 'update-grub'; regenera la configuración de GRUB manualmente."
          fi
        fi

        # "-k all": el blacklist de nouveau y las opciones de modprobe
        # quedan en los initramfs de TODOS los kernels instalados, no
        # solo del que está en ejecución. Un error puntual (p. ej. un
        # kernel sin /lib/modules) no debe abortar todo el script.
        sudo update-initramfs -u -k all \
          || warn "update-initramfs devolvió un error en algún kernel; revisa la salida de arriba. Puedes reintentarlo con: sudo update-initramfs -u -k all"

        log "Habilitando servicios de suspensión/hibernación de NVIDIA..."
        for svc in nvidia-suspend.service nvidia-hibernate.service nvidia-resume.service; do
          if sudo systemctl enable "$svc" 2>/dev/null; then
            ok "Servicio habilitado: $svc"
          else
            warn "Servicio $svc no disponible en este empaquetado del driver, se omite."
          fi
        done

        NVIDIA_INSTALLED=1

        if [[ "$SECURE_BOOT_STATE" == "enabled" ]]; then
          warn "Secure Boot está ACTIVADO en este sistema."
          warn "El módulo del kernel de NVIDIA no cargará hasta que firmes la clave MOK."
          warn "Este paso es manual (requiere reiniciar y confirmar en el MOK Manager)."
          warn "Consulta la sección 'Secure Boot / NVIDIA' en MANUAL.md ANTES de reiniciar."
        elif [[ "$SECURE_BOOT_STATE" == "unknown" ]]; then
          warn "No se pudo determinar el estado de Secure Boot. Si lo tienes activado, consulta la sección 'Secure Boot / NVIDIA' en MANUAL.md ANTES de reiniciar."
        fi
      fi
    fi
  else
    warn "Se omite la instalación del driver NVIDIA."
  fi
fi

# ----------------------------------------------------------------------
# 4. switcheroo-control (gestión de GPU híbrida, opcional)
# ----------------------------------------------------------------------

GPU_COUNT="$(echo "$GPU_INFO" | grep -c . || true)"

if [[ "$GPU_COUNT" -ge 2 ]]; then
  GPU_LIST="$(echo "$GPU_INFO" | sed 's/^/  /')"
  if confirm "Se han detectado $GPU_COUNT controladores de vídeo (GPU híbrida: integrada + dedicada):\n\n${GPU_LIST}\n\n¿Instalar switcheroo-control para gestionar el cambio de GPU?" 18 76; then
    SWITCHEROO_OK=1
    if dpkg -s switcheroo-control >/dev/null 2>&1; then
      ok "switcheroo-control ya está instalado."
    elif ! sudo apt install -y switcheroo-control; then
      warn "No se pudo instalar switcheroo-control. Reintenta luego con: sudo apt install switcheroo-control"
      SWITCHEROO_OK=0
    fi

    if [[ "$SWITCHEROO_OK" -eq 1 ]]; then
      if sudo systemctl enable --now switcheroo-control; then
        ok "switcheroo-control instalado y activo. Comprueba las GPUs detectadas con: switcherooctl list"
        SWITCHEROO_INSTALLED=1
      else
        warn "No se pudo habilitar/arrancar switcheroo-control. Reintenta luego con: sudo systemctl enable --now switcheroo-control"
      fi
    fi

    # --- Wrapper nvidia-run (variables de PRIME offload) ---
    # Mismas variables que usa el paquete oficial "nvidia-prime" de
    # Arch/CachyOS (prime-run) y que coinciden con el Environment: que
    # reporta "switcherooctl list" para el dispositivo NVIDIA discreto.
    # Deliberadamente NO se exportan de forma global (en /etc/environment
    # o similar): eso forzaría la NVIDIA para todo el sistema y anularía
    # el ahorro de batería del offloading selectivo.
    if [[ "${NVIDIA_INSTALLED:-0}" -eq 1 ]]; then
      if confirm "¿Crear el comando 'nvidia-run' para lanzar aplicaciones puntuales forzando la GPU NVIDIA (PRIME render offload)?\n\nEjemplo de uso: nvidia-run glxgears" 12 76; then
        log "Creando wrapper nvidia-run en /usr/local/bin..."
        sudo tee /usr/local/bin/nvidia-run >/dev/null <<'EOF'
#!/usr/bin/env bash
# nvidia-run — lanza un comando forzando el offload a la GPU NVIDIA
# (PRIME render offload). Generado por setup-nvidia-debian-sid.sh.
set -euo pipefail
if [[ $# -eq 0 ]]; then
  echo "Uso: nvidia-run <comando> [args...]" >&2
  exit 1
fi
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
export __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
        sudo chmod +x /usr/local/bin/nvidia-run
        ok "nvidia-run creado. Prueba con: nvidia-run glxinfo | grep 'OpenGL renderer'"
        NVIDIA_RUN_INSTALLED=1
      fi
    fi
  else
    warn "Se omite la instalación de switcheroo-control."
  fi
fi

# ----------------------------------------------------------------------
# 5. Resumen final
# ----------------------------------------------------------------------

if [[ "${NVIDIA_INSTALLED:-0}" -eq 1 ]]; then
  cat <<'EOF'

Driver NVIDIA instalado (nvidia-open, última versión del repo), junto
con librerías de 32 bits (nvidia-driver-libs:i386, para Steam/Proton)
y nvidia-vaapi-driver (aceleración de vídeo por hardware en navegadores).
El repo NVIDIA CUDA (rama debian13) se fijó como origen preferente para
todo el stack nvidia-*/libnvidia-* (ver /etc/apt/preferences.d/nvidia-cuda).
Reinicia para que cargue el nuevo driver. Si tienes Secure Boot activado,
no reinicies sin antes seguir la sección 'Secure Boot / NVIDIA' de
MANUAL.md (enrollment de la clave MOK).
Verifica tras reiniciar con: nvidia-smi
EOF
fi

if [[ "${SWITCHEROO_INSTALLED:-0}" -eq 1 ]]; then
  cat <<'EOF'

switcheroo-control instalado y activo (gestión de GPU híbrida).
Comprueba las GPUs detectadas con: switcherooctl list
EOF
fi

if [[ "${NVIDIA_RUN_INSTALLED:-0}" -eq 1 ]]; then
  cat <<'EOF'

Comando 'nvidia-run' creado en /usr/local/bin. Úsalo para forzar una app
puntual a la GPU NVIDIA sin cambiar el comportamiento del resto del
sistema, p. ej.: nvidia-run glxgears
En Steam: nvidia-run %command% como parámetro de lanzamiento.
EOF
fi

if [[ "${NVIDIA_INSTALLED:-0}" -ne 1 && "${SWITCHEROO_INSTALLED:-0}" -ne 1 ]]; then
  echo
  echo "No se instaló nada (sin GPU NVIDIA detectada, o se omitió en las preguntas)."
fi

if [[ "$ASSUME_YES" -ne 1 && "${NVIDIA_INSTALLED:-0}" -eq 1 ]]; then
  if whiptail --title "$TITLE" \
      --yes-button "Reiniciar ahora" --no-button "Reiniciar después" \
      --yesno "Instalación completada.\n\nSe instaló el driver NVIDIA: hace falta reiniciar para que cargue.\n\n¿Reiniciar ahora?" 14 70; then
    sudo reboot
  else
    ok "Recuerda reiniciar manualmente para que el driver NVIDIA entre en uso."
  fi
fi
