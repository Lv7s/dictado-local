# Dictado Local

Hola, soy un usuario de Mac. Tengo un Mac con M5 de 10 núcleos, 24 GB de RAM y 1 TB de SSD, y no estaba cómodo con las apps de dictado que tenía, así que quería una más simple. Como tengo 24 GB de RAM, instalé un modelo local para que todo lo que hablo se quede en mi Mac. Y coloqué también un modelo local que mejora la transcripción a partir de un diccionario.

Esta es la aplicación.

## Qué hace

1. Pulsas **Control+Option+D** (o «Dictar» en el icono del micrófono de la barra de menús) y hablas.
2. Pulsas otra vez y la app transcribe con **Whisper large-v3-turbo** (MLX) en tu Mac.
3. En modo *limpio*, **gemma4:12b** en Ollama corrige la transcripción con tu glosario: puntuación, términos propios y muletillas.
4. El texto queda en el **portapapeles**. Lo pegas con Cmd+V donde quieras.

Nada sale de tu Mac: la única conexión es a Ollama en `127.0.0.1:11434`. No guarda audio ni texto.

## Requisitos

- Mac con Apple Silicon y unos 16 GB de RAM o más (gemma4:12b ocupa ~9,5 GB mientras se usa).
- Herramientas de línea de comandos de Xcode (`xcode-select --install`).
- Python 3.13 y [Ollama](https://ollama.com) con el modelo `gemma4:12b`.
- FFmpeg en `/opt/homebrew/bin/ffmpeg`, solo para la herramienta de línea de comandos `dictado`.

## Instalación

```sh
git clone https://github.com/Lv7s/dictado-local.git
cd dictado-local
python3 -m venv proyecto/.venv
proyecto/.venv/bin/pip install -r proyecto/requirements.txt
ollama pull gemma4:12b
proyecto/construir 1
proyecto/instalar
open "app/Dictado Local.app"
```

El modelo de Whisper se descarga la primera vez desde Hugging Face (`mlx-community/whisper-large-v3-turbo`, 1,5 GB); después la app funciona sin conexión.

Al primer dictado macOS pide el permiso de **Micrófono**. Es el único que necesita: el atajo no pide Accesibilidad ni Monitorización de entrada. Si Ollama no está encendido, la app lo arranca y lo apaga al salir; si no responde, entrega la transcripción sin limpiar y lo avisa.

## Menú del micrófono

| Ítem | Qué hace |
|---|---|
| En espera / Grabando / Transcribiendo / Limpiando / Listo / Error | Estado actual |
| Dictar (Control+Option+D) | Empieza a grabar; durante la grabación cambia a «Terminar dictado» y «Cancelar dictado (Esc)» |
| Modo limpio · cambiar | Alterna entre *limpio* (Whisper + corrección con gemma) y *crudo* (solo Whisper, más rápido) |
| Aviso de copiado | Muestra u oculta el aviso en pantalla cuando el texto ya está copiado |
| Entrega: portapapeles (Cmd+V) | Cómo se entrega el texto. Si concedes Accesibilidad, pega solo en el cursor |
| Permisos… | Estado de los permisos y botón para pedirlos |

## Personalizar

- **Glosario:** `proyecto/especificacion/GLOSARIO.txt`, una palabra o expresión por línea (nombres propios, términos técnicos). Se usa como pista para Whisper y para la corrección.
- **Correcciones fijas:** `proyecto/especificacion/CORRECCIONES.tsv`, expresiones regulares con su reemplazo.
- **Atajo y modo:** `app/Ajustes.json` (`tecla`, `modificadores`, `modo`). macOS no admite atajos globales solo con Option.

Tras cambiar el glosario o el código, vuelve a ejecutar `proyecto/construir <n>` y `proyecto/instalar`. Cada compilación tiene firma ad hoc nueva, así que macOS vuelve a pedir el Micrófono.

## Probar sin micrófono

```sh
proyecto/dictado --archivo audio.m4a --modo limpio
"app/Dictado Local.app/Contents/MacOS/DictadoLocal" --probar-archivo audio.m4a --modo limpio
```

El segundo recorre el mismo camino que un dictado real (decodificación, motor, estados y portapapeles privado) e imprime el texto.

## Límites

- Un dictado dura como máximo 10 minutos.
- La primera transcripción tras abrir la app tarda unos segundos más porque carga Whisper.
- Probado solo en español y con una voz.
