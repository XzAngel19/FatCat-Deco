# Diseño del menú — render, medición y auditoría

Tres herramientas que convierten «el menú se ve raro» en un número y una línea
de código. Las tres son stdlib pura (`zlib`, `struct`, `math`), sin red, sin
`pip install` y sin Pillow, igual que el resto del repo.

```bash
bash tools/design.sh                 # layout + PNG + auditoría (Main)
bash tools/design.sh --project       # las pestañas del decompiler
bash tools/design.sh --zoom 2        # render 2x para revisar píxeles
bash tools/design.sh --strict        # los warnings también fallan
```

Salida: `build/FatCatHub.png`, `build/FatCatHub.audit.json` y el log en
`build/layout.txt`. Un render completo tarda ~1 s y el gate entero del menú
(compilar, 161 asserts, render y auditoría) ~4 s.

| Pieza | Qué hace |
| --- | --- |
| `tools/fatchub/layout.lua` | vuelca la geometría real del menú a una línea JSON por nodo |
| `tools/fatchub/font.py` | lector TrueType: métricas, truncado y rasterizado de glifos |
| `tools/fatchub/render.py` | dibuja el volcado en PNG con texto legible |
| `tools/fatchub/audit.py` | revisa el volcado contra reglas de diseño |
| `tools/fatchub/metrics.py` | empaqueta los avances reales para que el mock mida igual |
| `tools/fatchub/test_font.py` | 24 checks del lector TTF y del rasterizado |
| `tools/fatchub/test_audit.py` | prueba cada regla con un menú roto a propósito |

## Por qué existe esto

El renderer anterior dibujaba **barras grises** en lugar de letras. Servía para
comprobar geometría, pero no para responder las preguntas que importan: ¿se
corta este texto?, ¿cabe en la tarjeta?, ¿se lee sobre ese fondo? Además tardaba
**57 s** para 84 nodos porque pintaba píxel por píxel.

Ahora:

* las letras son letras, así que un texto cortado **se ve** cortado;
* el mismo volcado alimenta la auditoría, así que captura y diagnóstico nunca
  se contradicen;
* las superficies se pintan por scanline con cobertura analítica: **0,7 s** un
  menú entero, **4 s** el volcado de Luau incluido.

## La fuente

`font.py` lee el TTF de verdad: `cmap` formato 4, `glyf` simple y compuesto,
`loca`, `hmtx`, `hhea`. Nada de fuentes embebidas ni binarios extra.

Los nombres de Roblox se mapean a la cara libre más parecida del sistema:

| Roblox | Archivo |
| --- | --- |
| `Gotham` | `DejaVuSans.ttf` (o Liberation/Arial) |
| `GothamBold`, `GothamMedium` | `DejaVuSans-Bold.ttf` |
| `RobotoMono`, `Code` | `DejaVuSansMono.ttf` |

DejaVu es más ancha que Gotham, y eso es a propósito: **si el texto cabe medido
con DejaVu, cabe en Gotham**. La auditoría es conservadora, no optimista.

Tres detalles que costaron el run y están comentados en el código:

1. **El programa de hinting.** `glyf` guarda instrucciones entre la lista de
   puntos y las coordenadas. Saltarse esos bytes por defecto es no leerlos, y
   el cursor queda a mitad de la lista de flags: la letra sale como una mancha.
2. **Winding distinto.** Los contornos exteriores de TrueType van en sentido
   horario en unidades y-arriba, que se invierte al pasar a píxeles y-abajo. Un
   relleno que asuma «el primero es siempre positivo» pinta el hueco de la `a`
   como relleno.
3. **Coberturas y orígenes.** Un glifo con bearing izquierdo negativo (la `a`)
   necesita que el rasterizado reste el origen **una vez**; restarlo dos deja
   los píxeles fuera del array y el glifo sale hueco por la izquierda.

## Renderer

`render.py` respeta lo que Roblox hace de verdad:

