# raycrawl

Un crawler web educado, de línea de órdenes, escrito en
[raylang](https://github.com/ray-language/raylang): semillas → frontera → descarga → enlaces →
JSONL. Respeta `robots.txt`, lee sitemaps (también comprimidos), limita el ritmo por host, reintenta
con espera exponencial, decodifica codificaciones antiguas a UTF-8 y termina con un informe de
códigos de estado, enlaces rotos y cadenas de redirecciones.

```
$ raycrawl crawl https://www.rust-lang.org/ --max-pages 5 --depth 1 --delay 2000
== raycrawl summary ==
URLs: 5 (fetched 5), 68583 bytes, 6572 ms, 0.7 pages/s
Kinds: page 5
Status: 200×4  301×1
Charsets: utf-8 (header)×4
Redirect chains (1):
  https://www.rust-lang.org/ -301-> https://rust-lang.org/  [off-site]
```

## Uso

```
raycrawl crawl URL... [opciones]        rastrear; JSONL a --out, resumen por stderr
raycrawl robots URL [--user-agent UA]   qué dice robots.txt de esa URL, y por qué regla
raycrawl sitemap URL [--limit N]        las URLs de un sitemap o índice de sitemaps (.gz también)
raycrawl testsite [--port N] [--mode M] servir el sitio de pruebas local (hasta Ctrl-C)
raycrawl bench [--pages N] [--per-host N] [--hosts H] [--site BASE]   páginas/s contra el sitio local
```

| Opción | Por defecto | Qué hace |
|---|---|---|
| `--depth N` | 3 | profundidad de enlaces desde las semillas |
| `--max-pages N` | 500 | URLs admitidas como máximo (las bloqueadas por robots cuentan) |
| `--out FILE` | `pages.jsonl` | una línea JSON por URL; `-` = stdout |
| `--report FILE` | — | guarda también el resumen |
| `--per-host N` | 2 | peticiones simultáneas a un mismo origen |
| `--max-hosts N` | 8 | orígenes rastreados a la vez |
| `--delay MS` | 250 | separación mínima entre dos peticiones a un host (`Crawl-delay` puede subirla, hasta 30 s) |
| `--timeout MS` | 10000 | presupuesto de un intento (conexión + cabecera + cuerpo) |
| `--retries N` | 2 | reintentos para 5xx, 429, timeouts y errores de red; respeta `Retry-After` en segundos (más de 30 s = no se reintenta) |
| `--max-bytes N` | 2 MiB | el cuerpo se corta ahí; la página queda marcada `truncated` |
| `--scope S` | `host` | `host`, `domain` (dos últimas etiquetas, sin PSL), `prefix` o `any` |
| `--sitemaps` | no | sembrar también desde los sitemaps (`Sitemap:` de robots.txt, o `/sitemap.xml`) |
| `--no-robots` | no | ignorar robots.txt (solo en sitios propios) |
| `--user-agent UA` | `raycrawl/0.1.0 (+…)` | el token de producto (`raycrawl`) elige el grupo de robots.txt |
| `--text N` / `--links` | 300 / no | caracteres de texto visible por página / todos los enlaces en el JSONL |
| `--max-time MS` | — | dejar de admitir trabajo pasado ese tiempo |

Cada línea del JSONL: `url`, `final_url`, `status`, `kind` (`page`, `robots`, `breaker`, `error`,
`lost`), `depth`, `referrer`, `redirects` (`[{status, url}]`), `content_type`, `charset`,
`charset_source` (`bom`, `header`, `meta`, `default`, `fallback`), `size`, `truncated`, `title`,
`link_count`, `noindex`, `text`, `error`, `attempts`, `elapsed_ms` y `worker` (el hilo del
planificador que la procesó). Ctrl-C deja de admitir peticiones nuevas, espera las que están en
vuelo y escribe el resumen igualmente.

## Qué hace, y con qué parte de raylang

| Pieza | Módulo | raylang |
|---|---|---|
| Normalización de URLs (esquema/host en minúsculas, sin puerto por defecto, sin `.`/`..`, `%XX` en mayúsculas y no reservados decodificados, sin fragmento) y deduplicación | `urlnorm` | `std/url` (`normalize` RFC 3986 §6, `escape_unsafe`, `resolve`, `render`), `std/collections/set` |
| robots.txt RFC 9309: grupos por user-agent (se fusionan; `*` solo si ninguno nombra al agente), Allow/Disallow con `*` y `$`, gana la regla más larga y Allow en empate, `Crawl-delay`, `Sitemap:`; 4xx = todo permitido, 5xx o red = todo prohibido | `robots` | `std/regex` (cada patrón compilado a una regex anclada, los tramos literales con `escape`) |
| Sitemaps `urlset` e índice, con prefijo de namespace, en gzip (detectado por el número mágico), en texto plano; los hijos de un índice se piden en paralelo dentro de un `scope` | `sitemap`, `crawler` | `std/xml` (rechaza DTD: sin XXE), `std/inflate` (`gunzip_limit`, tope de 50 MB) |
| Charset: BOM > `Content-Type` > `<meta charset>` / `http-equiv` en los primeros 1024 bytes > UTF-8, y windows-1252 si el UTF-8 no es válido; los bytes malformados se sustituyen por U+FFFD | `encoding` | `std/charset` (`decode_lossy`; ISO-8859-1, windows-1252, Shift_JIS, UTF-16…) |
| HTML: título, enlaces (`a`, `area`, `iframe`), `<base>`, canonical, `meta robots` (noindex/nofollow), `rel=nofollow`, entidades, texto visible (sin `script`/`style`/comentarios) normalizado NFC | `html` | `std/text` (`nfc`, `words`), `stringbuilder` |
| Descarga en streaming con tope de bytes y presupuesto de tiempo, sobre un pool de conexiones persistentes por host; redirecciones seguidas a mano para registrar la cadena (bucles, límite de saltos, robots del destino, cambio de host) | `fetch` | `net/http` (`pool`, `pool_stream`, `stream_read`, `stream_close`), `std/resilience` (`deadline`) |
| Reintentos con espera exponencial + jitter solo para lo reintentable, o el `Retry-After` del servidor; cortacircuitos por host | `fetch`, `crawler` | `std/resilience` (`policy`/`retry_with`, `breaker`/`admit`/`report`) |
| Concurrencia (abajo) | `crawler` | `spawn_isolated`, `spawn_local`, `scope`, `try_join`, `try_call`, `select`, `select_timeout`, `try_send`, `try_recv`, `worker_id`/`worker_count`, `signals()` |

### Concurrencia

- Un **coordinador** (la fibra que llama a `crawl`) es dueño de la frontera (`deque`), del conjunto
  de vistas (`set`) y de una cola por host. Reparte con `try_send` a la cola acotada de cada host: si
  está llena, el trabajo sigue en la cola local (sin bloquearse nunca). Espera eventos con
  `select_timeout`, que también le sirve de reloj para `--max-time`.
- Cada **origen** tiene su trabajador, lanzado con **`spawn_isolated`**: un dominio de handles nuevo,
  así que los sockets de un host no pueden filtrarse a otro ni ser tocados desde fuera. El pool de
  conexiones (`http.pool(per_host)`) se crea dentro, y sus fetchers lo comparten.
- Dentro, un **despachador** baja robots.txt, aplica el ritmo (`--delay` / `Crawl-delay`) y el
  **cortacircuitos**, y entrega cada URL por un canal de rendezvous a `--per-host` **fetchers**
  lanzados con **`spawn_local`** (fijados al mismo hilo que su despachador: en nativo, todas las
  páginas de un host salen del mismo `worker_id()`, como muestra el resumen). Todo va dentro de un
  **`scope`**: si el despachador falla, sus fetchers se cancelan.
- Un **vigilante** por host hace **`try_join`** del trabajador: un fallo llega al coordinador como
  evento, sus URLs en vuelo se informan como `lost`, el host queda marcado y el resto del rastreo
  sigue. Un pánico al procesar una página concreta lo atrapa `try_call` y queda como error de esa
  página. (Para probarlo hay inyección de fallos: `--crash-on TEXTO`.)
- Si hay más hosts que `--max-hosts`, un trabajador ocioso se retira para ceder el sitio.
- Las señales (`signals()`, otro tipo de canal) entran por una fibra que las reenvía como evento,
  porque `select` exige canales del mismo tipo.

## Pruebas

**Ninguna prueba toca internet**: `testsite` es un sitio de pruebas en raylang (`net/webserver`, en
127.0.0.1 y el puerto 0) con páginas en UTF-8, ISO-8859-1 (por cabecera), windows-1252 (por
`http-equiv`), Shift_JIS (por `<meta charset>`), UTF-8 con BOM y cabecera equivocada, UTF-16;
variantes de robots.txt (normal, `Crawl-delay`, 404, 503); sitemap, sitemap en gzip e índice con un
hijo roto; cadenas de redirecciones 301→302→307, un bucle, una redirección a otro host; una página
lenta, una que da 503 dos veces antes de responder, una que siempre da 503, un 500, un 404, una que pide `Retry-After`, una
página de 3 MiB, una imagen, texto plano, una cadena de páginas para la profundidad y un árbol
generado para medir.

```
make test          # 40 pruebas en la VM
make test-native   # las mismas, como binarios nativos
make demo          # rastrea el sitio de pruebas con el binario nativo
make bench         # páginas/s: nativo vs VM, 1 vs N fetchers, 1 vs 4 hosts
make interop       # OPCIONAL: robots.txt + 5 páginas de un sitio público real, con 2 s entre peticiones
```

## Rendimiento

`make bench` (macOS, M-series, 11 workers, raylang 1.27.110, net 0.17.0): árbol de 1500 páginas
de ~0,9 KB servido en el mismo proceso, sin retardo ni texto en la salida. Cada host reutiliza sus
conexiones (`http.pool_stream`): tras una corrida queda ~1 socket en TIME_WAIT. Con net 0.15 cada
petición era una conexión nueva, se acumulaban 16.543 sockets en TIME_WAIT y el script tenía que
esperar a que se vaciaran; entre paréntesis, las cifras de entonces (raylang 1.27.95).

| Configuración | Nativo | VM |
|---|---:|---:|
| 1 host, 1 fetcher | 15.789 p/s (6.250) | 1.742 p/s (1.483) |
| 1 host, 4 fetchers | 26.785 p/s (11.627) | 4.285 p/s (2.555) |
| 1 host, 16 fetchers | 27.272 p/s (9.316) | 8.196 p/s (5.395) |
| 4 hosts, 4 fetchers | 68.181 p/s (12.931) | 7.978 p/s (5.769) |

En nativo, un host usa un solo hilo del planificador (`spawn_local`); con 4 hosts se reparten en 4.
Una página cuesta ~60 µs en nativo (descarga + charset + HTML + enlaces) y ~570 µs en la VM.

## Estado

| Qué | Estado |
|---|---|
| URLs, robots.txt, charset, HTML, sitemaps | **30 pruebas unitarias**, VM y nativo (raylang 1.27.110; `raylang = "1.27.108"` y net 0.17 en ray.toml) |
| Rastreo de punta a punta contra el sitio local | **10 pruebas**, VM y nativo |
| Binario nativo `--release` | compila y pasa la demo |
| Interop real | `www.rust-lang.org`: 301 a otro host seguido como nueva raíz, 4 páginas por TLS |

Pendiente: `Retry-After` en forma de fecha HTTP, lista de sufijos públicos para `--scope domain`, `<meta http-equiv=refresh>`, reanudar un rastreo
(frontera en disco), y que Ctrl-C también vacíe la cola ya entregada a cada host (hoy se despachan
las hasta `2 × per-host` URLs que ya estaban en ella).

## Hallazgos de dogfood

Registrados en `ray-apps/findings/` (campaña `raycrawl-1.27.95`, re-medida con 1.27.108 y 1.27.110,
y `raycrawl-1.27.110`). Cerrados todos menos #469, y raycrawl ya usa lo que los resolvió:

| # | Tipo | Qué faltaba | Cerrado en | Lo que usa raycrawl ahora |
|---:|---|---|---|---|
| 363 | E | `std/charset` solo estricto: un byte malo perdía la página | 1.27.108 | `charset.decode_lossy` (fuera el rodeo que leía el offset del mensaje de error) |
| 364 | E | `std/resilience.retry` reintentaba cualquier `Err`, sin número de intento ni `Retry-After` | 1.27.108 | `retry_with`: número de intento y `Retry-After` |
| 365 | E | `std/regex` sin `escape` | 1.27.108 | `regex.escape` en `robots.compile_pattern` |
| 366 | E | `std/url` sin normalización RFC 3986 §6 ni escape de un `href` | 1.27.108 | `url.normalize` y `url.escape_unsafe` (fuera ~90 líneas de `urlnorm`) |
| 367 | D | `text.words` no cortaba en NBSP y `trim` sí | 1.27.108 | `text.words` a secas (fuera el `replace` de U+00A0) |
| 368 | D | huecos en la doc de `try_join`, `spawn_isolated` y `scope` | 1.27.110 | — |
| 369 | B | mensaje distinto en VM y nativo para un handle de otro dominio | 1.27.108 | — |
| 370 | E | `net/http` sin streaming sobre una conexión persistente | net 0.17.0 | `http.pool_stream`, un pool por host (de 2,5× a 5× en nativo) |
| 371 | E | `net/webserver.quiet()` dejaba pasar los `Broken pipe` de los cortes del cliente | net 0.17.0 | — (los tests ya no ensucian stderr) |
| 469 | D/E | `url.escape_unsafe` dice imitar al navegador con un `href`, pero codifica los espacios de los extremos y los `\t`/`\n` en vez de quitarlos (`"  /x"` se resuelve como ruta relativa) | abierto | rodeo: `urlnorm.escape_href` limpia antes |

Lo que salió bien: `spawn_isolated`, `spawn_local`, `scope` con cancelación, `try_join`, `try_call`,
`select_timeout`, `try_send`/`try_recv` funcionaron a la primera **y con el mismo comportamiento en VM
y nativo**: las 39 pruebas de entonces pasaron en nativo sin un solo cambio. `std/charset`, `std/xml`,
`std/inflate`, `std/url.resolve` y `std/text.nfc` también a la primera.
