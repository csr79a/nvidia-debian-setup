# nvidia-debian-setup

Script de instalación del driver NVIDIA (`nvidia-open`) para **Debian Sid, Testing o Trixie**, vía el repositorio CUDA oficial de NVIDIA. Incluye gestión de GPU híbrida (`switcheroo-control`) y un wrapper `nvidia-run` para PRIME render offload selectivo.

Proyecto compartido, usado como acción del lanzador tanto desde [`debian-sid-setup`](https://github.com/csr79a/debian-sid-setup) como desde `debian-testing-setup` (y cualquier otro proyecto de Debian que necesite el driver NVIDIA): esta lógica vivía originalmente dentro de `setup-debian-sid.sh`, pero se separó a su propio repo/script para no duplicarla por cada proyecto de Debian y no tener que tocar el setup base cada vez que cambie algo del driver.

## Qué hace

1. Detecta si hay una GPU NVIDIA (`lspci`).
2. Comprueba el estado de Secure Boot (`mokutil` o lectura directa de la variable EFI).
3. Añade el repositorio CUDA oficial de NVIDIA vía `cuda-keyring`, eligiendo la rama según la suite detectada (ver [Ramas de NVIDIA por suite](#ramas-de-nvidia-por-suite)).
4. Fija ese repositorio como origen preferente para todo el stack `nvidia-*` / `libnvidia-*` (pin en `/etc/apt/preferences.d/nvidia-cuda`), incluidas las variantes de 32 bits.
5. Instala `nvidia-open`, cabeceras del kernel en ejecución, `nvidia-settings`, Vulkan (`libvulkan-dev`, `nvidia-vulkan-icd`, `vulkan-tools`, `vulkan-validationlayers`), librerías de 32 bits (`nvidia-driver-libs:i386`, para Steam/Proton) y `nvidia-vaapi-driver` (aceleración de vídeo en navegadores).
6. Deshabilita `nouveau` (blacklist + `modeset=0`).
7. Configura KMS de NVIDIA en GRUB (`nvidia-drm.modeset=1 nvidia-drm.fbdev=1`), con copia de seguridad previa de `/etc/default/grub`.
8. Configura preservación de memoria de vídeo para suspensión/hibernación (`NVreg_PreserveVideoMemoryAllocations=1`) y habilita `nvidia-suspend.service`, `nvidia-hibernate.service`, `nvidia-resume.service`.
9. Regenera initramfs para todos los kernels instalados.
10. Si detecta GPU híbrida (2+ controladores de vídeo): instala y activa `switcheroo-control`, y opcionalmente crea el comando `nvidia-run` para forzar el offload a la GPU NVIDIA en aplicaciones puntuales.

Secure Boot / firma MOK del módulo del kernel queda **deliberadamente fuera** del script: solo se detecta y se avisa. El procedimiento manual está en [`MANUAL.md`](MANUAL.md).

## Ramas de NVIDIA por suite

NVIDIA publica el repo CUDA por versión **numerada** de Debian (`debian13` = Debian 13, sea Trixie testing o ya estable), no por nombre de suite. Hoy, todas las suites soportadas resuelven a la misma rama:

| Suite detectada (`VERSION_CODENAME`) | Rama de NVIDIA usada |
|---|---|
| `sid`, `unstable` | `debian13` |
| `testing`, `forky` | `debian13` |
| `trixie` | `debian13` |
| otra / desconocida | `debian13` (con aviso, confirmación manual) |

El día que Sid (y después Testing) avancen a paquetes de Debian 14, solo hace falta actualizar esos casos en el script (`NVIDIA_DEBIAN_BRANCH`); el resto de la lógica no cambia.

## Requisitos

- Debian Sid, Testing o Trixie. El script avisa (no aborta) si detecta una suite distinta (por ejemplo, `bookworm`/stable), y pide confirmación manual antes de continuar.
- Arquitectura `x86_64`.
- GPU NVIDIA con soporte **Turing o posterior** (RTX 20xx, GTX 16xx, RTX 30xx/40xx/50xx). En GPUs más antiguas (GTX 10xx y anteriores) `nvidia-open` no carga; hace falta el paquete propietario clásico `nvidia-driver` en su lugar (no cubierto por este script).
- `sudo` configurado para el usuario que ejecuta el script.
- Conexión a internet (descarga del keyring de NVIDIA y paquetes vía `apt`).

## Uso

```bash
chmod +x setup-nvidia-debian.sh
./setup-nvidia-debian.sh
```

Modo no interactivo (acepta automáticamente todas las preguntas, incluida la instalación del driver y la modificación de GRUB/initramfs/blacklist de nouveau):

```bash
./setup-nvidia-debian.sh -y
```

Ayuda:

```bash
./setup-nvidia-debian.sh --help
```

> **No lo ejecutes como root.** El script comprueba `EUID` y aborta si lo haces; usa tu usuario normal, `sudo` se invoca internamente cuando hace falta.

## Qué NO hace

- No pinea una versión concreta del driver: instala siempre la más reciente disponible en el repo CUDA de NVIDIA.
- No firma el módulo del kernel para Secure Boot (proceso MOK manual, ver `MANUAL.md`).
- No distingue el modelo exacto de GPU NVIDIA, solo que el fabricante sea NVIDIA; la comprobación de compatibilidad (Turing+) queda en tu mano.
- No modifica `nouveau`/GRUB si la instalación del paquete falla, precisamente para no dejar el sistema sin driver gráfico funcional.

## Archivos que modifica

| Archivo | Acción | Copia de seguridad |
|---|---|---|
| `/etc/apt/preferences.d/nvidia-cuda` | Se crea (pin de origen) | No aplica (fichero nuevo propio) |
| `/etc/default/grub` | Se añaden parámetros de kernel si no existen ya | Sí, `grub.bak.<timestamp>` |
| `/etc/modprobe.d/blacklist-nouveau.conf` | Se crea | No aplica (fichero nuevo propio) |
| `/etc/modprobe.d/nvidia-preserve-vram.conf` | Se crea (se sobrescribe en cada ejecución) | No aplica (fichero propio) |
| `/usr/local/bin/nvidia-run` | Se crea (opcional, GPU híbrida) | No aplica (fichero nuevo propio) |

Más detalle de cada uno en [`MANUAL.md`](MANUAL.md).

## Verificación tras reiniciar

```bash
nvidia-smi
```

Si hay GPU híbrida:

```bash
switcherooctl list
nvidia-run glxinfo | grep "OpenGL renderer"
```

## Proyectos relacionados

- [`debian-sid-setup`](https://github.com/csr79a/debian-sid-setup) — setup base de Debian Sid, del que se desacopló originalmente este script.
- `debian-testing-setup` � setup base equivalente para Debian Testing/Trixie; usa este mismo repo para el driver NVIDIA.
- [`setup-gaming-debian-sid`](https://github.com/csr79a/setup-gaming-debian-sid) — optimización de Debian Sid para gaming.

## Licencia

MIT — ver [`LICENSE`](LICENSE).