| Comportamiento | Implementación |
| --- | --- |
| pintado por `ZIndex` acumulado, no por orden del árbol | `sorted(key=z)` antes de pintar |
| `UIStroke` sólo dentro del marco | el borde se recorta con el marco |
| texto que no cabe → elipsis (`TextTruncate.AtEnd`) | `font.truncate()` |
| `TextWrapped` rompe por palabras | `_wrap()` |
| alineación vertical `Top`/`Center`/`Bottom` | caja de línea según `valign` |
| descendentes de una `g` no se comen | caja de línea = ascenso − descenso reales |
| `CanvasGroup.Transparency` heredada | `group_alpha` en el volcado |

El fondo lleva una rejilla de 40 px: sirve para juzgar alineación y ritmo sin
abrir un medidor.

## Auditoría

Cada hallazgo lleva regla, severidad, el texto exacto y los píxeles que le
faltan. Umbrales en `audit.py: RULES`:

| Regla | Severidad | Umbral | Por qué |
| --- | --- | --- | --- |
| `text-clipped` | error | 0 px | un texto que sale de su tarjeta pierde píxeles, sin excusa |
| `contrast` | error | 3:1 | WCAG AA para texto grande; es un HUD sobre fondos variables |
| `text-truncated` | warning | — | cabe, pero se pierde texto: revisa el copy o ensancha |
| `text-overflow` | warning | 0 px | la caja de línea no cabe o una palabra es más ancha que el label |
| `target-size` | warning | 24 px | por debajo, el puntero falla en pantalla táctil y a 720p |
| `tight-spacing` | note | 3 px | dos tarjetas a menos de 3 px se leen como una |
| `off-grid` | note | 1 px | diferencias sub-píxel son bugs de redondeo, no decisiones |
| `out-of-bounds` | warning | 0 px | el nodo sale del viewport 1280×720 |

Salida legible:

```
audit: 84 nodes, window 460x560, 0 error(s) / 1 warning(s) / 0 note(s)
  WARN  [target-size] TextButton
        84x22px, below the 24px minimum for a pointer target
```

Con `--json` escribe el mismo informe con las cajas afectadas, listo para
comparar entre commits.

### El mock y la captura miden con la misma fuente

`Components.Label` dimensiona su tarjeta desde `TextBounds`, que en Roblox
calcula el motor. El mock no tiene motor de texto, así que `design.sh` le pasa
las mismas métricas que usa el PNG:

```bash
python3 tools/fatchub/metrics.py > build/textmetrics.lua   # _G.TextMetrics
```

Sin ese archivo el mock cae a una estimación por carácter y sigue funcionando
(es lo que usan los 110 asserts de `test_fatchub.sh`, que no deben depender de
qué fuentes tenga la máquina). Con él, `TextBounds` coincide con el rasterizado
y una tarjeta que crece en pantalla crece también en el volcado.

### Las reglas se prueban, no se suponen

`tools/fatchub/fixtures/*.json` son menús mínimos con **un fallo a propósito**
cada uno — un label más ancho que su tarjeta, texto casi invisible, un botón de
12 px, una `g` en una caja de 10 px, un label truncado. `test_audit.py` exige
que la regla correcta dispare con la severidad correcta y mencione el texto
esperado. Una regla que deja de disparar rompe el gate antes de que nadie note
que la captura se ve rara.

## Flujo de trabajo

1. `bash tools/design.sh --project` para ver las pestañas reales.
2. Lee el bloque `ERR`/`WARN` de la auditoría.
3. Arregla en `src/FatCatHub.lua` o `src/FatCatHub.project.lua`.
4. `bash tools/validate.sh` antes de commitear: compila, 161 asserts, 24 checks
   de fuente, 6 fixtures de auditoría, render y auditoría sin errores.

La auditoría **no** es un lint de código: no opina sobre nombres ni estructura.
Sólo mide lo que el usuario va a ver.
