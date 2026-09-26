# Manual — nvidia-debian-setup

Este manual cubre lo que el script **no** hace de forma automática y los procedimientos de verificación, troubleshooting y reversión.

## Índice

1. [Secure Boot / firma MOK del módulo NVIDIA](#secure-boot--firma-mok-del-módulo-nvidia)
2. [Detalle de los ficheros modificados](#detalle-de-los-ficheros-modificados)
3. [Verificación](#verificación)
4. [Troubleshooting](#troubleshooting)
5. [Reversión / desinstalación](#reversión--desinstalación)
6. [Notas sobre el repositorio de NVIDIA](#notas-sobre-el-repositorio-de-nvidia)

---

## Secure Boot / firma MOK del módulo NVIDIA

Si Secure Boot está **activado**, el kernel de Linux solo carga módulos firmados con una clave reconocida por el firmware UEFI. El módulo de `nvidia-open` se compila localmente vía DKMS y, salvo que hayas configurado firma automática con tu propia clave (MOK) de antemano, **no estará firmado** tras la instalación.

Sin completar este proceso, tras reiniciar el sistema caerá de vuelta a `nouveau` (o a modo gráfico sin aceleración) porque el kernel rechazará cargar `nvidia.ko`.

### Procedimiento (una sola vez por máquina)

1. **Antes de reiniciar**, comprueba si ya existe una clave MOK generada por DKMS:

   ```bash
   ls /var/lib/dkms/mok.pub 2>/dev/null && echo "Clave existente" || echo "No hay clave, se generará una"
   ```

2. Si no existe, se genera automáticamente al compilar el módulo DKMS (durante la instalación del paquete `nvidia-kernel-open-dkms`, que ya se ejecutó). Verifícalo:

   ```bash
   sudo mokutil --list-new
   ```

   Si aparece una entrada, hay una clave pendiente de inscribir.

3. Inscribe la clave en el MOK Manager:

   ```bash
   sudo mokutil --import /var/lib/dkms/mok.pub
   ```

   Se te pedirá una contraseña **temporal** (la que uses aquí, no tu contraseña de usuario ni de sudo). Anótala, la necesitas en el siguiente paso.

4. Reinicia:

   ```bash
   sudo reboot
   ```

5. En el arranque siguiente aparecerá la pantalla azul **MOK Manager**. Selecciona:

   `Enroll MOK` → `Continue` → `Yes` → introduce la contraseña del paso 3 → `Reboot`.

6. Tras el reinicio, verifica que el módulo cargó:

   ```bash
   nvidia-smi
   lsmod | grep nvidia
   ```

### Si te lo saltaste y ya reiniciaste

No pasa nada irreversible. Repite los pasos 2-6; DKMS mantiene la clave generada hasta que la inscribas. Si `mokutil --list-new` no devuelve nada, es que el módulo no llegó a compilarse: revisa `dkms status` y `journalctl -u nvidia-*` en busca de errores de compilación (headers del kernel incorrectos suele ser la causa más común, ver [Troubleshooting](#troubleshooting)).

---

## Detalle de los ficheros modificados

### `/etc/apt/preferences.d/nvidia-cuda` (nuevo)

Pin de origen (`Pin-Priority: 1000`) para forzar que **todo** el stack `nvidia-*`/`libnvidia-*` (incluidas variantes `:i386`) se resuelva desde `developer.download.nvidia.com` y no desde el repo `non-free` de Debian, donde también existen paquetes con el mismo nombre pero versión distinta. Sin este pin, APT podría mezclar el módulo de kernel de un origen con las librerías userspace de otro, lo que produce fallos de `nvidia-smi` (`NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver`) por desajuste de versión kernel/userspace.

Si actualizas el driver manualmente en el futuro y ves paquetes retenidos o conflictos de versión, revisa primero este fichero:

```bash
apt-cache policy nvidia-open
```

La línea con prioridad `1000` debe apuntar al origen de NVIDIA.

### `/etc/default/grub` (modificado, con backup)

Se añaden `nvidia-drm.modeset=1 nvidia-drm.fbdev=1` a `GRUB_CMDLINE_LINUX_DEFAULT` si no estaban ya presentes con ese valor exacto. Si ya tenías `nvidia-drm.modeset=0` puesto a mano (por ejemplo, para depurar), el script **no lo sobrescribe**: te avisa y lo deja para que lo revises tú.

Backup: `/etc/default/grub.bak.<YYYYMMDDHHMMSS>`. Para revertir:

```bash
sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub
sudo update-grub
```

### `/etc/modprobe.d/blacklist-nouveau.conf` (nuevo)

```
blacklist nouveau
options nouveau modeset=0
```

Impide que `nouveau` se cargue. Para revertir, elimina el fichero y regenera initramfs (ver [Reversión](#reversión--desinstalación)).

### `/etc/modprobe.d/nvidia-preserve-vram.conf` (nuevo, se sobrescribe en cada ejecución)

```
options nvidia NVreg_PreserveVideoMemoryAllocations=1 NVreg_TemporaryFilePath=/var/tmp
```

Necesario para que `nvidia-suspend`/`nvidia-hibernate`/`nvidia-resume` funcionen correctamente: preserva el contenido de la VRAM al suspender. El volcado va a `/var/tmp`; **comprueba que ese punto de montaje tiene espacio libre suficiente para el tamaño de tu VRAM** y que no es un `tmpfs` en RAM en tu configuración concreta, o la suspensión puede fallar o no liberar la RAM esperada.

### `/usr/local/bin/nvidia-run` (nuevo, opcional)

Wrapper para PRIME render offload selectivo. Exporta `__NV_PRIME_RENDER_OFFLOAD=1`, `__GLX_VENDOR_LIBRARY_NAME=nvidia` y `__VK_LAYER_NV_optimus=NVIDIA_only` solo para el proceso que ejecutes con él, sin afectar al resto del sistema. Uso:

```bash
nvidia-run glxgears
nvidia-run glxinfo | grep "OpenGL renderer"
```

En Steam, como parámetro de lanzamiento de un juego: `nvidia-run %command%`.

---

## Verificación

```bash
# Driver cargado y GPU visible
nvidia-smi

# Módulo del kernel activo
lsmod | grep nvidia

# Renderer en uso (debería decir NVIDIA si no hay GPU híbrida,
# o Intel/AMD si la hay y no usas nvidia-run)
glxinfo | grep "OpenGL renderer"

# Si hay GPU híbrida
switcherooctl list
```

---

## Troubleshooting

**`nvidia-smi` dice que no puede comunicar con el driver, tras reiniciar**
Causa más probable: Secure Boot activado y módulo sin firmar. Ve a [Secure Boot / firma MOK](#secure-boot--firma-mok-del-módulo-nvidia). Si Secure Boot está desactivado, comprueba `dkms status` para ver si el módulo compiló:

```bash
dkms status
journalctl -b -u nvidia-* --no-pager
```

**DKMS falla al compilar el módulo**
Casi siempre son cabeceras del kernel que no coinciden con el kernel en ejecución. Comprueba:

```bash
uname -r
dpkg -l | grep linux-headers
```

Si usas un kernel compilado a mano (ver el proyecto [`kernel-build-debian`](https://github.com/csr79a)), asegúrate de tener instaladas **sus** cabeceras exactas, no el metapaquete `linux-headers-amd64`.

**Pantalla negra tras reiniciar**
No fuerces un `apt purge` en caliente sin consola. Entra en un TTY (`Ctrl+Alt+F3`) o arranca el kernel anterior desde el menú de GRUB, y desde ahí revierte con los pasos de la siguiente sección.

**`apt install` de paquetes `nvidia-*` da conflictos de versión**
Revisa el pin en `/etc/apt/preferences.d/nvidia-cuda` y ejecuta `sudo apt update` de nuevo; es señal de que el repo de NVIDIA no está devolviendo los paquetes esperados o el pin no cubre un paquete nuevo (ver [Notas sobre el repositorio](#notas-sobre-el-repositorio-de-nvidia)).

---

## Reversión / desinstalación

**Desinstalar el driver y volver a nouveau:**

```bash
sudo apt purge -y 'nvidia-*' 'libnvidia-*'
sudo rm -f /etc/modprobe.d/blacklist-nouveau.conf
sudo rm -f /etc/modprobe.d/nvidia-preserve-vram.conf
sudo rm -f /etc/apt/preferences.d/nvidia-cuda
sudo update-initramfs -u -k all
```

Revierte también `/etc/default/grub` desde el backup (`grub.bak.<timestamp>`) si quieres quitar los parámetros de KMS:

```bash
sudo cp /etc/default/grub.bak.<timestamp> /etc/default/grub
sudo update-grub
```

Reinicia después de todo esto.

> **Aviso:** `apt purge 'nvidia-*' 'libnvidia-*'` es una operación destructiva que elimina paquetes por patrón de nombre. Revisa con `apt list --installed | grep nvidia` antes de purgar, por si tienes algún paquete `nvidia-*` instalado manualmente por otro motivo que no quieras perder.

---

## Notas sobre el repositorio de NVIDIA

NVIDIA publica el keyring/repo CUDA por versión **numerada** de Debian (`debian12`, `debian13`...), no existe una rama `sid` dedicada. El script elige la rama según la suite detectada (`NVIDIA_DEBIAN_BRANCH`, ver `README.md`); hoy Sid, Testing, Forky y Trixie resuelven todos a `debian13`. Si en el futuro deja de funcionar (paquetes no encontrados, 404 al descargar el keyring), comprueba la URL vigente en:

<https://developer.download.nvidia.com/compute/cuda/repos/>

y actualiza el `case` de `NVIDIA_DEBIAN_BRANCH` en el script (por ejemplo, cuando Sid avance a paquetes de Debian 14).
