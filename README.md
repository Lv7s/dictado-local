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

La app graba siempre con el micrófono integrado del Mac (si no lo hay, con la entrada del sistema) y no cambia la entrada del sistema. Así, unos auriculares Bluetooth conectados siguen sonando en alta calidad mientras dictas, en vez de pasar al perfil de llamada, y las llamadas siguen usando su micrófono.

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

## Pruebas en un Mac mini de 16 GB (2026-11-21)

Mac mini con Apple Silicon y 16 GB de RAM, Ollama 0.40 y `gemma4:12b` (7,7 GB de descarga). Audio de prueba con la voz sintética de macOS, un solo párrafo; no es una medición con voz humana.

| | Modo crudo | Modo limpio |
|---|---|---|
| Tiempo con Whisper ya cargado | ~5 s | ~2 s de Whisper + ~2,5 s de limpieza |
| Primera limpieza tras cargar Gemma | no aplica | más de 25 s: la app se rinde y entrega el texto sin limpiar |
| Memoria de la app | pico de ~2,4 GB | pico de ~2,4 GB, más Ollama con Gemma (7,8 GB) |

Con Gemma cargada, la memoria libre del sistema bajó de 69 % a 27 % y el swap pasó de 0,8 GB a 7,9 GB (de 9,2 GB). Funciona, pero un Mac de 16 GB queda al límite si además hay otras apps abiertas.

Conclusiones:

- El **modo crudo** es cómodo en 16 GB. El **modo limpio** es posible, pero la primera carga de Gemma supera el tiempo de espera de la app; a partir de la segunda es rápido mientras Gemma siga en memoria (Ollama la descarga a los 10 minutos).
- El glosario solo llega a Whisper como pista inicial. Las correcciones fijas (`CORRECCIONES.tsv`) corren únicamente en modo limpio.
- Los nombres propios poco comunes (por ejemplo, nombres de especies) se transcriben mal en modo crudo con la voz sintética de la prueba.

### Segunda ronda: solo modo crudo, con glosario propio

Mismo Mac mini, con voz humana. Se dictó dos veces el mismo texto con unos 35 términos técnicos de una tesis de biología estructural (nombres de especies, proteínas, equipos y apellidos), con un glosario de 50 términos (~214 tokens) como pista para Whisper.

- **Aciertos:** más o menos la mitad de los términos. Los errores cambiaron de un dictado al siguiente, así que una regla hecha con el primero casi no ayudó con el segundo. Algunos fallos son palabras reales en español (por ejemplo un apellido que sale como «garras»), que una regla fija no puede decidir.
- **Alucinación:** Whisper añadió «Gracias por ver el video» al final de un dictado. Es un fallo conocido cuando queda silencio.
- **Velocidad:** en uso real el modo crudo es muy rápido en este Mac. Según el autor, si vocaliza bien el resultado es suficiente y corregir lo que falle lleva unos 30 segundos.
- **Qué recomienda el autor:** no escribir el glosario a mano. Pasar los propios documentos (tesis, artículos) a una IA y pedirle la lista de términos, abreviaturas e inconsistencias; el autor lo hizo con Claude y lo recomienda. Después se dicta esa lista, se mira cómo la escribe la app y con eso se arman las correcciones fijas.
- **Límite del glosario:** Whisper solo usa los últimos 224 tokens de la pista ([guía de OpenAI](https://developers.openai.com/cookbook/examples/whisper_prompting_guide)). Si el glosario es más largo, se pierde el principio: los términos más importantes van al final.

En la versión publicada, las correcciones fijas solo corren en modo limpio; en su copia local el autor probó aplicarlas también en crudo.

## Límites

- Un dictado dura como máximo 10 minutos.
- La primera transcripción tras abrir la app tarda unos segundos más porque carga Whisper.
- Probado solo en español y con una voz.

## Licencia y cita

Licencia [MIT](LICENSE): puedes usarlo, modificarlo y redistribuirlo conservando el aviso de autoría. Si lo usas o lo adaptas, cita este repositorio; GitHub muestra la cita en «Cite this repository» a partir de [CITATION.cff](CITATION.cff).
